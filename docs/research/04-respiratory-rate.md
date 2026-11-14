# 04 — Respiratory rate

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Companion to
`docs/research/00-inventory.md` §2.4. Every paper in §7 was fetched this session (abstract or full
text); numbers quoted from a search snippet rather than a fetched record are confined to §8 and are
not relied on. Wording throughout is non-clinical: NOOP's respiratory rate is an on-device estimate of
breathing rhythm during sleep, not a measurement of ventilation.

Line numbers below are from the tree on the date above; function names are the stable handle.

---

## 1. What NOOP does today

### 1.1 Files and functions

| Platform | Location | Role |
|---|---|---|
| Swift | `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStager.swift` — `respRateFromRR(_:start:end:)` (~L2094) and the constants directly above it (`rsaResampleHz 4.0`, `rsaDetrendWindowS 8.0`, `rsaMinPeakDistanceS 2.5`, `rsaWindowS 300.0`, `rsaGapToleranceS 3.0`, `rsaMinBreathIntervalS 2.5`, `rsaMaxBreathIntervalS 10.0`, `respPlausibleRangeBpm 8.0...25.0`) | The only respiratory-rate estimator that runs on a WHOOP 5.0: respiratory sinus arrhythmia (RSA) read out of the R-R stream. |
| Swift | same file — `respRateAndRRV(_:dtS:)` (~L1974) and `findPeaks(_:distance:height:)` | WHOOP 4.0 only: peak-picks the raw respiration ADC waveform (`respSample`, 1 Hz). Also used per epoch by the V1 stager's feature extractor. Not reachable on a 5.0 (no raw respiration channel). |
| Swift | `SleepStagerV2.swift` — `respRegularity(_:dft:)` (~L436) and `RespDFT` | A separate RSA readout for the stager: tachogram → 4 Hz resample → mean-removal → band-limited DFT over 0.15–0.40 Hz → peak/sum "peakedness". Returns regularity, not a rate; weighted `respWeight 0.6` in V2's emissions. |
| Swift | `AnalyticsEngine.swift` — `vendorRespRateBpm(_:sessions:)` (~L341, `vendorRespMinSpanS 3_600`) and the `respRateDaily` closure (~L887) | Day roll-up: a device-measured rate (Oura `breath` rows) wins; otherwise the median of finite per-session `respRateFromRR` results over the matched in-bed sessions; nil if none. Feeds `dailyMetric.respRateBpm`, the Charge `resp` term (`wResp 0.05`), `ReadinessEngine` resp z (WATCH 1.5 / BAD 2.0), `IllnessSignalEngine`, and the HealthKit / Health Connect `respiratoryRate` writers. |
| Swift | `HRVFreqDomain.swift` | Lomb–Scargle LF/HF estimator, opt-in display only. HF band 0.15–0.40 Hz (Task Force 1996). Not used for respiratory rate today, but it is the obvious spectral cross-check (§6). |
| Swift | `Packages/WhoopProtocol/Sources/WhoopProtocol/PpgHr.swift` | Decodes the 5.0's v26 24 Hz optical burst for HR only (8 s autocorrelation, 30–220 bpm, `minConfidence 0.3`). Explicitly "HR-only … NOT HRV". The waveform is never examined for respiratory modulation. |
| Swift | `Packages/WhoopStore/Sources/WhoopStore/Whoop5RRReadPolicy.swift`, `Reads.swift` | Upstream of the estimator: every R-R read excludes `tsSuspect = 1` rows, which is where the 5.0's 500 ms filler beats (`rrMs = 500` with same-second HR < 100, #2371) and future-stamped beats (#1073) are removed. `respRateFromRR` therefore never sees a filler beat; its own 300–2000 ms range test is a second line, not the only one. CONFIRMED by reading `Reads.swift` L497–L611. |
| Kotlin | `android/app/src/main/java/com/noop/analytics/SleepStager.kt` — `respRateFromRR(rr, start, end)` (~L2300), constants at ~L2238–L2268 | Byte-parity twin. Same constants, same pipeline, same 8–25 clamp. |
| Kotlin | `SleepStagerV2.kt` `respRegularity` / `RespDft`; `AnalyticsEngine.kt` `vendorRespRateBpm` | Twins. |

### 1.2 Method, step by step (`respRateFromRR`)

1. Keep R-R rows whose `ts` lies in the matched in-bed session `[start, end]`, stable-sorted by `ts`
   (#823), and apply `HRVAnalyzer.rangeFilter`'s predicate (300–2000 ms) to the rows so that `ts`
   survives (#977).
2. Beat-accuracy gate (#882/#883): if ≥ 30 rows, compute `HRVAnalyzer.beatAccurateFraction` (share of
   consecutive rows whose wall-clock step is within 0.5 s of their own R-R) and refuse the night
   (`NaN`) when it is below `beatAccuracyMinFraction 0.5`. Catches banked streams whose intervals are
   a decomposition rather than beat-to-beat measurements.
3. Need ≥ 30 beats. Reconstruct beat times by cumulative sum of R-R; record a splice wherever the
   wall clock outran the beats by more than `rsaGapToleranceS 3.0` s (#977). Need ≥ 150 s of beats.
4. Linear-interpolate the tachogram onto a 4 Hz grid.
5. Detrend by subtracting a centred 8 s moving mean. Refuse if the result is flat.
6. For each 300 s window that contains no splice: `findPeaks` (local maxima above zero, minimum
   spacing 2.5 s = 10 samples); keep peak-to-peak intervals in 2.5–10 s (6–24 breaths/min); window
   rate = 60 / median(interval) if ≥ 2 intervals from ≥ 3 peaks.
7. Night rate = median of the per-window rates; `NaN` unless it lies in 8–25 breaths/min.

No published method is cited at the function beyond "RSA" as a concept; `HRVFreqDomain` cites the
Task Force HF band. The daily roll-up takes the median across sessions. Nothing about the night's
confidence (how many windows survived, how peaked the spectrum was) is stored or shown.

### 1.3 Tests

Swift `RespRateRsaTests` (synthetic sinusoidal RSA at 15 and 11 breaths/min, tolerance ≈ 3 bpm;
batched-timestamp `NaN`; "banked stream without breathing still looks plausible ungated"; compressed
banking; the re-timing known limitation; too-few-beats `NaN`), `RespRateGapAwareTests` (#977
splices), `VendorRespRateTests`, `OuraRespScoringExclusionTests`, `SleepStagerRespDFTTableTests`,
`SleepStagerRespEvidenceTests`. Kotlin: `RespRateRsaTest`, `RespRateGapAwareTest`. All synthetic;
there is no replay of the estimator over any recording with a reference breathing signal, so there is
no accuracy figure for it anywhere in the tree (inventory §2.4, CONFIRMED).

### 1.4 The 13.33 breaths/min floor (#882/#883), explained mechanically

The comment at `respRateFromRR` records that two banked Oura nights returned exactly 13.3333 bpm
ungated, unchanged when the R-R values were shuffled or reversed. The mechanism is arithmetic, not
physiology (INFERRED from the constants, consistent with the measured value): `findPeaks` on a
zero-mean noise-like series with a 10-sample minimum spacing yields local maxima at a characteristic
spacing of about 18 samples (4.5 s at 4 Hz) once the 2.5–10 s interval band is applied, and
60 / 4.5 = 13.33. It is the peak-picker's expected output when the input carries no breathing
rhythm. It sits inside the 8–25 plausibility band, so only an upstream gate on the input (banked-ness)
catches it today. The same floor must be assumed to appear on any WHOOP night whose R-R carries too
little RSA — an older or sympathetically driven sleeper, a night of heavy artefact — because nothing
in the pipeline measures whether a respiratory rhythm was actually present. That is gap G1 in §3.

---

## 2. Recommended method(s) from the literature

### 2.1 Vocabulary

Charlton et al. 2018 (review; fetched full text) name three respiratory modulations of the ECG and
PPG: baseline wander (BW), amplitude modulation (AM) and frequency modulation (FM). FM "is the
manifestation of the spontaneous increase in HR during inspiration", i.e. RSA. NOOP's estimator is a
pure-FM, time-domain method on a beat-interval series. The three are extracted as low-rate
"respiratory signals", typically resampled to "approximately 4–10 Hz", then a rate is read from each
by a time-domain (breath counting) or frequency-domain (spectral peak) technique, optionally fused.

### 2.2 How much RSA there is to read

- Hirsch & Bishop 1981 (17 seated adults, controlled and spontaneous breathing): RSA amplitude is
  large and flat below about 6 breaths/min (plateau 20 ± 5 beats/min peak-to-peak), has a corner
  frequency of 7.2 ± 1.5 breaths/min and then falls at 21 ± 3.4 dB/decade; it is linear in tidal
  volume. Consequence for NOOP: at a typical sleeping rate of 14–16 breaths/min (one octave above the
  corner) the RSA amplitude is roughly half its low-rate value, and at 20+ it is smaller still, so the
  tachogram's respiratory peak shrinks exactly when rate rises — the illness-ward direction the
  readiness gates care about.
- Age: Charlton et al. 2017 (57 healthy subjects, oral-nasal pressure reference) found "frequency
  modulation-based respiratory signals were generally of lower quality in elderly subjects" and that
  23 of 26 respiratory signals degraded at elevated breathing rates; the ECG gave better respiratory
  signals than the PPG. Schäfer & Kratky 2008 (PhysioNet recordings, young supine vs elderly) found
  RSA-based rate "noticeably less accurate for elderly persons". Umetani et al. 1998 (260 healthy
  subjects, 10–99 y, 24 h Holter): rMSSD and pNN50 fall fastest with age, to 47 % and 24 % of
  second-decade values by the sixth decade. The beat-to-beat variance NOOP reads breathing from is
  the quantity that halves by one's fifties.
- Sleep state: Douglas et al. 1982 (19 healthy adults): breathing in all sleep stages is "more rapid
  and shallow" than awake, and minute ventilation is lowest in REM (6.46 vs 7.18 L/min NREM vs 7.66
  awake). Smaller tidal volume means smaller RSA (Hirsch & Bishop's linearity), so REM windows carry
  the weakest and least regular respiratory rhythm. Fitbit's production method (Natarajan 2021)
  prefers deep sleep, falls back to light, and excludes REM for this reason.

### 2.3 Time-domain vs spectral readout of the FM (RSA) signal

- Schäfer & Kratky 2008 compared three published RSA-to-rate techniques with their own; their
  "advanced counting method" (a time-domain approach with amplitude-aware peak validation) did best,
  and RSA gave "good approximations of mean respiratory rate for young subjects with time series longer
  than 1 minute". The abstract gives no numeric error. NOOP's peak-pick is the simple relative of this
  family; the paper's lesson is that counting works when peaks are validated, not when every local
  maximum is a breath.
- Natarajan et al. 2021 (Fitbit Research; wrist PPG beat intervals): non-overlapping 5-minute blocks,
  resampled to 512 points, Hann window, FFT; low- and high-frequency background modelled and
  subtracted; the residual peak in 10–26 breaths/min is the rate; a window is used only if its
  signal-to-noise ratio ≥ 2.5; spectra are aggregated over the night to one estimate. Validated on 52
  nights from 28 adults aged 32–71 against airflow-based PSG / home sleep test nightly medians: RMSE
  0.648, MAE 0.46, MAPE 3.0 %, bias −0.244 breaths/min, r = 0.95. Population reference: in 10,000
  users aged 20–69, 90 % of nightly values lay in 11.8–19.2 breaths/min (mean 15.4, SD 2.35); 14-day
  coefficient of variation roughly 4–6 % under 60 y, widening with age; 7.9 % during illness vs
  5.05 % healthy. Vendor-affiliated authors; observational; still the only wrist-beat-interval RSA
  method with a published nightly accuracy against an airflow reference.
- Charlton et al. 2016 (39 healthy adults 18–40, 32 s windows, oral-nasal pressure reference,
  314 algorithms): the best ECG combination (BW+AM+FM fused, time-domain breath detection) had bias
  0.0 and 95 % LoA −4.7 to +4.7 breaths/min with 80.5 % of estimates within ±2 breaths/min; the best
  PPG algorithm had bias 1.0, LoA −5.1 to +7.2; impedance pneumography itself scored bias −0.2, LoA
  −5.6 to +5.2. The authors restrict the result to young healthy adults. These are per-32-s-window
  figures; nightly medians (Natarajan, Berryhill) are far tighter because the window errors average.
- Orphanidou et al. 2013 (single-lead ECG, RSA fused with R-peak amplitude): bibliographic record
  verified; the search snippet reports MAE 0.81 (young) / 0.84 (elderly) breaths/min over 1-minute
  windows, but the abstract could not be fetched, so those numbers are in §8.

### 2.4 PPG-modulation methods (relevant to the 5.0's v26 bursts)

- Karlen et al. 2013 (CapnoBase, 29 children + 13 adults under anaesthesia): extract RIFV (frequency),
  RIIV (intensity/baseline) and RIAV (amplitude) with Incremental-Merge Segmentation, FFT each, and
  "Smart Fusion": average the three only when they agree, otherwise emit nothing. Mean RMSE 3.0
  breaths/min vs 5.8 / 6.2 / 3.9 for the single modulations.
- Pimentel et al. 2017 (BIDMC + CapnoBase, 95 × 8 min recordings, 32 s and 64 s windows): multiple
  autoregressive models of different orders find the dominant respiratory frequency in each of the
  three variations; median MAE 1.5 (IQR 0.3–3.3) breaths/min on one dataset and 4.0 (1.8–5.5) on the
  other at 32 s, with estimates for > 90 % of input data. The point of the paper is robustness and
  quality-awareness, not a lower floor.
- Lázaro et al. 2013 (17 subjects, tilt table): pulse-width variability as a fourth PPG respiratory
  signal; combining PPG-only signals gave a rate error of −0.17 ± 6.67 %.
- Charlton 2017's device finding: PPG respiratory signal quality fell below ~16 Hz sampling, so a
  24 Hz burst is above the floor; ECG needed ≥ ~250 Hz for FM, which is moot here because the 5.0
  delivers beat intervals at 1/1024 s ticks already.
- Charlton 2018 on fitness trackers: PPG acquired for HR "is likely to be highly corrupted by motion
  artifact"; fusion of modulations improves accuracy "even beyond … the respiratory signal with the
  strongest respiratory modulation", and respiratory quality indices "both increase data retention
  and decrease estimation error".

### 2.5 Wearable validations during sleep (what a good nightly number looks like)

| Study | Device / input | n, population | Reference | Result |
|---|---|---|---|---|
| Berryhill et al. 2020, J Clin Sleep Med (peer-reviewed) | WHOOP strap (vendor's RSA method) | 32 healthy adults, mean 23.8 ± 5 y, one PSG night | Inductance plethysmography during PSG | Respiratory rate bias 1.8 %, precision 6.7 %; HR bias −0.17 %, precision 1.5 %. Percent units, single night, young cohort. |
| Natarajan et al. 2021, npj Digit Med (vendor authors) | Fitbit wrist PPG beat intervals, spectral | 52 nights / 28 adults, 32–71 y, AHI < 30 | PSG or home sleep test airflow, nightly median | RMSE 0.648, MAE 0.46, bias −0.24 breaths/min, r 0.95 |
| Gehring et al. 2023, medRxiv (preprint) | Corsano CardioWatch 287 wrist PPG | 26 adults with and without OSA, one night | Home sleep apnoea test | Arms 0.60 breaths/min, bias −0.14, LoA −1.28 to +1.71; free-living Arms 2.43, LoA −5.00 to +4.47 |
| Oura blog (vendor claim, not peer-reviewed) | Oura ring IR-PPG IBI, RSA | 43 young participants, one ECG night each | ECG-derived rate | "0.71 bpm" mean nightly error |

Reading: a nightly median from an RSA/PPG method can reach ≈ 0.5–1 breath/min against an airflow
reference in young-to-middle-aged sleepers, provided windows are quality-gated and aggregated. The
per-window error is several times larger (Charlton 2016 LoA ± 4.7). No study above reports an older
cohort or a sparse beat stream; both are NOOP's normal case on a 5.0 (§4).

### 2.6 Recommended method for NOOP (summary)

1. Keep the FM/RSA time-domain estimate but make it **refuse honestly**: compute a per-window
   spectral peakedness / SNR on the same detrended 4 Hz grid and drop windows below a threshold, and
   require a minimum number of surviving windows for a nightly value (Natarajan's SNR gate; Charlton
   2018's RQI finding). This removes the 13.33 floor for any input, not just banked ones.
2. Add a **spectral cross-check** per window (band DFT or Lomb–Scargle peak in 0.10–0.40 Hz) and keep
   a window only when the counting estimate and the spectral estimate agree within ~2 breaths/min —
   Smart-Fusion's agreement rule transplanted to two readouts of one signal (Karlen 2013; Charlton
   2016 fused methods were the best).
3. Aggregate the night as the median of surviving windows, **preferring quiescent windows** (low HR
   variance, no motion) over stage labels, since NOOP's stages are not trustworthy enough to gate on
   (inventory §2.3) and `docs/RR-OPTIMIZATION.md` already refuted stage-based window selection for HRV.
4. Store and surface a **confidence** (windows kept / windows available, median peakedness) alongside
   the rate, and export to Health only above a floor.
5. PPG modulation from the v26 bursts is a **research track** behind an Experimental flag, gated on a
   capture audit showing contiguous bursts ≥ 32 s exist in practice (§4, §6).

---

## 3. Gap analysis

| # | Gap (NOOP today vs literature) | Expected impact | Why |
|---|---|---|---|
| G1 | **No quality metric on the output.** Nothing measures whether a respiratory rhythm was present; the peak-picker emits a rate from noise (the 13.33 floor), and only the banked-stream gate stands in front of it. | **High** | Every published wearable method gates windows on SNR / RQI (Natarajan ≥ 2.5; Karlen agreement; Pimentel quality-aware). On a 5.0 the weak-RSA case (older sleeper, fast breather, artefact night) is common, and a plausible wrong number enters the resp baseline, Charge, readiness and illness gates, and Apple Health. A shuffled-input test should return `NaN`; today it returns 13.33. |
| G2 | **Single readout, no cross-check.** Time-domain counting only; the stager already computes a band-limited spectrum (`respRegularity`) of the same signal but the two never meet. | **High** | Charlton 2016: fused/cross-checked methods ranked best; Karlen 2013: agreement gating cut RMSE from 3.9–6.2 to 3.0. Also a "two readouts of one fact" risk in the repo's own terms: the stager's RSA peakedness and the resp rate derive from different pipelines (DFT vs peak-pick) and can disagree about whether breathing was regular. |
| G3 | **Local-maxima counting without peak validation.** Every zero-crossing bump ≥ 2.5 s apart counts as a breath; no amplitude prominence, no comparison to the window's RSA amplitude. | **Medium** | Schäfer & Kratky's best method validates peaks; split peaks inflate the rate toward 2× (#958 was exactly this, patched by the median). Prominence gating is cheap and reduces the floor's reach. |
| G4 | **Fixed 6–24 breaths/min peak band, 8–25 output clamp, 8 s detrend.** The 8 s centred-mean high-pass passes 6 breaths/min at ~0.77 gain and ripples ±20 % through the band (INFERRED from the moving-average response); band edges are fixed, not personal. | **Low** | Natarajan's 10–26 band and Fitbit's 11.8–19.2 (90 %) range sit inside NOOP's; the clamp matters less than G1. A per-user prior around the baseline would help disambiguate a 2× harmonic but is a refinement. |
| G5 | **No confidence stored or shown.** `dailyMetric.respRateBpm` is a bare number; consumers (Charge `wResp`, readiness z, illness ≥ 2-of-4, HealthKit) cannot tell a 40-window night from a 2-window night. | **High** for downstream, low for the rate itself | The repo rule "a diagnostic may only assert what it can attribute" applies: an illness flag built on a 2-window estimate is attributing more than was observed. |
| G6 | **REM / quiescence not considered in aggregation.** Median over all windows in the in-bed span, including wake-in-bed and REM. | **Medium** | Douglas 1982: REM breathing is faster, shallower; Fitbit excludes REM. NOOP's REM is over-called (SleepPSG) so stage gating is unsafe; use HR-flatness / motion-quiescence instead. |
| G7 | **v26 PPG waveform unused for respiration.** Only FM from R-R; the 24 Hz optical burst that `PpgHr` already decodes carries BW/AM/FM in principle. | **Medium–unknown** | Charlton 2016: PPG-only best bias 1.0, LoA −5.1 to +7.2 per 32 s; fusion with FM from R-R could rescue v26-heavy stretches that have no R-R at all. Blocked on whether bursts are contiguous ≥ 32 s (§4). |
| G8 | **No accuracy figure, no harness.** Synthetic sinusoids at ±3 bpm are the only evidence. | **High** (process) | `docs/VALIDATION_PROTOCOL.md` R3/R8: a number with no regenerating command is not evidence. Fantasia / MIT-BIH PSG give R-R + reference breathing for free (§5). |
| G9 | **Sparse-R-R behaviour unmeasured.** The estimator was written for a dense stream; the 5.0 gives ≤ 4 words/s with filler beats removed upstream and v26 holes. | **Medium** | A 1-s hole created by a removed filler beat is below `rsaGapToleranceS` and is bridged by linear interpolation, which fabricates a smooth segment inside the breath band. How often this happens per night on real 5.0 data is unknown (R6: count the base rate). |

---

## 4. WHOOP 5.0 input constraints

### 4.1 What the strap delivers (from `docs/PROTOCOL_SENSORS.md`, CONFIRMED)

- **R18 biometric summary** (124 bytes, nominally one per second when banked): HR at byte 22, R-R
  count at 23, **at most four R-R words** at 24+2i in 1/1024 s ticks. At sleeping heart rates
  (< 90 bpm) one second holds at most two beats, so the four-word cap is not the constraint; the
  constraints are (a) the strap's own 500 ms filler beats at rest, flagged `tsSuspect = 1` by
  `Whoop5RRReadPolicy` when same-second HR < 100 and excluded at read, and (b) seconds with zero
  words.
- **Packet 40** (live): HR plus a declared count of R-R words; "no packet-local quality flag or
  independent absolute timestamp per interval is established".
- **R26 compact optical window**: 88 bytes, one base code plus 24 adjacent deltas (a 25-sample window,
  "a one-second interpretation has been used"), burst counter at 21 (increments per acquisition burst),
  signal-acceptance byte at 82 with an unresolved vocabulary, and "no established R-R interval field".
  On v26-heavy stretches the strap records the waveform **instead of** the v18/R18 summary, so those
  stretches have HR (via `PpgHr`) but **no R-R**, hence no RSA.
- No respiration waveform, no device-computed respiratory rate on the wire (the 4.0's `respSample`
  and Oura's `breath` rows have no 5.0 counterpart).

### 4.2 Consequences for the estimator

| Condition | What happens today | Recommendation |
|---|---|---|
| Night is R-R-dense (R18 banked throughout) | Full pipeline runs; accuracy unknown (G8). | Normal path; add G1/G2 gates. |
| v26-heavy stretch (minutes to hours with no R-R) | Those windows have no beats; cumulative-sum beat time compresses the hole, `rsaGapToleranceS` marks a splice, the window is dropped (#977). If every window is dropped → `NaN`. | Correct. Count dropped windows into the confidence (G5). Research track: BW/AM/FM from the v26 burst itself (G7), only after a capture audit shows how long contiguous bursts actually are (the burst counter at R26 byte 21 makes this a one-script question). |
| Filler beats removed, 1–2 s holes | Linear interpolation bridges them; no splice because the gap ≤ 3 s. | Measure the per-night base rate of such holes before changing anything (R6). If common, treat a window with > X % interpolated samples as low-quality rather than widening the splice tolerance (which would discard whole windows for 1 s holes). |
| HR-only night (sleep bounds from `hrOnlySessions`) | Session bounds come from HR-only detection; the R-R stream inside them may be empty or partial. | Same gates; the confidence must carry `windowsAvailable` so a short bound does not look like a quiet night. |
| Older / low-RSA sleeper, fast breather, artefact night | Peak-picker emits a rate anyway; the 13.33 floor or a harmonic can land inside 8–25. | G1 is the fix: refuse below a peakedness/SNR floor. Showing nothing is the correct output. |
| Banked / batched stream (not a 5.0 case; Oura, imports) | Beat-accuracy gate refuses. | Keep. |

### 4.3 When to show nothing (proposed, to be pre-registered before measuring — R1)

Emit `nil` for the night when any of: beat-accurate fraction < 0.5 (existing); fewer than
`minWindows` (proposal: 6 of the 300 s windows, i.e. 30 min of usable beats) pass the quality gate;
median window peakedness below the floor fitted on Fantasia/MIT-BIH (§5); counting and spectral
estimates disagree in the majority of surviving windows. Store the reason (an enum) so the Test
Centre can say "no respiratory rate: 3 usable windows" instead of silence — the repo rule against
letting a path go quiet.

---

## 5. Validation plan

### 5.1 Public datasets (all fetched this session)

| Dataset | URL | Contents | Why it fits | License / access / size |
|---|---|---|---|---|
| **Fantasia** (PhysioNet) | https://physionet.org/content/fantasia/1.0.0/ | 40 healthy subjects: 20 young (21–34 y), 20 elderly (68–85 y), equal sexes; 120 min supine rest each, awake (watching a film); ECG with beat annotations + respiration, 250 Hz. | The cleanest test of RSA-from-R-R **and of the age failure mode**: feed the annotated beat times (as `RRInterval` rows with whole-second `ts`) to `respRateFromRR`, score against breaths counted on the respiration channel. Not sleep, but supine and quiet. | ODC Attribution 1.0; open; 292.5 MB |
| **MIT-BIH Polysomnographic** (PhysioNet `slpdb`) | https://physionet.org/content/slpdb/1.0.0/ | 16 male subjects, 32–56 y, studied for OSA; ECG (QRS annotations), nasal + chest respiration, EEG/EOG/EMG, R&K sleep stages; 250 Hz; 2–7 h each. | The only free set with **sleep stages + ECG beats + respiration**: lets the night-aggregation and REM/quiescence questions be measured, and shows what apnoeic breathing does to a counting method. Population is patients, so report per-subject. | ODC Attribution 1.0; open; 632.3 MB |
| **BIDMC PPG and Respiration** (PhysioNet) | https://physionet.org/content/bidmc/1.0.0/ (DOI 10.13026/C2208R) | 53 × 8 min ICU recordings; PPG, ECG, impedance respiration at 125 Hz; HR/RR/SpO₂ numerics at 1 Hz; breaths manually annotated by two annotators. | Benchmark for the PPG-modulation track (G7): downsample PPG to 24 Hz and chop into 1 s records to mimic R26 before extracting BW/AM/FM. Adult ICU patients; not sleep. | ODC Attribution 1.0; open; 207.7 MB |
| **CapnoBase IEEE TBME RR Benchmark** | https://borealisdata.ca/dataverse/capnobase | 42 × 8 min, PPG + capnography + ECG, 29 children + 13 adults under anaesthesia; expert-labelled pulse peaks and breaths. | The reference benchmark for PPG RR (Karlen 2013, Pimentel 2017). The project says it is for testing, not tuning. | Custom terms, free account + EULA, access granted in 1–2 working days; size not stated |
| **PPG-DaLiA** (UCI) | https://archive.ics.uci.edu/dataset/495/ppg+dalia (DOI 10.24432/C53890) | 15 subjects; wrist Empatica E4 BVP 64 Hz + 3-axis accel 32 Hz; chest RespiBAN ECG + respiration 700 Hz; daily-life activities. | **Wrist** PPG with simultaneous chest respiration — the closest public analogue to a strap's optical channel. Awake and moving, so it bounds the artefact case, not the sleep case. | CC BY 4.0; open; 2.7 GB zip |
| **WESAD** (UCI) | https://archive.ics.uci.edu/dataset/465/wesad+wearable+stress+and+affect+detection (DOI 10.24432/C57K5T) | 15 subjects; same E4 + RespiBAN pairing; lab protocol (neutral/stress/amusement). | Same use as PPG-DaLiA with seated segments. | Per original site's terms (UCI points to it); open download |

Not found: a PhysioNet set literally named "respiratory rate estimation from PPG" — BIDMC is that
set (it was published for Pimentel 2017). Charlton's RRest toolbox page also lists Vortal (not
public), a processed MIMIC-II subset and a synthetic set; MIMIC-II/III waveform access was not
fetched this session (§8). The RRest toolbox itself ships GPL files (fetched: `LICENSE.txt`,
`gpl.txt` present) — reference its algorithm descriptions, do not copy code (PolyForm NC is not
GPL-compatible for inclusion).

Download into `research-data/` (git-ignored on this branch), never into the tree.

### 5.2 Metrics to report (R4: instrument matches question)

- **Per-window**: bias, 95 % limits of agreement, MAE, and CP2 (% of windows within ±2 breaths/min)
  against the reference window rate — the Charlton 2016 instrument, so NOOP's number is comparable
  to the ± 4.7 LoA ceiling.
- **Per-night / per-record**: MAE and bias of the nightly median vs the reference median
  (Natarajan's instrument; their 0.46 MAE is the bar), plus **retention** (windows kept / windows
  available) — a method that reaches 0.5 MAE by discarding 80 % of nights has not solved the problem.
- **Refusal correctness**: on inputs with the breathing removed (shuffled R-R, Fantasia with RSA
  amplitude scaled toward zero) the output must be `nil`; report the false-emit rate. This is the test
  the 13.33 floor fails.
- **Stratified**: young vs elderly (Fantasia), NREM vs REM vs wake (slpdb stages), by reference rate
  tercile (fast breathers are where RSA is smallest).
- **Direction tracking** (AGENTS.md "validate against the artifact"): synthetic RSA at several
  injected rates (8, 11, 15, 20, 24) and several amplitudes down to the noise floor; recover all, and
  refuse at the floor.
- Every figure with n, instrument, units, run date and the regenerating command (R3, R7). Temporal /
  subject hold-out: fit the peakedness floor on half the Fantasia subjects, report on the other half
  and on slpdb (R5).

### 5.3 Owner validation (n = 1, WHOOP 5.0, no official app)

Two devices agreeing are two estimates, not a measurement (R8), so the plan separates input quality
from algorithm quality:

1. **Polar H10 R-R as a reference-grade beat stream.** Gilgen-Ammann et al. 2019: 99.6 % correctly
   detected R-R intervals vs Holter ECG (10 adults, rest to high intensity). Record H10 R-R overnight
   (any app that logs R-R to CSV), run `respRateFromRR` on the H10 stream and on the strap's stream
   over the same bounds. Disagreement here is **R-R quality** (sparsity, filler removal, v26 holes),
   not the algorithm; it is the measurement the "sparse R-R" question needs.
2. **A breathing reference.** Options in rising fidelity: (a) a 60 s manual count on waking, twice,
   before sitting up — only validates the final windows, and only coarsely; (b) a phone on the
   sternum logging accelerometer at ≥ 20 Hz for the night (respiratory effort is visible as a slow
   oscillation; count peaks offline) — cheap, whole-night, imperfect in side-lying; (c) a Bluetooth
   respiratory belt or an RIP band if one is available. Score the night's median and, for (b)/(c),
   per-5-min windows with the §5.2 instruments.
3. **Keep personal data out of git** (brief §2.6); write the comparison script so it reads from
   `research-data/` and prints the R3 command line in its header.
4. Pre-register (R1) before the first night: prediction, threshold (e.g. nightly MAE ≤ 1.0 vs belt),
   exclusion rule (nights with < 30 min of usable R-R), and n.

---

## 6. Implementation sketch

Everything below is pure, Foundation/stdlib only, and written once for both platforms; the Kotlin
twin is a line-for-line port with a Swift-stdout oracle test (AGENTS.md parity contract). Language
here is pseudocode; names follow the Swift side.

### 6.1 Item A — Per-window quality gate and night confidence (closes G1, G5; effort S–M)

```
struct RespWindowEstimate { rate: Double; peakedness: Double; nPeaks: Int; interpolatedFrac: Double }
struct RespNightEstimate  { bpm: Double?; windowsKept: Int; windowsAvailable: Int;
                            medianPeakedness: Double?; refusal: RespRefusal? }

func respRateFromRR(rr, start, end) -> RespNightEstimate:
    rows, splices, grid, detrended = existing steps 1–5          // unchanged, bit-identical
    windows = []
    for each 300 s window w (unchanged tiling):
        if w contains a splice: windowsAvailable += 0; continue    // as today
        seg = detrended[w]
        // (a) spectral peakedness on the SAME grid the peak-picker uses.
        //     Reuse SleepStagerV2.RespDFT bins 0.10–0.40 Hz (widen kLo from 0.15 to 0.10 so 6–9
        //     breaths/min are visible); peakedness = maxP / sumP, as respRegularity already defines it.
        (fPeak, peakedness) = bandDFTPeak(seg, fs: 4, lo: 0.10, hi: 0.40, dft: &table)
        // (b) counting estimate exactly as today
        rateCount = countingRate(seg)                               // 60 / median(interval) or NaN
        if rateCount.isNaN: continue
        windows.append(RespWindowEstimate(rate: rateCount, peakedness: peakedness,
                                          nPeaks: peaks.count, interpolatedFrac: holes(w)))
    kept = windows.filter { $0.peakedness >= peakednessFloor && $0.interpolatedFrac <= maxHoleFrac }
    if kept.count < minWindows: return .refused(.tooFewUsableWindows(kept.count, windows.count))
    bpm = median(kept.map(\.rate))
    if !respPlausibleRangeBpm.contains(bpm): return .refused(.outOfBand)
    return RespNightEstimate(bpm, kept.count, windows.count, median(kept.map(\.peakedness)), nil)
```

Constants to pre-register and then fit on Fantasia (young half), checked on the elderly half and
slpdb: `peakednessFloor` (start from the value `respRegularity` returns on shuffled input plus a
margin — measure it, do not guess), `minWindows` (proposal 6), `maxHoleFrac` (proposal 0.10).
Persist `windowsKept / windowsAvailable / medianPeakedness` on the day row (additive migration on
both platforms, Room column order = entity order) so HealthKit / Health Connect export and the
illness/readiness consumers can gate on it. Tests: shuffled-input → refused (the 13.33 test
inverted); synthetic RSA at five rates and three amplitudes → recovered / refused at the floor;
oracle literal for Kotlin.

Risk: low for correctness (the shipped number is unchanged on windows that pass), medium for
behaviour (nights that used to show 13–14 bpm will show nothing; the resp baseline will thin). State
that in the PR; it is the honest direction.

### 6.2 Item B — Spectral cross-check and agreement fusion (closes G2, G3; effort M)

```
for each window:
    rateSpec  = 60 * fPeak                      // from 6.1 (a); optionally refine by parabolic
                                                // interpolation of the three DFT bins around the peak
    rateCount = countingRate(seg) with prominence >= promFrac * windowRsaAmplitude
                                                // promFrac ~0.3 of the window's peak-to-trough std;
                                                // candidate, fit on Fantasia
    agree = abs(rateSpec - rateCount) <= agreeTolBpm     // proposal 2.0, Karlen-style
    if agree: windowRate = (rateSpec + rateCount) / 2   // Smart-Fusion average
    else:     window is dropped (counts toward windowsAvailable, not kept)
```

`HRVFreqDomain`'s Lomb–Scargle is the alternative to the band DFT and avoids the resampling step
entirely; it is slower (per-window O(N·F)) but a night has only ~100 windows, and it would make the
estimator consistent with the opt-in HF display. Either way the aim is ONE spectral funnel feeding
both the stager's regularity and the rate (the repo's "one resolver" defence). Oracle test over a
sweep of synthetic rates with harmonics injected (a 2× component at 0.5 amplitude) — the case the
counting method alone gets wrong (#958). Risk: medium; it changes which windows count, so the nightly
value moves on real nights and must be measured before/after on Fantasia + slpdb, never by eye.

### 6.3 Item C — Quiescence-weighted aggregation (closes G6; effort S once A exists)

Among kept windows prefer those whose HR variance (the stager's `hrVar` feature, already computed
per epoch) and motion are in the lowest tercile of the night; take the median of that subset if it
has ≥ `minWindows`, else the median of all kept. Stage-free, so it does not inherit the stager's REM
over-call. Measure on slpdb whether NREM-only windows change the night median vs all windows before
shipping; if the delta is within the reference's own noise, do not ship (negative result, documented).

### 6.4 Item D — PPG modulation from v26 bursts (G7; effort L; research, Experimental flag)

Precondition (R6, one script, no app code): over the owner's captures, histogram the length of runs
of consecutive R26 records with the same burst counter and contiguous timestamps. If contiguous
≥ 32 s runs are rare, stop here and write that down.

If they exist:

```
for each contiguous run >= 32 s (24 Hz, after PpgHr.removeRecordRateComponent + detrend):
    beats     = pulse peaks (PpgHr already finds the fundamental period; a simple peak-pick per
                period suffices)
    FM series = beat-to-beat intervals at beat times
    AM series = (peak − preceding trough) per beat
    BW series = mean level per beat (or per 1 s record: the R26 base code is a free BW proxy,
                but the record-boundary DC steps PpgHr documents (#194) must be removed first)
    each → 4 Hz resample → detrend → band DFT 0.10–0.40 Hz → rateBW, rateAM, rateFM
    emit a run estimate only when the three agree within agreeTolBpm (Karlen 2013 Smart Fusion)
```

Land as instrumentation first (decode + store + log beside the R-R estimate; AGENTS.md
"physiological signal from raw sensor data"), validated on BIDMC/PPG-DaLiA downsampled to 24 Hz and
chopped into 1 s records, then on the owner's belt nights. The record-period artefact that nearly
pinned `PpgHr` to 60 bpm (#194) is the known trap: a 1 s record comb has harmonics at 0.5 Hz, inside
the breath band's second harmonic, so any peak at exactly k/record-period is suspect. Risk: high;
reward: respiration on the stretches that currently have no R-R at all.

### 6.5 Item E — Harness (G8; effort M; do first)

`Tools/RespBench` in the shape of `Tools/SleepPSG`: a Swift CLI that reads PhysioNet WFDB (Fantasia,
slpdb) via a small pure reader, converts beat annotations to `RRInterval` rows with whole-second
`ts` (mimicking R18 stamping), optionally thins to ≤ 4 words/s and drops a configurable share of
seconds (the 5.0 regime), runs `SleepStager.respRateFromRR` and the §6.1/6.2 candidates, and prints
the §5.2 table plus the command line. Without it, items A–D cannot claim anything (R3).

### 6.6 Effort / risk summary

| Item | Effort | Risk | Depends on | Platforms |
|---|---|---|---|---|
| E Harness | M | low | datasets in `research-data/` | Swift CLI (Kotlin tests consume its oracle output) |
| A Quality gate + confidence | S–M | low (correctness) / medium (more nil nights) | E for the floor | Swift + Kotlin, additive migration |
| B Spectral cross-check | M | medium | A, E | Swift + Kotlin, oracle |
| C Quiescence aggregation | S | low | A, E, slpdb result | Swift + Kotlin |
| D v26 PPG modulation | L | high | capture audit, E | Swift + Kotlin, Experimental-gated, instrumentation first |

---

## 7. Sources (verified this session)

1. Charlton PH, Bonnici T, Tarassenko L, Clifton DA, Beale R, Watkinson PJ. *An assessment of
   algorithms to estimate respiratory rate from the electrocardiogram and photoplethysmogram.*
   Physiol Meas 2016;37(4):610. DOI 10.1088/0967-3334/37/4/610. Fetched IOP full page: 314
   algorithms, 39 healthy adults 18–40, 32 s windows, oral-nasal pressure reference; best ECG bias
   0.0 / LoA ±4.7 / CP2 80.5 %; best PPG bias 1.0 / LoA −5.1 to 7.2; IP −0.2 / −5.6 to 5.2.
2. Charlton PH, Birrenkott DA, Bonnici T, Pimentel MAF, Johnson AEW, Alastruey J, Tarassenko L,
   Watkinson PJ, Beale R, Clifton DA. *Breathing Rate Estimation From the Electrocardiogram and
   Photoplethysmogram: A Review.* IEEE Rev Biomed Eng 2018;11:2–20. DOI 10.1109/RBME.2017.2763681,
   PMID 29990026, PMC7612521. Fetched Europe PMC record and full text (first 200k chars): BW/AM/FM
   definitions, FM = RSA, 30–90 s typical windows / 32 s compromise, FM "may be diminished … in
   elderly subjects", fusion and RQI statements, fitness-tracker PPG motion caveat, 4–10 Hz resample.
3. Pimentel MAF, Johnson AEW, Charlton PH, Birrenkott D, Watkinson PJ, Tarassenko L, Clifton DA.
   *Toward a Robust Estimation of Respiratory Rate From Pulse Oximeters.* IEEE Trans Biomed Eng
   2017;64(8):1914–1923. DOI 10.1109/TBME.2016.2613124, PMID 27875128, PMC6051482. Fetched Europe PMC
   abstract: multiple AR models over RIFV/RIAV/RIIV, 95 × 8 min recordings, 32/64 s windows, median
   MAE 1.5 (0.3–3.3) and 4.0 (1.8–5.5) breaths/min, > 90 % retention.
4. Karlen W, Raman S, Ansermino JM, Dumont GA. *Multiparameter respiratory rate estimation from the
   photoplethysmogram.* IEEE Trans Biomed Eng 2013;60(7):1946–1953. DOI 10.1109/TBME.2013.2246160,
   PMID 23399950. Fetched Europe PMC abstract: Smart Fusion of RIFV/RIIV/RIAV, 29 children + 13
   adults, mean RMSE 3.0 vs 5.8 / 6.2 / 3.9 breaths/min.
5. Schäfer A, Kratky KW. *Estimation of breathing rate from respiratory sinus arrhythmia: comparison
   of various methods.* Ann Biomed Eng 2008;36(3):476–485. DOI 10.1007/s10439-007-9428-1, PMID
   18188703. Fetched Europe PMC abstract: advanced counting method best; good for young subjects with
   > 1 min series; "noticeably less accurate for elderly persons"; no numeric error in abstract.
6. Charlton PH, Bonnici T, Tarassenko L, Alastruey J, Clifton DA, Beale R, Watkinson PJ. *Extraction
   of respiratory signals from the electrocardiogram and photoplethysmogram: technical and
   physiological determinants.* Physiol Meas 2017;38(5):669–690. DOI 10.1088/1361-6579/aa670e, PMID
   28296645. Fetched Europe PMC abstract: 57 subjects, 15 ECG + 11 PPG respiratory signals; FM lower
   quality in elderly; 23/26 signals degrade at elevated rates; ECG > PPG; quality drops below ~250 Hz
   ECG / ~16 Hz PPG.
7. Hirsch JA, Bishop B. *Respiratory sinus arrhythmia in humans: how breathing pattern modulates
   heart rate.* Am J Physiol 1981;241(4):H620–H629. DOI 10.1152/ajpheart.1981.241.4.H620, PMID
   7315987. Fetched Europe PMC abstract: 17 subjects; plateau 20 ± 5 beats/min below ~6 breaths/min;
   corner 7.2 ± 1.5 breaths/min; roll-off 21 ± 3.4 dB/decade; linear in tidal volume.
8. Natarajan A, Su H-W, Heneghan C, Blunt L, O'Connor C, Niehaus L. *Measurement of respiratory rate
   using wearable devices and applications to COVID-19 detection.* npj Digit Med 2021;4:136. DOI
   10.1038/s41746-021-00493-6, PMC8443549. Fetched PMC full text: Fitbit (not WHOOP) beat-interval
   spectral method, 5-min blocks, SNR ≥ 2.5, 10–26 band, deep-sleep preference / REM excluded; 52
   nights / 28 adults 32–71 y vs airflow median: RMSE 0.648, MAE 0.46, bias −0.244, r 0.95; 90 %
   population range 11.8–19.2; 14-day CoV ~4–6 %; 3-breath elevation in 36.4 % symptomatic. Vendor
   authors.
9. Berryhill S, Morton CJ, Dean A, et al. *Effect of wearables on sleep in healthy individuals: a
   randomized crossover trial and validation study.* J Clin Sleep Med 2020;16(5):775–783. DOI
   10.5664/jcsm.8356, PMID 32043961, PMC7849816. Fetched Europe PMC abstract: WHOOP, 32 adults
   (mean 23.8 ± 5 y), one PSG night, ECG + inductance plethysmography reference; respiratory rate
   bias 1.8 %, precision 6.7 %; HR bias −0.17 %, precision 1.5 %.
10. Gehring J, Niel LS, ten Bosch-Paniagua L, Frank M. *Continuous respiratory rate monitoring using
    photoplethysmography technology in patients with Obstructive Sleep Apnea.* medRxiv 2023 (preprint,
    not peer-reviewed). DOI 10.1101/2023.07.25.23293134. Fetched Europe PMC preprint abstract:
    Corsano CardioWatch 287 wrist PPG, 26 adults ± OSA, one night vs home sleep apnoea test; RR Arms
    0.60, bias −0.14, LoA −1.28 to +1.71; free-living Arms 2.43, LoA −5.00 to +4.47.
11. Lázaro J, Gil E, Bailón R, Mincholé A, Laguna P. *Deriving respiration from photoplethysmographic
    pulse width.* Med Biol Eng Comput 2013;51(1–2):233–242. DOI 10.1007/s11517-012-0954-0, PMID
    22996834. Fetched Europe PMC abstract: 17 subjects, tilt table; PWV error 1.27 ± 7.81 %; combined
    PPG-only −0.17 ± 6.67 %.
12. Douglas NJ, White DP, Pickett CK, Weil JV, Zwillich CW. *Respiration during sleep in normal man.*
    Thorax 1982;37(11):840–844. PMID 7164002, DOI 10.1136/thx.37.11.840. Fetched Europe PMC abstract:
    19 adults; breathing more rapid and shallow in all sleep stages; minute ventilation 7.66 awake /
    7.18 NREM / 6.46 REM L/min; tidal volume in REM ~73 % of awake.
13. Umetani K, Singer DH, McCraty R, Atkinson M. *Twenty-four hour time domain heart rate variability
    and heart rate: relations to age and gender over nine decades.* J Am Coll Cardiol
    1998;31(3):593–601. DOI 10.1016/S0735-1097(97)00554-8, PMID 9502641. Fetched Europe PMC abstract:
    260 healthy subjects 10–99 y; rMSSD and pNN50 fall to 47 % and 24 % of second-decade values by
    the sixth decade.
14. Gilgen-Ammann R, Schweizer T, Wyss T. *RR interval signal quality of a heart rate monitor and an
    ECG Holter at rest and during exercise.* Eur J Appl Physiol 2019;119(7):1525–1532. DOI
    10.1007/s00421-019-04142-5, PMID 31004219. Fetched Europe PMC abstract: Polar H10 99.6 % correct
    R-R vs Holter 94.6 %; 10 adults; r = 0.997.
15. Orphanidou C, Fleming S, Shah SA, Tarassenko L. *Data fusion for estimating respiratory rate from
    a single-lead ECG.* Biomed Signal Process Control 2013;8(1):98–105. DOI 10.1016/j.bspc.2012.06.001.
    Bibliographic record fetched (Semantic Scholar API; abstract withheld by publisher). Existence and
    venue verified; its error figures are listed in §8, not relied on.
16. Dai R, Lu C, Avidan M, Kannampallil T. *RespWatch: Robust Measurement of Respiratory Rate on
    Smartwatches with Photoplethysmography.* IoTDI 2021. DOI 10.1145/3450268.3453531. Fetched Semantic
    Scholar record and abstract: 30 participants, signal-processing + CNN hybrid with an Estimation
    Quality Index on Wear OS watches; no MAE number in the abstract (PDF fetched but not renderable
    locally).
17. BIDMC PPG and Respiration Dataset v1.0.0, PhysioNet. https://physionet.org/content/bidmc/1.0.0/
    DOI 10.13026/C2208R. Fetched: 53 × 8 min, PPG/ECG/impedance 125 Hz, annotated breaths, ODC-By,
    207.7 MB.
18. Fantasia Database v1.0.0, PhysioNet. https://physionet.org/content/fantasia/1.0.0/ Fetched: 40
    subjects (20 young 21–34, 20 elderly 68–85), ECG + respiration 250 Hz, 120 min supine, ODC-By,
    292.5 MB.
19. MIT-BIH Polysomnographic Database v1.0.0, PhysioNet. https://physionet.org/content/slpdb/1.0.0/
    Fetched: 16 male OSA-study subjects 32–56 y, ECG + nasal/chest respiration + EEG + R&K stages,
    250 Hz, 2–7 h, ODC-By, 632.3 MB.
20. CapnoBase Dataverse. https://borealisdata.ca/dataverse/capnobase Fetched: IEEE TBME RR Benchmark
    42 × 8 min with expert pulse/breath labels; custom terms; free account + EULA; access in 1–2
    working days.
21. PPG-DaLiA, UCI ML Repository. https://archive.ics.uci.edu/dataset/495/ppg+dalia DOI
    10.24432/C53890. Fetched: 15 subjects, E4 BVP 64 Hz + RespiBAN ECG/respiration 700 Hz, CC BY 4.0,
    2.7 GB.
22. WESAD, UCI ML Repository. https://archive.ics.uci.edu/dataset/465/wesad+wearable+stress+and+affect+detection
    DOI 10.24432/C57K5T. Fetched: 15 subjects, same sensor pairing, lab affect protocol.
23. Charlton PH. RRest toolbox, https://github.com/peterhcharlton/RRest and
    https://peterhcharlton.github.io/RRest/datasets.html. Fetched: three toolbox versions, GPL
    licence files present, dataset list (Synthetic, Vortal, BIDMC, MIMIC-II, CapnoBase).
24. Oura, *How Accurate Is Oura's Respiratory Rate?* https://ouraring.com/blog/how-accurate-is-ouras-respiratory-rate/
    and *Respiratory rate* https://ouraring.com/blog/respiratory-rate/ Fetched. **Vendor claims,
    not peer-reviewed**: IBI/RSA method from IR PPG; "0.71 bpm" mean nightly error vs ECG-derived
    rate in 43 young participants; "12–20 breaths per minute" typical; sleep-apnoea caveat.

## 8. Unverified leads

- **Orphanidou 2013 error figures** — MAE 0.81 (young) / 0.84 (elderly) breaths/min over 1-min
  windows, 40 subjects: from a search snippet of the abstract; the abstract itself was not fetched
  (Elsevier/Europe PMC withheld). Treat as plausible, unconfirmed.
- **WHOOP vendor pages** on respiratory rate (`whoop.com/thelocker/...`): returned HTTP 403 / DNS
  failure. Search snippets claim "within 1 breath per minute of gold standard", nightly **median**
  display, and RSA derivation. The peer-reviewed basis (Berryhill 2020) is in §7; the vendor wording
  is not.
- **Miller et al. 2020, J Sports Sci** (WHOOP vs PSG): search results describe it as a sleep-only
  validation (12 adults, 86 nights; 2-stage 89 %, 4-stage 64 %) with no respiratory-rate result. Not
  fetched; do not cite for respiration.
- **Shah / Nazari wearable sleep respiratory rate; Grimm / Haveman wrist-PPG RR at rest** — no
  matching records were located this session; not searched exhaustively.
- **Berntson et al. 1993** (RSA origins review, Psychophysiology) and **Lipponen & Tarvainen 2019**
  (artefact correction; topic 01) — not fetched here; relevant background only.
- **MIMIC-II / MIMIC-III waveform subsets** with impedance respiration (Charlton's processed
  MIMIC-II set) — listed on the RRest page, access terms not fetched.
- **Apnea-ECG and St Vincent's (ucddb) PhysioNet sets** (ECG + respiration during sleep) — not fetched;
  candidates to extend §5 if slpdb's 16 subjects prove too few.
- **Fitbit's SNR definition** (what "≥ 2.5" is a ratio of) — the PMC text names the threshold and the
  background-subtraction fit but the exact SNR formula was not extracted; needs the methods section
  before a NOOP constant borrows the value.
- **RespWatch MAE** — the abstract gives none; the ACM full text was not readable here.

# 01 — HRV & R-R interval quality

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Phase 1 research
note; no source was changed. Every paper in §7 was fetched this session (PubMed E-utilities abstract,
Europe PMC full text, PMC full text, or the dataset's own page). Anything that could not be fetched is
in §8 and carries no recommendation. All wording keeps NOOP's non-medical stance: HRV here is a wellness
approximation, not a clinical measurement.

Companion documents this note assumes you have read: `docs/research/00-inventory.md` §2.1,
`docs/RR-OPTIMIZATION.md` (especially finding 4: stage-based window selection is refuted, quality-based
selection is live) and `docs/VALIDATION_PROTOCOL.md` (R1–R8).

---

## 1. What NOOP does today

CONFIRMED by reading the source on 2026-11-10 (line numbers drift; names are the handle).

### 1.1 Files and functions

| Platform | File | Functions |
|---|---|---|
| Swift | `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift` | `rmssdRaw`, `sdnnRaw`, `rangeFilter`, `rejectEctopic`, `cleanRR`, `cleanRRGapAware`, `rmssdGapAware`, `pnn50GapAware`, `analyze(rawRR:maxRejectedFraction:)`, `sdnnIndex`, `rollingRmssd`, `rrCoverage`, `classifyCoverage`, `beatSpreadIsTrustworthy`, `successiveDiffIsTrustworthy`, `beatAccurateFraction`, `beatValuesAreTrustworthy`, `collapseOverCount` (instrumentation only) |
| Swift | `.../SleepStager.swift` | `sessionHrvWindows` (5-min tumbling windows), `sessionAvgHRV` (plain mean of window RMSSDs, refused by `sessionHrvOverCounted`), `lastDeepRun` (trace only) |
| Swift | `.../AnalyticsEngine.swift` | `avgHRVDaily` (in-bed-duration-weighted mean over physiology sessions; optional deep-window mode), `avgSDNNDaily` (= `sdnnIndex` over in-bed R-R) |
| Swift | `.../HRVReadiness.swift` | opt-in ln RMSSD 7-night rolling baseline vs 60-night (fallback 30) ±0.5 SD band, `minNights 14`, CV trend over 28 nights |
| Kotlin | `android/app/src/main/java/com/noop/analytics/HrvAnalyzer.kt`, `SleepStager.kt`, `AnalyticsEngine.kt`, `HRVReadiness.kt` | "Faithful Kotlin port … verified on macOS"; constants `RR_MIN_MS 300`, `RR_MAX_MS 2000`, `MIN_BEATS 20`, `ECTOPIC_THRESHOLD 0.20`, `ECTOPIC_WINDOW_RADIUS 2`, `DEFAULT_SPOT_MAX_REJECTED_FRACTION 0.35` identical to Swift |

### 1.2 Method and parameters

1. **Metrics.** Task Force (1996) RMSSD, SDNN (sample SD, ddof = 1), mean NN, pNN50. The nightly
   headline (`dailyMetric.avgHrv`) is RMSSD in ms. `avgSdnn` is the Task Force **SDNN index** (mean of
   5-min SDNNs), chosen for window-comparability with Apple Watch.
2. **Cleaning.** Range filter `[300, 2000]` ms → Malik-style rejection of any interval deviating more
   than **20 %** from the median of its 4 neighbours (window radius 2, beat under test excluded) →
   `minBeats 20` clean intervals per analysis unit. No missed-/extra-beat modelling (the file header says
   so explicitly: the Lipponen–Tarvainen classifier used by the original Python pipeline "is unavailable
   on-device").
3. **Gap-aware successive differences** (#204/#208): a difference across a dropped beat is skipped, so a
   deletion costs data but does not splice a spurious delta. Identical to plain RMSSD on clean input.
4. **Nightly value.** `sessionHrvWindows` cuts `[start, end]` into 5-min tumbling windows (last window
   closed on `end`); a window reports RMSSD only when `≥ 20` clean beats survive; `sessionAvgHRV` is the
   **unweighted mean** of window RMSSDs; the day value is the in-bed-duration-weighted mean over
   physiology sessions (HR-only nights only if nothing else). A deep-window pool exists behind
   `deepHrvWindow` (default off; refuted by `docs/RR-OPTIMIZATION.md` finding 4).
5. **Gates.** `rrCoverage = Σrr / wall-clock` with plausible band `[0.90, 1.10]`; the two over-count
   verdicts refuse RMSSD for the night (#1118) and SDNN; `beatAccurateFraction ≥ 0.5` (|Δts − rr| ≤ 0.5 s)
   gates SDNN and the RSA respiration path; the spot reading additionally refuses when > 35 % of input
   beats were rejected. **The nightly windows have no rejected-fraction gate and no minimum number of
   valid windows per night**: one qualifying 5-min window makes a night.
6. **Rolling RMSSD** (`rollingRmssd`, #803): display timeline, emits from 8 clean beats per window.
7. **Baselines.** `RecoveryScorer` z-scores HRV in **raw ms**; `ReadinessEngine` and `HRVReadiness`
   work in **ln RMSSD**. ln RMSSD for the Charge z was tried and parked at n = 8
   (`docs/RR-OPTIMIZATION.md` finding 3).

### 1.3 Sources already cited in code

Task Force 1996; Malik et al. 1989; Lipponen & Tarvainen 2019 (named as not implemented); Baek 2015,
Munoz 2015, Shaffer & Ginsberg 2017, Plews 2013, Buchheit 2014, Bellenger 2016 (in
`docs/RR-OPTIMIZATION.md`); Lomb/Scargle/Laguna/Clifford for the opt-in frequency domain.

### 1.4 Tests

Swift: `HRVAnalyzerTests`, `HRVCleaningPreservationTests`, `HrvGapAwareTests`, `HrvOverCountGateTests`,
`HrvCollapseOverCountTests`, `HrvWindowSweepOracleTests`, `HrvDiagnosticRowsTests`,
`AnalyticsEngineRefusedMainNightHrvTests`. Kotlin: `HrvAnalyzerGateTest`, `HrvAnalyzerRollingTest`,
`HrvAnalyzerSdnnIndexTest`, `HrvArtifactDensityTest`, `HrvCleaningPreservationTest`,
`HrvCollapseOverCountTest`, plus fixture-backed `HrvGoldAgreementTest` / `HrvOpticalRobustnessTest`
(AAUWSS PSG-ECG and GalaxyPPG Polar-H10 windows, fixtures not committed, skipped in CI).

---

## 2. Recommended method(s) from the literature

### 2.1 Which metric: RMSSD for the nightly value, ln RMSSD for baselines and trends

- RMSSD is "the primary time-domain measure used to estimate the vagally mediated changes reflected in
  HRV"; SDNN mixes sympathetic and parasympathetic contributions and, over short resting recordings, is
  dominated by respiratory sinus arrhythmia (Shaffer & Ginsberg 2017, PMC full text). The Task Force
  1996 standard is the definition NOOP already reproduces (record verified; full text not fetchable, see
  §8).
- For monitoring, the vagal indices (rMSSD, SD1) "are the most attractive ones" because they can be
  captured over 10 s to 1 min and are robust to the short field recordings athletes make (Buchheit 2014,
  Europe PMC full text). The same paper puts the typical error of resting vagal HRV at ≈ 12 % CV for
  Ln rMSSD and the smallest worthwhile change at ≈ +3 %, and notes that a single ectopic or skipped beat
  in a 5-min recording "can modify common HRV indices up to 50 %".
- The log transform is the standard for day-to-day comparison: Plews 2012 (7-day rolling average of
  Ln rMSSD and its CV tracked a triathlete into non-functional overreaching; slope −0.17 ms/week,
  r² = −0.88 in the NFOR athlete vs 0.01 in the control), Plews 2014 (standardised changes in Ln rMSSD
  plateau once ≥ 3–4 days are averaged; "a minimum of 3 (randomly selected) valid data points per
  week"), Flatt 2017 and Nakamura 2016 (weekly mean lnRMSSD and lnRMSSDCV as the operating pair),
  Bellenger 2022 (WHOOP 3.0 weekly lnRMSSD CV 5.4 ± 0.7 % in 11 elite athletes over 16 weeks, inside the
  ~3–13 % natural day-to-day range). NOOP's `HRVReadiness` already does exactly this; `RecoveryScorer`
  does not.
- SWC conventions in this literature: 0.5 × CV (Le Meur, cited in Buchheit 2014) or 1 × CV (Plews),
  or ±0.5 SD of the personal normal band (the `HRVReadiness` choice). Any of these is defensible; what
  the literature does **not** support is a z-score on raw ms with a fixed logistic.

### 2.2 Minimum valid data per analysis unit (the per-window beat floor)

Measured against 5-min ECG, in healthy adults:

| Study | n | Finding for RMSSD | Finding for SDNN |
|---|---|---|---|
| Baek 2015 (Telemed J E Health) | 467, ages 8–69 | **30 s** is the minimum length that reliably estimates 5-min RMSSD | not in abstract (SDSD needs 240 s) |
| Munoz 2015 (PLoS ONE) | 3,387 | a single 10-s strip gives a valid RMSSD (r 0.85–0.86, bias 0.08–0.10 ms); averaging three 10-s strips r = 0.94; **120 s is near-perfect** (r 0.986, bias 0.014) | 10 s r 0.76; needs ≥ 30 s or several 10-s strips |
| Esco & Flatt 2014 (JSSM) | 23 athletes, ECG | **60 s** lnRMSSD: ICC 0.98, LoA 0.00 ± 0.22 ln; 30 s: −0.07 ± 0.41; 10 s: −0.20 ± 0.94 | — |
| Nussinovitch 2011 (ANE) | 70 healthy | RMSSD reliable at 1 min and 10 s (ICC good) | **SDNN not reliable** below 5 min |
| Salahuddin 2007 (IEEE EMBC) | 24 | RMSSD and pNN50 reliable within 30 s | — |

Translation into beats: at a sleeping HR of 50–60 bpm, 30 s ≈ 25–30 beats and 60 s ≈ 50–60 beats.
NOOP's `minBeats 20` is ≈ 20–24 s of beats, i.e. **below Baek's 30-s floor** and well below the 60-s
length at which lnRMSSD agreement becomes excellent. The rolling timeline's 8-beat floor (≈ 8–10 s) sits
at Munoz's "single 10-s strip" edge (r ≈ 0.85). Averaging several short units recovers reliability
(Munoz: r 0.86 → 0.94 by averaging three 10-s strips), which is the argument for keeping many 5-min
windows and pooling them rather than for a longer single window.

### 2.3 Which window: whole night vs slow-wave sleep vs stillest windows

What the literature says:

- Night recordings are "theoretically the best (more standardized) recording condition" and SWS
  episodes "offer great signal stability and a high standardization of both environmental factors and
  respiratory influences" (Buchheit 2014, citing Brandenberger 2005 and Buchheit 2004).
- Brandenberger 2005 (16 healthy adults, PSG+ECG): in 5-min SWS segments respiration is more regular
  (SD of cycle 0.27 vs 0.42 s), SDNN is **lower** than quiet wake (54.3 vs 78.8 ms) and normalised HF is
  higher (0.57 vs 0.51). Boudreau 2013 (13 participants, ultradian protocol): progression to deeper NREM
  shifts toward parasympathetic modulation, REM toward sympathetic; parasympathetic modulation in SWS
  peaks at ~02:00 (a circadian effect independent of stage).
- Herzig 2018 (15 males × 3 PSG nights): HR and HF power are reproducible within and across nights in
  SWS; LF and LF/HF are poor in every stage. A **purely R-R-based** selector (moving 5-min windows of the
  correlation of successive R-R, detrended, first run ≥ 10 min sitting 0.1 below its mean) landed 87 % of
  its selected segments inside SWS "without the need of full PSG".
- WHOOP's own convention, as described in the peer-reviewed validation (Bellenger 2021): HRV is taken
  from the **final five minutes of the final SWS episode**. The Miller 2022 comparison, by contrast,
  averaged WHOOP's raw R-R over the **whole sleep period** and obtained ICC 0.99 vs ECG, so the whole
  night is not an inferior reference condition; it is a different one.
- Kinnunen 2020 (Oura, 49 adults 15–72 y, nightly ECG): the nightly-average HRV reached r² = 0.980 with
  bias −1.2 ms, while individual 5-min segments reached only r² = 0.765 ± 0.178. A night-level
  aggregate is far more reliable than any one 5-min window.

How this reads against `docs/RR-OPTIMIZATION.md` finding 4: the refutation was of **stage-labelled**
selection, where the label comes from NOOP's own stager (κ ≈ 0.37 four-class, per
`docs/research/00-inventory.md` §2.3). Selecting on a label that is wrong 60 % of the time cannot
reproduce Brandenberger/Herzig, whose labels were PSG. Herzig's R-R-only selector and the "lowest
variance windows, median across them" idea from the second wearer are the same thing: a stationarity
selector that never consults the hypnogram. That is the live candidate. The recommendation is therefore:

1. **Headline nightly value: the whole-night aggregate over quality-gated 5-min windows** (what NOOP
   does, with the tightened gates of §3), because that is the quantity validated at ICC 0.99 (Miller
   2022, WHOOP) and r² 0.98 (Kinnunen 2020, Oura) against ECG.
2. **Experimental alternative: an R-R-only stationarity selector** (Herzig-style or lowest-variance
   windows, median of their RMSSD), shipped behind a default-off flag and scored on night-to-night CV and
   on agreement with a Polar H10 reference before any promotion. Nothing stage-based.

### 2.4 Artifact and ectopic-beat handling for PPG-derived R-R

The candidate algorithms, with what was verified:

| Approach | Verified finding | Fit for NOOP |
|---|---|---|
| **Lipponen & Tarvainen 2019** (J Med Eng Technol 43:173) | Time-varying thresholds from the distribution of successive differences + beat classification into ectopic / long-short / missed / extra. Sensitivity 100 % for simulated missed/extra beats; 96.96 % sensitivity, 99.94 % specificity for real atrial/ventricular ectopics; mean HRV error after correction < 2 % (worst case < 8 % for minimally misaligned beats). "Relatively easy to implement." | Deterministic, no dependencies, ~200 lines (§6.1). The reference implementation in NeuroKit2 (`signal_fixpeaks.py`, fetched) pins the constants: `alpha = 5.2`, `window_width = 91`, `c1 = 0.13`, `c2 = 0.17`, `medfilt_order = 11`; threshold `th = alpha · (Q3 − Q1)/2` over a centred rolling window of |dRR| (th1) and of the median-deviation series (th2). |
| **Kubios threshold filter** (Alcantara 2020, J Clin Med, full text) | Compare each R-R with a median-filtered local average; levels Very Low 0.45 s, Low 0.35, Medium 0.25, Strong 0.15, Very Strong 0.05; flagged beats cubic-spline interpolated. Very Strong interpolated 17–39 % of beats in the best 5-min period of three cohorts, so "most of the selected period is artificial". | NOOP's 20 % of a ~1000 ms sleeping R-R ≈ a 200 ms absolute threshold, i.e. between Kubios Medium and Strong. Bellenger 2021 found the **200 ms** level and WHOOP's proprietary filter gave the lowest Ln RMSSD bias/LoA on WHOOP PP intervals and Very Strong was worse. So the present rule is in the right band; its weakness is that it is not adaptive (next row). |
| **Berntson 1990** (Psychophysiology) | Subject-specific criterion from the distribution of successive heart-period differences using percentile-based (robust) indexes; flagged all 1,494 simulated and real artifacts with < 0.3 % false alarms. | The principle Lipponen inherits: derive the threshold from the wearer's own difference distribution with quantiles, not from a fixed percentage. |
| **Karlsson 2012** (Biomed Eng Online, 140 Holters) | Recursive removal of intervals differing from the mean of surrounding intervals by more than a limit (10–50 %); an age-based limit reproduced carefully edited frequency-domain HRV; sufficient for subjects > 30 y. | Evidence that a fixed percentage needs to be age/variability-tuned — a fixed 20 % is one point on that curve. |
| **Citi 2012** (IEEE TBME) | Point-process inverse-Gaussian model; best specificity and sensitivity on Fantasia/MIT-BIH among compared methods. | Model-based, online-adaptive; heavier than needed and harder to make byte-identical across platforms. Not recommended. |
| **Peltola 2012** (Front Physiol review) | Deletion, interpolation and filtering have different effects that depend on setting, metric and series length; editing is "an integral part" of analysis. | Supports NOOP's choice of deletion + gap-aware differences for RMSSD over interpolation. |
| Shaffer & Ginsberg 2017 | "The bias introduced by even a single artifact can easily eclipse the 0.5–1.0 Ln effect sizes" of interest. | Justifies gating a window on its rejected fraction, not only on survivors. |

### 2.5 Missing and sparse R-R: what is tolerable

- Kim 2007 (Physiol Meas; 2,615 five-minute tachograms from MIT-BIH NSR with 0–100 s removed, 1,000
  Monte Carlo runs each; plus real missing data from a capacitive ECG during sleep): MeanNN is the most
  robust parameter to missing data (explained by finite-population correction); **pNN50 is the most
  sensitive**; SDNN/SDSD/RMSSD lie between. Errors on real sleep data "may exceed those of the
  simulation". The frequency-domain and non-linear sequels (Kim 2009, Kim 2012) found interpolation
  rules necessary there, with Poincaré measures the only non-linear ones that tolerate gaps.
- Morelli 2019 (Sensors; nsr2db, Gilbert-burst missing data): if you must interpolate, interpolate the
  **beat times**, not the durations — interpolating durations "modifies the power spectrum". For NOOP's
  time-domain RMSSD the better answer is not to interpolate at all: a skipped pair is unbiased, an
  interpolated pair is a manufactured small difference that biases RMSSD low.
- Hernando 2018 (Apple Watch vs Polar H7, 20 subjects): the watch's R-R stream contains gaps (on average
  5 per recording, 6.5 s each); **temporal HRV indices were not significantly affected by the gaps**,
  while LF and HF power were. This is the single most relevant result for a decimated stream: time-domain
  RMSSD survives gaps provided differences are never taken across them, which NOOP already guarantees.

Net: there is no published "X % missing is the limit" for RMSSD. What exists is (a) the per-unit length
floor (§2.2: ≥ 30 s, better 60 s, of **contiguous** beats), (b) the evidence that aggregation over more
units repairs reliability (Munoz, Kinnunen), and (c) the warning that pNN50 degrades first. The
operational rule in §4 is derived from these, not copied from a paper, and must be validated (R1).

### 2.6 Agreement of wrist PPG HRV vs ECG during sleep

| Study | Device / population | Window | Agreement vs ECG |
|---|---|---|---|
| Miller 2022 (Sensors; PMC full text) | WHOOP 3.0, raw R-R supplied by manufacturer; 53 adults, 1 lab night | whole sleep period, RMSSD | **bias −4.5 ± 3.9 ms, LoA ±7.6 ms, ICC 0.99**; HR bias −0.3 ± 1.0 bpm, ICC 0.99 |
| Miller 2022 | Oura Gen 2 | whole sleep, RMSSD | bias −10.2 ± 39.4 ms, LoA ±77.2, ICC 0.63 (proportional, heteroscedastic) |
| Miller 2022 | Apple Watch S6 | sleep, RMSSD | bias −9.6 ± 28.1, LoA ±55.2, ICC 0.67 |
| Miller 2022 | Polar Vantage V | 4 h within sleep | bias −8.7 ± 38.0, ICC 0.65 |
| Miller 2022 | Garmin FR245 | 3-min wake test | bias −22.4 ± 46.9, ICC 0.24 |
| Bellenger 2021 (Sensors; PMC full text) | WHOOP 2.0; 6 adults, 15 nights | last 5 min of final SWS | Ln RMSSD bias 1.66 ± 1.80 %, LoA ±5.93 % (200 ms filter or proprietary filter); HR bias ≤ 0.39 %, LoA ≤ 1.56 %; authors note Ln RMSSD bias/LoA approach or exceed the SWC (1.5–6.5 %) |
| Kinnunen 2020 (Physiol Meas) | Oura ring, 49 adults 15–72 y, nights | nightly average | HR r² 0.996 bias −0.63 bpm; HRV r² 0.980 bias −1.2 ms; per-5-min HRV r² 0.765 ± 0.178 |
| Sarhaddi 2022 (PLoS ONE) | Samsung Gear Sport, 28 adults, 24 h free-living | sleep vs awake | sleep: high correlation, low bias for HR and time-domain HRV; awake: only AVNN/HR acceptable |
| Stone 2021 (Front Sports Act Living) | 7 consumer devices, 5 adults, 148 resting trials | seated rest | rMSSD MAPE: HRV4Training 4.10 % (CCC 0.98), Oura 6.84 % (CCC 0.91), CameraHRV 112 % |
| Plews 2017 (IJSPP) | smartphone PPG and Polar H7, 29 adults | 5-min rest | rMSSD TEE CV 6.35 %, R = 1.00, trivial standardised difference |
| Hernando 2018 (Sensors) | Apple Watch vs Polar H7, 20 adults | relax / mental stress | reliability and agreement > 0.9 for R-R; gaps as above |
| Schäfer & Vagedes 2013 (Int J Cardiol review) | PPG/PRV vs ECG, many studies | rest vs activity | sufficient at rest, but short-term variability "somewhat overestimated by PRV" (respiratory coupling); activity and some mental stressors impair agreement "often to an inacceptable extent" |
| Georgiou 2018 (Folia Med review, 18 studies) | wearables | rest / exercise | very good to excellent at rest, declines progressively with exercise |

Reading: (1) a wrist PPG R-R stream **can** reproduce ECG RMSSD during sleep to within ±8 ms when the
vendor's own beat detection and filtering are used (WHOOP 3.0 in Miller 2022); (2) the same hardware
family read through the last-SWS window carries ≈ 6 % LoA on Ln RMSSD, which is the size of the
day-to-day signal itself (Bellenger 2021); (3) PRV tends to over-read short-term variability slightly
relative to ECG (Schäfer & Vagedes), the same direction as NOOP's observed over-read vs WHOOP in
`docs/RR-OPTIMIZATION.md`; (4) every other wrist device in Miller 2022 shows proportional,
heteroscedastic error, i.e. error grows with HRV — expect NOOP's absolute agreement to be worse for
high-HRV wearers.

---

## 3. Gap analysis

Expected accuracy impact is for the owner's case (WHOOP 5.0, sparse R-R, HR-dense nights). CONFIRMED
means the NOOP behaviour was read in source; the impact rating is INFERRED from the literature above.

| # | NOOP today (CONFIRMED) | Recommended | Impact | Why |
|---|---|---|---|---|
| G1 | Per-window floor is **20 clean beats** (~20–24 s at sleeping HR), with no requirement that those beats be contiguous and no rejected-fraction gate on nightly windows. | Floor at **≥ 30 contiguous successive pairs** (Baek 30 s) as the minimum, **≥ 50** as the "full confidence" tier (Esco & Flatt 60 s, ICC 0.98); reuse the spot gate (rejected fraction ≤ 0.35) on every nightly window. | **High** on a 5.0 | On sparse nights many windows sit in the 20–30-beat regime; each contributes a noisy RMSSD with the same weight as a full window, and feeds the personal baseline. This is the "raise the floors toward 20–30" candidate already named in `docs/RR-OPTIMIZATION.md`, now with the exact literature floors. |
| G2 | Night = **unweighted mean** of window RMSSDs; day = in-bed-weighted mean across sessions. | Weight each window by its contiguous-pair count, or take the median across windows (robust to a few artifact-inflated windows). Kinnunen/Munoz show aggregation repairs reliability; Shaffer warns a single artifact dominates. | Medium | Changes which windows dominate, not the formula. The lowest-variance-median idea (second wearer, LOO r −0.49 → +0.67, n = 20) is a special case; a plain beat-weighted mean is the conservative first step and is cheap to oracle-test. |
| G3 | Fixed **20 % of local median** ectopic rule. | Lipponen–Tarvainen 2019 adaptive thresholds (5.2 × quartile deviation of |dRR| over 91 beats) with beat classification. | Medium (direction wearer-dependent) | A fixed percentage is too permissive for a low-HRV wearer (a 15 % jump passes, inflating RMSSD) and too strict for a high-HRV wearer (genuine 25 % successive changes are deleted, deflating RMSSD and discarding scarce data). Berntson 1990 and Karlsson 2012 both show the criterion must come from the wearer's own distribution. At ~1000 ms the current rule ≈ Kubios Strong (200 ms), the level Bellenger 2021 found best for WHOOP PP, so the expected gain is in robustness across wearers and nights, not a large mean shift for one wearer. |
| G4 | No missed-/extra-beat **correction**: both are deleted (loss, not bias, thanks to gap-awareness). | Lipponen's missed (insert midpoint) / extra (merge) correction recovers those beats as valid pairs. | Medium on a 5.0, Low on a 4.0 | On a stream that already banks ≤ 4 R-R/s, every recovered pair matters for reaching the G1 floors. Caveat: a 500-ms filler beat is **not** an extra beat of the heart; see §4 for why the detector must run only on `tsSuspect = 0` beats and never "merge" a filler. |
| G5 | Deep-window option (stage-labelled) exists, default off. | Remove or leave off; add an **R-R-only stationarity selector** (Herzig 2018) as default-off experiment. | Medium for night-to-night reliability; unknown for absolute agreement | Stage-labelled selection is refuted on NOOP data because NOOP's labels are κ ≈ 0.37; Herzig's selector reaches SWS 87 % of the time from R-R alone. Must be validated against H10 and on night-to-night CV before any promotion (R1/R5). |
| G6 | `RecoveryScorer` z-scores HRV in **raw ms**; two other engines use ln. | One baseline machinery in **ln RMSSD** with an SWC band (topic 06 decides the machinery; this topic only says the domain). | Low–Medium | Unanimous in the monitoring literature (Plews 2012/2013/2014, Buchheit 2014, Flatt, Bellenger 2022). The n = 8 null result in `docs/RR-OPTIMIZATION.md` was a narrow-range sample, not evidence against the transform. Also removes the "two readouts of one fact" risk named in `AGENTS.md`. |
| G7 | No nightly **confidence tier** and no minimum count of valid windows: one qualifying window makes a night, and that night seeds the baseline. | Tiered nightly output (§4.3): refuse / limited / normal, with "limited" nights displayed but kept out of baseline seeding. | **High** on a 5.0 | Kim 2007: errors on real sleep data exceed simulation; Hernando 2018: gaps are fine only when few. A night built from 5 minutes of beats is a spot reading, not a night, and the baseline it enters is what every later night is scored against (the same reasoning as `successiveDiffIsTrustworthy`'s comment). |
| G8 | pNN50 is computed and gap-aware but carries no extra gate. | Keep display-only; never feed it a gate. | Low | Kim 2007: most sensitive to missing data. |
| G9 | `rollingRmssd` emits from 8 beats. | Label the timeline as ultra-short (Munoz: single 10-s r ≈ 0.85) or raise to ≥ 12–15 beats; display only. | Low | Not in any gate. |

What is **not** a gap: deletion plus gap-aware differences (Peltola 2012 supports deletion over
interpolation for time-domain; Morelli 2019 shows duration interpolation biases); the SDNN index choice
(Task Force; Nussinovitch 2011 shows whole-night SDNN would not be comparable anyway); coverage and
beat-accuracy gates (no literature equivalent, but they are instrument checks per R4).

---

## 4. WHOOP 5.0 input constraints

### 4.1 What the strap provides (from `docs/research/00-inventory.md` §1, CONFIRMED there)

- R18 history banks **≤ 4 R-R words per second**; live `0x2A37` carries R-R while connected. Scored
  channels are `srcChannel IN (5, 7)`.
- At rest the strap emits a **500 ms filler beat**, flagged `tsSuspect = 1` by `v47-rr-whoop5-fill`
  when the same-second HR is < 100 bpm.
- `rrCoverage` is often < 1 (under-covered); `beatAccurateFraction` separates beat-accurate from
  banked streams. README: overnight HRV is "incomplete unless sufficient R-R intervals are captured".
- Gravity is sparse, so session bounds often come from HR-only detection; the HRV window therefore
  inherits sleep-detection error (cross-cutting observation 1 in the inventory).

### 4.2 Consequences for each recommended method

- **Filler beats and the artifact detector.** A 500 ms interval next to ~1000 ms neighbours is a
  −50 % deviation: Malik deletes it today and the gap-aware RMSSD skips both adjacent differences. A
  Lipponen detector would classify it as an *extra* beat (two short intervals summing to the local
  median) and try to **merge** it with its neighbour. That is correct for a double-detected pulse and
  wrong for a filler the firmware invented. Rule: feed the detector only `tsSuspect = 0` beats, and
  treat `tsSuspect = 1` as a hard gap (no merge, no pair across it). The filler flag is upstream
  protocol work and must not be re-derived in analytics.
- **Contiguity is the scarce resource.** With ≤ 4 words/s the stored sequence may or may not be
  consecutive heartbeats; `beatAccurateFraction` (|Δts − rr| ≤ 0.5 s) is the only on-device evidence of
  adjacency. The G1 floor must therefore count **contiguous pairs that are also beat-accurate**, not
  raw survivors. A window of 40 beats whose timestamps do not step by their own intervals is 0 valid
  pairs, and must report nothing.
- **No interpolation, ever, on this stream.** Morelli 2019's interpolation result is for spectral
  features on a nominally complete tachogram; on a decimated stream interpolation manufactures the very
  successive differences RMSSD measures. Deletion + skip remains the right primitive.
- **Session bounds from HR-only nights** move the window. The whole-night aggregate is more robust to a
  ±20-min bound error than any single selected window; a second reason to keep the whole-night headline.

### 4.3 Graceful degradation: a three-tier nightly output (proposal, to be validated)

Per 5-min window (all pure, both platforms):

```
cleanBeats        = survivors of range + artifact filter          (exists)
validPairs        = count of successive pairs that are contiguous (exists: `contiguous`)
                    AND beat-accurate (|Δts − rr| ≤ 0.5 s)        (new: thread tsSec into the window)
rejectedFraction  = 1 − cleanBeats / inputBeats                   (exists for spot only)
windowTier        = refuse   if validPairs < 30  or rejectedFraction > 0.35
                  = limited  if 30 ≤ validPairs < 50
                  = full     if validPairs ≥ 50
```

Per night:

```
fullWindows, limitedWindows  = counts
pairsTotal                   = Σ validPairs over non-refused windows
nightTier = refuse   if (fullWindows + limitedWindows) < 3  or pairsTotal < 150
          = limited  if fullWindows < 6                      (< 30 min of full-quality data)
          = normal   otherwise
```

Behaviour by tier: `refuse` → nil (existing honest edge, never a fabricated number); `limited` →
value shown with a "limited R-R" marker, **excluded from baseline seeding and from any downstream gate**
(Charge, illness, readiness) until a held-out comparison shows limited nights agree with normal nights
within the SWC; `normal` → as today. The thresholds 30/50 pairs come from Baek (30 s) and Esco & Flatt
(60 s); 3 windows / 150 pairs and 6 full windows are **engineering choices** with no literature
constant behind them and must be pre-registered and swept on the owner's H10 nights (R1, R5). Report
the tier in the existing `hrv diag` line so the distribution across real nights is visible before any
threshold is frozen (the same path `coveragePlausibleFloor`'s comment asks for).

---

## 5. Validation plan

### 5.1 Public datasets (all pages fetched 2026-11-10)

| Dataset | What it gives for this topic | Access / license / size |
|---|---|---|
| **DREAMT** v2.2.0, PhysioNet, https://physionet.org/content/dreamt/ (DOI 10.13026/3f7y-2d80) | 100 adults (Duke sleep lab, mean age 56, BMI 33.7, 23 with severe OSA), Empatica E4 **wrist BVP 64 Hz + IBI** and full PSG including **ECG**, 30-s technician stages. The only public set with wrist PPG and ECG across whole nights with sleep labels. | **Restricted**: PhysioNet account + Restricted Health Data Use Agreement 1.5.0; size not listed on the page. Population is clinical/older, so absolute RMSSD levels are not the owner's, but per-night PPG-vs-ECG agreement and SWS-window behaviour can be scored. |
| **PPG-DaLiA**, UCI #495, https://archive.ics.uci.edu/dataset/495/ppg+dalia (DOI 10.24432/C53890) | 15 subjects, E4 wrist BVP 64 Hz + RespiBAN chest **ECG 700 Hz**, daily activities (Reiss 2019). | Open, CC BY 4.0, 2.7 GB. Daytime only; use for artifact-detector sensitivity under motion and for the Malik-vs-Lipponen comparison on real wrist PPG. |
| **WESAD**, UCI #465, https://archive.ics.uci.edu/dataset/465/wesad+wearable+stress+and+affect+detection (DOI 10.24432/C57K5T) | 15 subjects, E4 wrist BVP 64 Hz + RespiBAN chest ECG 700 Hz, lab stress/amusement/neutral. | Public; license per the original dataset site (not stated on UCI). Same use as PPG-DaLiA, at rest. |
| **GalaxyPPG**, Zenodo 14635823, https://zenodo.org/records/14635823 (paper DOI 10.1038/s41597-025-05152-z) | 24 adults (20–29 y), Galaxy Watch 5 PPG 25 Hz + E4 BVP 64 Hz + **Polar H10 ECG 130 Hz with ms IBIs**; stress and treadmill tasks (~33 min of tasks). The paper reports wrist SDNN/RMSSD "differed substantially from ECG" across activities. | Open, CC BY 4.0, 481.6 MB. Already used by NOOP's fixture tests. The H10 IBIs are the same reference instrument the owner can wear. |
| **Wrist PPG During Exercise**, PhysioNet, https://physionet.org/content/wrist/ | 8 subjects, Shimmer wrist PPG + chest ECG at 256 Hz with hand-marked R peaks. | Open, ODC-By 1.0, 49.8 MB. Small; artifact-detector unit tests only. |
| **Pulse Transit Time PPG**, PhysioNet, https://physionet.org/content/pulse-transit-time-ppg/ | 22 adults, **finger** PPG (not wrist) + 3-lead ECG 500 Hz, sit/walk/run; ~40,000 beats. | Open, ODbL 1.0, 2.9 GB. Finger site: secondary. |
| **BIDMC**, PhysioNet, https://physionet.org/content/bidmc/ | 53 ICU records × 8 min, PPG + ECG 125 Hz. | Open, ODC-By 1.0, 208 MB. ICU, finger; RMSSD formula checks only. |
| **MIMIC-III Waveform**, PhysioNet, https://physionet.org/content/mimic3wdb/1.0/ | ~67,000 ICU records, fingertip PPG + ECG 125 Hz. | Open, ODbL 1.0, 6.7 TB. Not worth the download for this topic. |
| **Sleep deprivation HRV/PPG/PSG**, Zenodo 4326598, https://zenodo.org/record/4326598 | 15 participants, overnight PPG + PSG + morning orthostatic R-R across baseline / 3 nights at 3 h sleep / recovery. PPG site and device not stated on the page. | Open, CC BY 4.0, ~24 MB. Verify PPG site before use. |
| **AAUWSS** (used by `HrvGoldAgreementTest`) | PSG 200 Hz ECG + E4 wrist IBI windows per the Kotlin test header. | No public landing page was found this session (web search returned nothing under that name); treat its provenance as **unverified** until the fixture's README/URL is located. |

Not usable for HRV: PhysioNet `sleep-accel` (Walch 2019; HR + accelerometry, **no R-R**), Sleep-EDF
(no PPG). MIT-BIH NSR / nsr2db (ECG-only R-R) is the substrate Kim 2007 and Morelli 2019 used for
missing-data Monte Carlo and is appropriate for the same purpose here (page not fetched this session —
§8).

### 5.2 Metrics to report (per R4, instrument matched to question)

- **Agreement of nightly RMSSD vs reference**: Bland–Altman bias and 95 % LoA in ms **and** in ln units,
  ICC(2,1), Lin's CCC, MAPE; always next to the reference's own range (heteroscedasticity check as in
  Miller 2022).
- **Artifact detector**: sensitivity/specificity on injected missed/extra/misaligned beats (Lipponen's
  protocol) and on real wrist-PPG R-R vs ECG R-R (PPG-DaLiA / GalaxyPPG); fraction of beats modified
  (Alcantara 2020 shows this is the number that reveals over-correction).
- **Sparse-stream robustness**: Kim-style Monte Carlo — remove 0–100 s and random single beats from
  clean windows, report relative RMSSD error vs fraction removed, separately for deletion+skip,
  interpolation-on-time, and Lipponen correction.
- **Window floor sweep**: RMSSD error vs validPairs floor (20/30/50) on reference R-R subsampled to
  WHOOP-5.0-like density (≤ 4/s, 500-ms fillers injected and flagged).
- **Night-to-night reliability**: weekly CV of ln RMSSD (Bellenger 2022's 5.4 % on WHOOP 3.0 is the
  benchmark) for whole-night vs stationarity-selected windows.
- Every number with its regenerating command, date and input (R3); temporal hold-out (R5).

### 5.3 Validating with the owner's own data

- **Polar H10 as reference.** Gilgen-Ammann 2019: H10 R-R signal quality 99.6 % overall and 99.4 % at
  high intensity vs a Holter's 94.6 %, correlation r = 0.997; the authors suggest it "might be
  recommended as the gold standard for RR interval assessments". Plews 2017 and Hernando 2018 use Polar
  chest straps as the HRV reference. Wear H10 and WHOOP 5.0 simultaneously for ≥ 14 nights; record H10
  R-R with any app that exports per-beat R-R with timestamps.
- **Alignment.** Align by wall clock, then refine by cross-correlating 5-min mean R-R (both streams
  share HR). Do not align on RMSSD (R2: never score against the thing being tested).
- **Pre-register (R1)** before looking: whole-night RMSSD bias within ±8 ms (Miller 2022's WHOOP LoA)
  on `normal` nights; `limited` nights expected worse; the G1 floor change expected to reduce |bias| and
  LoA on nights with coverage < 0.95; stratum = tier; exclusion list = nights with H10 dropout > 10 %.
- **WHOOP CSV history** (from before the official app was removed) gives WHOOP's own nightly HRV for the
  same strap; it is a second estimate, not truth (R8), but the night-to-night CV of NOOP vs WHOOP can be
  compared.
- Keep all captures in `research-data/` (git-ignored); never paste row-level data.

---

## 6. Implementation sketch

All pseudocode is dependency-free, integer-safe where rounding matters, and written so the Swift and
Kotlin twins can be oracle-tested per `AGENTS.md`: compile the Swift helper standalone, print its output
over a spread of inputs (clean, dense, sparse, filler-laden, all-NaN, < 3 beats), paste that stdout as
the Kotlin expected literal. Quantile and median definitions are stated explicitly because that is where
two platforms silently diverge.

### 6.1 Lipponen–Tarvainen 2019 artifact classifier (deterministic port)

Inputs: `rr[]` in ms (already range-filtered, `tsSuspect = 0` only, chronological, with `gapBefore[i]`
true where a filler or a dropped beat precedes `i`). Constants from the reference implementation:
`ALPHA = 5.2`, `WIN = 91` (centred, odd), `MED = 11` (centred median), `C1 = 0.13`, `C2 = 0.17`.

```
dRR[i]   = rr[i] − rr[i−1]                       (dRR[0] = mean of the rest; never used across a gap:
                                                   if gapBefore[i], set dRR[i] = 0 and mark i unclassifiable)
medRR[i] = median(rr[i−5 … i+5])                 (edge: shrink window symmetrically, same rule both platforms)
mRR[i]   = rr[i] − medRR[i];  if mRR[i] < 0 then mRR[i] *= 2
th1[i]   = ALPHA · QD(|dRR| over centred window of WIN beats)   QD = (Q3 − Q1) / 2
th2[i]   = ALPHA · QD(|mRR| over the same window)
  Quantile definition: sort the window; Q = v[lo] + (v[hi] − v[lo]) · frac with p·(n−1) = lo + frac
  (this is NumPy's default linear interpolation, so results match the reference implementation).
nd[i]    = dRR[i] / th1[i]   (th1 == 0 → treat nd as 0)
nm[i]    = mRR[i] / th2[i]
s12[i]   = nd[i] > 0 ? max(nd[i−1], nd[i+1]) : min(nd[i−1], nd[i+1])     (reflect-pad by 2)
s22[i]   = nd[i] ≥ 0 ? min(nd[i+1], nd[i+2]) : max(nd[i+1], nd[i+2])

for each i with |nd[i]| > 1:
  ectopic  = (nd[i] > 1  and s12[i] < −C1·nd[i] − C2) or (nd[i] < −1 and s12[i] > −C1·nd[i] + C2)
  if ectopic → class[i] = ECTOPIC; continue
  candidates = {i} ∪ {i+1 if |nd[i+1]| < |nd[i+2]|}
  for j in candidates:
    long   = nd[j] >  1 and s22[j] < −1
    short  = nd[j] < −1 and s22[j] >  1
    either = |nm[j]| > 3
    missed = |rr[j]/2 − medRR[j]| < th2[j]
    extra  = |rr[j] + rr[j+1] − medRR[j]| < th2[j]
    if short and extra      → class[j] = EXTRA
    else if long and missed → class[j] = MISSED
    else if long or short or either → class[j] = LONGSHORT
```

Correction policy for NOOP (differs from Kubios, deliberately):

```
EXTRA     → merge rr[j] + rr[j+1] into one interval          (counts as one valid pair each side)
MISSED    → split rr[j] into two equal halves                 (the midpoint insertion of the reference)
ECTOPIC / LONGSHORT → DELETE and mark gapBefore on the successor   (no relocation, no interpolation:
                       relocation changes the two adjacent differences, which is exactly the quantity
                       RMSSD measures; deletion + skip is unbiased, per §2.5)
```

Run once (not iteratively) for determinism; emit counts per class to the `hrv diag` line. **Never apply
EXTRA/MISSED across a `tsSuspect` boundary.** Effort **M** (≈ 200–250 lines per platform plus the oracle
test over the whole-space sweep: clean, injected missed/extra/ectopic, NaN, length < WIN). Risk: medium
— the quantile and median edge rules are the parity hazard; a 50 ms–class tie must round identically
(use the `x + 0.5` truncation idiom already in `HRVAnalyzer.msToInt`). Land as instrumentation first:
log Malik-vs-LT RMSSD per night beside each other for several weeks before switching the read path (the
"validate against the artifact" rule).

### 6.2 Window quality and nightly tiers (G1, G7)

```
struct HrvWindowQuality { cleanBeats, validPairs, rejectedFraction, tier }
validPairs = count over i ≥ 1 of (contiguous[i] && !gapBefore[i] && |(ts[i]−ts[i−1]) − rr[i]/1000| ≤ 0.5)
tier per §4.3; sessionAvgHRV pools only non-refused windows;
nightTier per §4.3; AnalyticsEngine stores tier next to avgHrv (additive migration: new nullable column,
pinned by a migration test on both platforms) and Baselines.update skips `limited` nights the way it
already skips nil.
```

Effort **S** (the primitives exist; the work is threading `tsSec` into `sessionHrvWindows` and adding one
column). Risk: low for refuse/normal; the **limited** tier changes which nights seed the baseline, so it
must ship behind the experiment flag with the tier distribution logged first. Oracle: Swift stdout of
`(validPairs, tier)` over a fixed sweep of synthetic windows (dense, 4/s subsampled, with fillers, with
banked timestamps) pasted into the Kotlin test.

### 6.3 R-R-only stationarity selector (G5, experimental, default off)

```
for each non-refused 5-min window w: rrv[w] = SD of successive differences (or SDNN) over its valid pairs
rank windows by rrv ascending; take the lowest-quartile windows (≥ 3)
nightHrvStill = median(RMSSD over the selected windows)
```

Herzig's variant (correlation of successive R-R, detrended, first ≥ 10-min run 0.1 below its mean) is a
drop-in alternative; implement whichever is simpler to oracle-test (the quartile-rank version). Report
both `nightHrvStill` and the whole-night value in the trace; promote nothing until weekly CV and H10
agreement are measured on held-out nights. Effort **S**, risk low (display/trace only).

### 6.4 ln RMSSD baseline domain (G6)

Not implemented here; topic 06 owns the baseline machinery. The only input from this topic: whatever
machinery is chosen, the HRV term should be `ln(rmssd)` with an SWC band (0.5 × CV or ±0.5 SD), which
`HRVReadiness` already demonstrates on both platforms. Effort S inside that refactor.

### 6.5 What not to do

- No interpolation of missing beats on the 5.0 stream (Morelli 2019 is a spectral-domain result; for
  RMSSD it manufactures differences).
- No stage-labelled window selection (refuted on NOOP data; NOOP's labels are too noisy).
- No frequency-domain gate on sparse R-R (Hernando 2018: gaps break LF/HF even when RMSSD survives).
- No pNN50 in any gate (Kim 2007: most sensitive to missing data).

---

## 7. Sources (verified)

Each entry: citation, identifier, and what was verified from the fetched text.

1. Lipponen JA, Tarvainen MP. A robust algorithm for heart rate variability time series artefact
   correction using novel beat classification. *J Med Eng Technol* 2019;43(3):173–181. DOI
   10.1080/03091902.2019.1640306, PMID 31314618. Verified (abstract): time-varying thresholds from
   successive-difference distribution + beat classification; sensitivity 100 % simulated missed/extra,
   96.96 % real ectopic, specificity 99.94 %; mean HRV error < 2 % after correction (< 8 % worst case).
2. NeuroKit2 reference implementation of the above, `neurokit2/signal/signal_fixpeaks.py` (GitHub
   master, fetched). Verified: `c1 = 0.13`, `c2 = 0.17`, `alpha = 5.2`, `window_width = 91`,
   `medfilt_order = 11`; threshold `alpha · (Q3 − Q1)/2`; subspace rules s12/s22; eq1–eq7 as in §6.1;
   corrections = delete extra, insert midpoint for missed, relocate ectopic/long-short to midpoint.
3. Alcantara JMA et al. Impact of using different levels of threshold-based artefact correction on the
   quantification of heart rate variability in three independent human cohorts. *J Clin Med*
   2020;9(2):325. DOI 10.3390/jcm9020325, PMID 31979367 (Europe PMC full text). Verified: Kubios
   thresholds Very Low 0.45 s / Low 0.35 / Medium 0.25 / Strong 0.15 / Very Strong 0.05 vs a
   median-filtered local average; cubic-spline interpolation; Very Strong interpolated 17–39 % of beats.
4. Bellenger CR, Miller DJ, Halson SL, Roach GD, Sargent C. Wrist-based photoplethysmography assessment
   of heart rate and heart rate variability: validation of WHOOP. *Sensors* 2021;21(10):3571. DOI
   10.3390/s21103571, PMID 34065516 (abstract + PMC full text). Verified: WHOOP 2.0, 6 adults, 15 nights,
   final 5 min of final SWS; Ln RMSSD bias 1.66 ± 1.80 %, LoA ±5.93 % at 200 ms/proprietary filter; HR
   bias ≤ 0.39 %, LoA ≤ 1.56 %; erratum exists (Sensors 2022;22(8):3090, PMID 35459085).
5. Bellenger CR et al. Evaluating the typical day-to-day variability of WHOOP-derived heart rate
   variability in Olympic water polo athletes. *Sensors* 2022;22(18):6723. DOI 10.3390/s22186723, PMID
   36146073. Verified: 11 athletes, 16 weeks, WHOOP 3.0 overnight; weekly lnRMSSD CV 5.4 ± 0.7 %, HR CV
   7.6 ± 1.3 %.
6. Miller DJ, Sargent C, Roach GD. A validation of six wearable devices for estimating sleep, heart rate
   and heart rate variability in healthy adults. *Sensors* 2022;22(16):6317. DOI 10.3390/s22166317, PMID
   36016077 (abstract + PMC full text). Verified: 53 adults, one PSG/ECG night; RMSSD bias/LoA/ICC per
   device as tabulated in §2.6 (WHOOP 3.0 −4.5 ± 3.9 ms, ±7.6, ICC 0.99 over whole sleep).
7. Kinnunen H, Rantanen A, Kenttä T, Koskimäki H. Feasible assessment of recovery and cardiovascular
   health: accuracy of nocturnal HR and HRV assessed via ring PPG in comparison to medical grade ECG.
   *Physiol Meas* 2020;41(4):04NT01. DOI 10.1088/1361-6579/ab840a, PMID 32217820. Verified: 49 adults;
   nightly HR r² 0.996 bias −0.63 bpm; HRV r² 0.980 bias −1.2 ms; 5-min segments r² 0.765 ± 0.178.
8. Sarhaddi F et al. A comprehensive accuracy assessment of Samsung smartwatch heart rate and heart rate
   variability. *PLoS ONE* 2022;17(12):e0268361. DOI 10.1371/journal.pone.0268361, PMID 36480505.
   Verified: 28 adults, 24 h vs Shimmer3 ECG; time-domain HRV acceptable during sleep, poor awake.
9. Stone JD et al. Assessing the accuracy of popular commercial technologies that measure resting heart
   rate and heart rate variability. *Front Sports Act Living* 2021;3:585870. DOI
   10.3389/fspor.2021.585870, PMID 33733234. Verified: 5 adults, 148 trials; rMSSD MAPE HRV4Training
   4.10 % (CCC 0.98), Oura 6.84 % (CCC 0.91), CameraHRV 112 %.
10. Hernando D, Roca S, Sancho J, Alesanco Á, Bailón R. Validation of the Apple Watch for heart rate
    variability measurements during relax and mental stress in healthy subjects. *Sensors*
    2018;18(8):2619. DOI 10.3390/s18082619, PMID 30103376. Verified: 20 subjects vs Polar H7; agreement
    > 0.9; gaps (5 per recording, 6.5 s) did not significantly affect temporal indices, did reduce LF/HF.
11. Plews DJ, Scott B, Altini M, Wood M, Kilding AE, Laursen PB. Comparison of heart-rate-variability
    recording with smartphone photoplethysmography, Polar H7 chest strap, and electrocardiography.
    *IJSPP* 2017;12(10):1324–1328. DOI 10.1123/ijspp.2016-0668, PMID 28290720. Verified: 29 subjects;
    rMSSD TEE CV 6.35 %, R = 1.00, trivial standardised differences.
12. Schäfer A, Vagedes J. How accurate is pulse rate variability as an estimate of heart rate
    variability? A review. *Int J Cardiol* 2013;166(1):15–29. DOI 10.1016/j.ijcard.2012.03.119, PMID
    22809539. Verified: sufficient at rest; short-term variability "somewhat overestimated by PRV";
    activity impairs agreement.
13. Georgiou K et al. Can wearable devices accurately measure heart rate variability? A systematic
    review. *Folia Med (Plovdiv)* 2018;60(1):7–20. DOI 10.2478/folmed-2018-0012, PMID 29668452.
    Verified: 18 studies; very good to excellent at rest, declines with exercise.
14. Baek HJ, Cho CH, Cho J, Woo JM. Reliability of ultra-short-term analysis as a surrogate of standard
    5-min analysis of heart rate variability. *Telemed J E Health* 2015;21(5):404–414. DOI
    10.1089/tmj.2014.0104, PMID 25807067. Verified: 467 healthy, 8–69 y; minimum 30 s for RMSSD, 60 s
    pNN50, 240 s SDSD, 90 s LF/HF.
15. Munoz ML et al. Validity of (ultra-)short recordings for heart rate variability measurements. *PLoS
    ONE* 2015;10(9):e0138921. DOI 10.1371/journal.pone.0138921, PMID 26414314. Verified: 3,387 adults;
    RMSSD r 0.85–0.86 at 10 s, 0.94 averaging three 10-s strips, 0.986 at 120 s; RMSSD outperformed SDNN
    at every length.
16. Esco MR, Flatt AA. Ultra-short-term heart rate variability indexes at rest and post-exercise in
    athletes. *J Sports Sci Med* 2014;13(3):535–541. PMID 25177179, PMC4126289. Verified: 23 athletes;
    lnRMSSD 60 s ICC 0.98, LoA 0.00 ± 0.22; 30 s −0.07 ± 0.41; 10 s −0.20 ± 0.94.
17. Nussinovitch U et al. Reliability of ultra-short ECG indices for heart rate variability. *Ann
    Noninvasive Electrocardiol* 2011;16(2):117–122. DOI 10.1111/j.1542-474X.2011.00417.x, PMID 21496161.
    Verified: 70 healthy; RMSSD reliable at 1 min and 10 s, SDNN not.
18. Salahuddin L, Cho J, Jeong MG, Kim D. Ultra short term analysis of heart rate variability for
    monitoring mental stress in mobile settings. *IEEE EMBC* 2007:4656–4659. DOI
    10.1109/IEMBS.2007.4353378, PMID 18003044. Verified: RMSSD/pNN50 reliable within 30 s.
19. Pecchia L, Castaldo R, Montesinos L, Melillo P. Are ultra-short heart rate variability features good
    surrogates of short-term ones? *Healthc Technol Lett* 2018;5(3):94–100. DOI 10.1049/htl.2017.0090,
    PMID 29922478. Verified: of 29 reviewed papers only one used a rigorous method; proposes a protocol
    for assessing ultra-short reliability (use it in §5.2).
20. Castaldo R et al. Ultra-short term HRV features as surrogates of short term HRV: a case study on
    mental stress detection in real life. *BMC Med Inform Decis Mak* 2019;19:12. DOI
    10.1186/s12911-019-0742-y, PMID 30654799. Verified: 42 subjects; MeanNN, StdNN, HF consistent from 5
    to 1 min.
21. Shaffer F, Ginsberg JP. An overview of heart rate variability metrics and norms. *Front Public
    Health* 2017;5:258. DOI 10.3389/fpubh.2017.00258, PMID 29034226 (PMC full text). Verified: RMSSD as
    primary vagal time-domain index; 5-min conventional minimum; UST summary (RMSSD 10 s Salahuddin,
    30 s Baek, 60 s); 5-min norms RMSSD 42 ± 15 ms, SDNN 50 ± 16 ms; single artifact can eclipse 0.5–1.0
    ln effect sizes.
22. Buchheit M. Monitoring training status with HR measures: do all roads lead to Rome? *Front Physiol*
    2014;5:73. DOI 10.3389/fphys.2014.00073, PMID 24578692 (Europe PMC full text). Verified: vagal
    indices capturable in 10 s–1 min; Ln rMSSD typical error ≈ 12 % CV, SWC ≈ 3 %; SWC = 0.5 or 1 × CV;
    single ectopic/skipped beat can change indices up to 50 %; night and SWS recordings as the most
    standardised condition; morning 5–10 min supine/seated as field practice.
23. Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate
    variability in elite endurance athletes: opening the door to effective monitoring. *Sports Med*
    2013;43(9):773–781. DOI 10.1007/s40279-013-0071-8, PMID 23852425. Verified (abstract): appropriate
    averaging techniques and saturation-aware indices; longitudinal individual fingerprint.
24. Plews DJ, Laursen PB, Kilding AE, Buchheit M. Heart rate variability in elite triathletes, is
    variation in variability the key to effective training? *Eur J Appl Physiol* 2012;112(11):3729–3741.
    DOI 10.1007/s00421-012-2354-4, PMID 22367011. Verified: 7-day rolling Ln rMSSD and its CV over 77
    days; NFOR athlete slope −0.17 ms/week, CV −0.65 %/week; control stable.
25. Plews DJ et al. Monitoring training with heart rate-variability: how much compliance is needed for
    valid assessment? *IJSPP* 2014;9(5):783–790. DOI 10.1123/ijspp.2013-0455, PMID 24334285. Verified:
    plateau after 3–4 averaged days; minimum 3 valid points per week.
26. Flatt AA, Esco MR, Nakamura FY. Individual heart rate variability responses to preseason training in
    high level female soccer players. *J Strength Cond Res* 2017;31(2):531–538. DOI
    10.1519/JSC.0000000000001482, PMID 27227794. Verified: weekly lnRMSSD means; r = −0.85 with training
    load change.
27. Nakamura FY et al. Monitoring weekly heart rate variability in futsal players during the preseason.
    *J Sports Sci* 2016;34(24):2262–2268. DOI 10.1080/02640414.2016.1186282, PMID 27214584. Verified:
    ln RMSSDWeekly and ln RMSSDCV as the monitoring pair; r = −0.53 between them.
28. Flatt AA, Esco MR. Validity of the ithlete smart phone application for determining ultra-short-term
    heart rate variability. *J Hum Kinet* 2013;39:85–92. DOI 10.2478/hukin-2013-0071, PMID 24511344.
    Verified: 25 adults; r = 0.99 vs ECG; LoA −2.57 to +2.63 around −0.03.
29. Altini M, Plews D. What is behind changes in resting heart rate and heart rate variability? A
    large-scale analysis of longitudinal measurements acquired in free-living. *Sensors*
    2021;21(23):7932. DOI 10.3390/s21237932, PMID 34883936. Verified: 28,175 people, 9 M measurements;
    HRV −12 % after high alcohol, −10 % during sickness, 4.6 % change with training; "sensitive but not
    specific".
30. Herzig D et al. Reproducibility of heart rate variability is parameter and sleep stage dependent.
    *Front Physiol* 2018;8:1100. DOI 10.3389/fphys.2017.01100, PMID 29367845. Verified: 15 males × 3 PSG
    nights; HR and HF reproducible in SWS; LF/LF-HF poor in all stages; R-R-only selector found SWS 87 %.
31. Brandenberger G, Buchheit M, Ehrhart J, Simon C, Piquard F. Is slow wave sleep an appropriate
    recording condition for heart rate variability analysis? *Auton Neurosci* 2005;121(1–2):81–86. DOI
    10.1016/j.autneu.2005.06.002, PMID 16005265. Verified: 16 adults; SDNN 54.3 vs 78.8 ms (SWS vs quiet
    wake), HFnu 0.57 vs 0.51, respiratory SD 0.27 vs 0.42 s.
32. Buchheit M, Simon C, Piquard F, Ehrhart J, Brandenberger G. Effects of increased training load on
    vagal-related indexes of heart rate variability: a novel sleep approach. *Am J Physiol Heart Circ
    Physiol* 2004;287(6):H2813–H2818. DOI 10.1152/ajpheart.00490.2004, PMID 15308479. Verified: 5-min
    SWS segments "offer high electrocardiographic stationarity"; SWS discriminates training state better
    than waking.
33. Boudreau P, Yeh WH, Dumont GA, Boivin DB. Circadian variation of heart rate variability across sleep
    stages. *Sleep* 2013;36(12):1919–1928. DOI 10.5665/sleep.3230, PMID 24293767. Verified: deeper NREM →
    parasympathetic, REM → sympathetic; SWS parasympathetic peak ≈ 02:00.
34. Stein PK, Pu Y. Heart rate variability, sleep and sleep disorders. *Sleep Med Rev* 2012;16(1):47–66.
    DOI 10.1016/j.smrv.2011.02.005, PMID 21658979. Verified (abstract): review scope and caveats for
    interpreting sleep HRV.
35. Kim KK, Lim YG, Kim JS, Park KS. Effect of missing RR-interval data on heart rate variability
    analysis in the time domain. *Physiol Meas* 2007;28(12):1485–1494. DOI 10.1088/0967-3334/28/12/003,
    PMID 18057513. Verified: 2,615 tachograms, 0–100 s removed; MeanNN most robust, pNN50 most sensitive;
    real sleep errors may exceed simulation.
36. Kim KK, Kim JS, Lim YG, Park KS. The effect of missing RR-interval data on heart rate variability
    analysis in the frequency domain. *Physiol Meas* 2009;30(10):1039–1050. DOI
    10.1088/0967-3334/30/10/005, PMID 19713596. Verified (abstract): interpolation/spectral methods under
    missing data.
37. Kim KK, Baek HJ, Lim YG, Park KS. Effect of missing RR-interval data on nonlinear heart rate
    variability analysis. *Comput Methods Programs Biomed* 2012;106(3):210–218. DOI
    10.1016/j.cmpb.2010.11.011, PMID 21194782. Verified: non-linear measures except Poincaré unsuitable
    with missing data.
38. Morelli D, Rossi A, Cairo M, Clifton DA. Analysis of the impact of interpolation methods of missing
    RR-intervals caused by motion artifacts on HRV features estimations. *Sensors* 2019;19(14):3163. DOI
    10.3390/s19143163, PMID 31323850. Verified: interpolate on time, not duration; duration interpolation
    distorts the spectrum.
39. Karlsson M, Hörnsten R, Rydberg A, Wiklund U. Automatic filtering of outliers in RR intervals before
    analysis of heart rate variability in Holter recordings. *Biomed Eng Online* 2012;11:2. DOI
    10.1186/1475-925X-11-2, PMID 22236441. Verified: recursive mean-of-neighbours filter, 10–50 % limits,
    age-based threshold reproduces edited data.
40. Citi L, Brown EN, Barbieri R. A real-time automated point-process method for the detection and
    correction of erroneous and ectopic heartbeats. *IEEE Trans Biomed Eng* 2012;59(10):2828–2837. DOI
    10.1109/TBME.2012.2211356, PMID 22875239. Verified: inverse-Gaussian point-process model; best
    specificity/sensitivity on Fantasia and MIT-BIH among compared methods.
41. Peltola MA. Role of editing of R-R intervals in the analysis of heart rate variability. *Front
    Physiol* 2012;3:148. DOI 10.3389/fphys.2012.00148, PMID 22654764. Verified: deletion, interpolation
    and filtering have setting-dependent effects.
42. Berntson GG, Quigley KS, Jang JF, Boysen ST. An approach to artifact identification: application to
    heart period data. *Psychophysiology* 1990;27(5):586–598. DOI 10.1111/j.1469-8986.1990.tb01982.x,
    PMID 2274622. Verified: subject-specific percentile-based criterion; 1,494 artifacts flagged, < 0.3 %
    false alarms.
43. Gilgen-Ammann R, Schweizer T, Wyss T. RR interval signal quality of a heart rate monitor and an ECG
    Holter at rest and during exercise. *Eur J Appl Physiol* 2019;119(7):1525–1532. DOI
    10.1007/s00421-019-04142-5, PMID 31004219. Verified: Polar H10 99.6 % R-R quality, 99.4 % at high
    intensity, r = 0.997 vs Holter.
44. Task Force of the ESC and NASPE. Heart rate variability: standards of measurement, physiological
    interpretation and clinical use. *Circulation* 1996;93(5):1043–1065. PMID 8598068. Verified: PubMed
    record only (no abstract indexed; full text at ESC/AHA/OUP returned 403). Definitions used here are
    taken from Shaffer & Ginsberg 2017 (fetched), which reproduces them.
45. Miller DJ et al. A validation study of the WHOOP strap against polysomnography to assess sleep. *J
    Sports Sci* 2020;38(22):2631–2636. DOI 10.1080/02640414.2020.1797448, PMID 32713257. Verified: WHOOP
    4-stage κ 0.47, SWS sensitivity 68 % — relevant to how well a WHOOP-style "last SWS" window can be
    located at all.
46. Reiss A, Indlekofer I, Schmidt P, Van Laerhoven K. Deep PPG: large-scale heart rate estimation with
    convolutional neural networks. *Sensors* 2019;19(14):3079. DOI 10.3390/s19143079, PMID 31336894.
    Verified: introduces PPG-DaLiA.
47. Park S, Zheng D, Lee U. A PPG signal dataset collected in semi-naturalistic settings using Galaxy
    Watch (GalaxyPPG). *Sci Data* 2025;12:892. DOI 10.1038/s41597-025-05152-z (PMC full text) and Zenodo
    record 14635823. Verified: devices, rates, protocol, CC BY 4.0, 481.6 MB; wrist RMSSD/SDNN differed
    substantially from ECG across activities.
48. Dataset pages fetched: DREAMT v2.2.0 (PhysioNet), PPG-DaLiA and WESAD (UCI), Wrist PPG During
    Exercise, Pulse Transit Time PPG, BIDMC, MIMIC-III Waveform (PhysioNet), Zenodo 4326598. Details in
    §5.1.

---

## 8. Unverified leads

Not fetched this session, or fetched without the content needed. No recommendation above rests on them.

- **Lam E et al. 2020**, "Measuring heart rate variability in free-living conditions using
  consumer-grade photoplethysmography: validation study", *JMIR Biomed Eng* 2020;5(1):e17355 (DOI
  10.2196/17355). The DOI resolves but the JMIR page returned empty content and the paper is not indexed
  in PubMed/Europe PMC; no numbers taken.
- **Task Force 1996 full text** (ESC PDF, OUP and AHA pages all 403). Record verified; content used only
  via Shaffer & Ginsberg 2017.
- **WHOOP's own HRV explainer** (`whoop.com/thelocker/heart-rate-variability-hrv/`), 403 to the fetcher;
  a search snippet says WHOOP uses RMSSD "during your deepest sleep each night". The method as actually
  described in a peer-reviewed study (Bellenger 2021: final 5 min of final SWS) is what §2.3 relies on.
- **Kubios HRV User's Guide PDF** downloaded but image-only (no text layer); the threshold levels and
  cubic-spline correction were instead verified through Alcantara 2020's description of the software.
- **"Kubios threshold-based artefact correction affects HRV parameters in elite athletes"** (J Sci Sport
  Exerc 2022, DOI 10.1007/s42978-022-00210-z): surfaced by search with the claim that Medium/Strong/Very
  Strong interpolated > 5 % of beats in 3.4 / 28.2 / 95 % of athlete recordings; not fetched.
- **Malik et al. 1989** (the "20 % rule" NOOP's header cites): not fetched; the rule's provenance is
  cited in code, not re-verified here.
- **Le Meur 2013, Pichot 2000, Nunan 2010, Seppälä, Kiviniemi 2004**: cited inside Buchheit 2014 /
  Shaffer 2017 for the SWC = 0.5 × CV convention, night recordings, 5-min norms, 1-min RMSSD and the
  1000-ms saturation point; secondary citations only.
- **MIT-BIH Normal Sinus Rhythm RR Interval Database (nsr2db)** page not fetched; named here only as
  the substrate Kim 2007 and Morelli 2019 report using.
- **AAUWSS**: used by NOOP's Kotlin fixture tests; no public landing page located by search this
  session.
- **BiHeartS** (arXiv 2308.06811): 10 participants × 30 nights, "research-grade and commercial
  wearables"; the arXiv page does not name devices, PSG or a download URL.

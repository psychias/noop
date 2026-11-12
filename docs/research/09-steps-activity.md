# 09 — Steps and activity from the accelerometer

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Every source in
§7 was fetched this session (Europe PMC REST for abstracts and open-access full text, Crossref for
metadata, publisher / archive pages where they answered). Numbers quoted are from the fetched abstract
or full text, not from memory. Non-medical wording throughout: steps and activity classes are
approximations of behaviour, not clinical measurements.

The short version. On a WHOOP 5.0 the strap's own hardware pedometer is the only step signal NOOP has
continuously, and it is a black box: NOOP cannot change how it detects a step, only how it reads,
gates and calibrates the counter. The always-on motion stream is a ~1 Hz gravity vector with gaps,
which physically cannot resolve a 1.5–3 Hz gait, so there is no software step counter to build on it.
The 100 Hz IMU exists only as an opt-in capture, where the literature offers well-validated open
algorithms (12–17 % MAPE free-living at best). The realistic improvements are therefore (a) a
data-derived calibration and plausibility band for the counter, validated against the owner's phone
and manual counts, and (b) an optional research-grade step counter over captured IMU, used to
*measure* the strap counter rather than replace it.

---

## 1. What NOOP does today

| Concern | Swift (`Packages/StrandAnalytics/Sources/StrandAnalytics/`) | Kotlin (`android/app/src/main/java/com/noop/analytics/`) |
|---|---|---|
| Tick → step kernel | `StepsCounter.stepsInWindow` | `StepsCounter.stepsInWindow` |
| Sleep gating | `SleepAwareStepCounter` | `SleepAwareStepCounter` |
| 4.0 motion-volume estimate | `StepsEstimateEngine` | `StepsEstimateEngine` |
| Day-cycle ownership | `PhysiologicalSteps` | `PhysiologicalSteps`, `PhysiologicalStepCycleEngine` |
| 100 Hz IMU features | `ImuFeatureExtractor` | `ImuFeatureExtractor` |
| Coarse sport class | `WorkoutTypeClassifier` | — (Swift-first, per header) |
| Sedentary bouts | `SedentaryDetector` | `ActivityDetector.detectSedentaryBouts` (PR #419 origin) |
| Daily total | `AnalyticsEngine.analyzeDay` (~L1032–1046) | `AnalyticsEngine.kt` |

**Input (WHOOP 5.0).** R18 record byte 57 is a cumulative u16 "step/motion" counter; byte 63 the
activity class (0 still / 1 walk / 2 run; everything else → `FF`); byte 59 a cadence-like raw byte
that `docs/PROTOCOL_SENSORS.md` says is *not* a documented steps-per-minute conversion; bytes 61/64
carry the hardware count when a software override is active. Rollover, reset and day boundaries are
documented as unresolved, and "neither counter is established as equal to the official app's
aggregated step count". The always-on motion stream is byte 41 (dynamic accel, g) plus bytes 45–56
(gravity x/y/z, f32), nominally 1 Hz and sparse in practice (`00-inventory.md` §1). The 100 Hz
six-axis IMU (R21, types 51/52) arrives only through the opt-in Raw Data Collector (commands 81/106)
and is stored in file-backed `.imus` segments, not SQLite (`docs/RAW_DATA_CAPTURE.md`).

**Method (shipped, both platforms, byte-identical).**

1. `StepsCounter.stepsInWindow`: sort by `ts`; per adjacent pair `delta = (cur − prev) & 0xFFFF`
   (wrap-aware); attribute the increment to the later sample; keep it only if that sample's
   `activityClass ∈ {1, 2}` (walk/run) — a wholly unclassed legacy window keeps every increment;
   `isPlausibleDelta` rejects `delta < 1`, `delta ≥ maxStepDelta (512)`, non-positive elapsed time,
   and any delta above `elapsed × maxTicksPerSecond (4)` (capped at 511). Returns `nil` for < 2 samples
   or zero retained ticks.
2. `AnalyticsEngine.analyzeDay`: filter samples to the local calendar day, run the kernel, then
   `steps = round(ticks / max(profile.stepTicksPerStep, 0.5))`. `stepTicksPerStep` defaults to 1.0
   (raw pass-through) and is user-set; there is no auto-fit on the 5.0 path. Comment history (#132,
   #276, #316, #139) records the earlier 24× over-count from summing the running total and that the
   "5/MG counter overcounts and its true tick rate is unknown".
3. `SleepAwareStepCounter`: inside a detected sleep session, ticks are accepted only as gait bouts
   (`maxSecondsBetweenGaitDeltas 3`, `minGaitBoutDurationSeconds 4`, `minGaitBoutActiveSamples 5`,
   `minGaitBoutTicks 6`); isolated in-sleep ticks are rejected and every rejection class is counted
   (class-rejected, implausible, isolated-sleep) so the funnel is auditable.
4. `StepsEstimateEngine` (WHOOP 4.0 only): `steps ≈ k · motionVolume`, through-origin, `k` = a
   motion-weighted median of per-day `steps/motion` ratios against phone steps; `minCalibrationDays 3`,
   `goodCalibrationDays 14`, `minMotionForFit 1.0`, `maxDailySteps 60_000`; confidence tiers at
   0.34 / 0.67. This is the only per-user step calibration *estimator* in the tree, and it is not
   wired to the 5.0 counter.
5. `ImuFeatureExtractor.extract` (research): over a 100 Hz window computes accel-AC RMS, gyro mean
   magnitude, jerk RMS and a normalized-autocorrelation cadence peak in `cadenceBand 1.2…3.5 Hz`
   (`minCadenceStrength 0.20`). Its header states the Nyquist argument explicitly ("a 1.8 Hz step
   rate is above the 1 Hz stream's Nyquist limit") and that cadence is a feature, never a gate.
   Nothing scores from it.
6. `WorkoutTypeClassifier` reads the class-byte composition, HR shape and the ~1 Hz gravity-delta
   series, and deliberately refuses spectral/autocorrelation cadence on that stream (file header cites
   the withdrawn PPG→HR estimate #194). `SedentaryDetector` uses smoothed gravity delta (desk ≈
   0.05–0.10 g, walking ≈ 0.2–0.4 g per its header), not steps, because the 4.0 has no counter.
7. **Energy.** Daily `activeKcalEst` is HR-only (`Calories.estimateDayCalories`, Keytel 2005 active +
   revised Harris–Benedict resting). Steps do **not** feed energy or strain anywhere in
   `AnalyticsEngine`/`StrainScorer` today; the "step/active-energy floor" named in the brief is not
   present in the code as read.

**Cited in code:** no step-counting literature at all; the only references are issue numbers and the
Nyquist remark. **Tests:** `StepsCounterTests`, `StepsDailyTests`, `StepsDetailDensityTests`,
`SleepAwareStepCounterTests`, `StepsEstimateEngine*Tests`, `StepsMotionCacheTests`,
`ImuFeatureExtractorTests` (recovers multiple injected cadences); Kotlin twins. There is no harness
that compares the counter with any reference, and `docs/VALIDATION_PROTOCOL.md` R4 records that the
remembered "wrist ticks are 2–6× phone steps" band held on only 57 % of 30 qualifying days, every
violation on the low side.

---

## 2. Recommended method(s) from the literature

### 2.1 What a wrist step count can be expected to achieve (sets the bar for the strap's counter)

- **Treadmill, normal speeds.** Moore et al. 2020 (scoping review of 77 treadmill validation studies,
  weighted median MAPE at 1.1–1.8 m/s): **wrist 7–11 %**, waist 1–4 %, thigh ≤ 1 % [S14].
  Mora-Gonzalez et al. 2022 (CADENCE-adults, n = 258, 21 devices, direct observation): wrist **15 %**
  MAPE across normal speeds vs ankle/thigh 1 % and waist 3 %; **all devices ~40 % MAPE at slow
  speeds (0.8–3.2 km/h)**; wrist ActiGraph GT9X 52 % [S13].
- **Free-living, video criterion.** Toth et al. 2018 (12 adults, GoPro all waking hours, hand tally):
  wrist Fitbit Charge recorded 69–84 % of true steps; wrist ActiGraph 109–122 % (no-LFE) and
  128–220 % (LFE); ankle StepWatch 95.3–102.8 % [S11]. Small et al. 2024: "error routinely above
  20 % in wrist-worn devices against camera-annotated ground truth" [S1].
- **Consumer-device reviews.** Fuller et al. 2020 (158 publications, 9 brands): steps accurate in
  laboratory settings for Fitbit, Apple Watch, Samsung; varies by device; energy expenditure
  inaccurate for every brand [S9]. Feehan et al. 2018 (67 Fitbit studies): acceptable accuracy
  (±3 % controlled, ±10 % free-living) "approximately half the time"; **undercount in controlled
  testing, overcount in free-living**; best on the wrist during jogging, worst at slow walking [S10].
- **Gait regularity dominates.** Mattfeld et al. 2021 (Clemson, 30 participants, 60,805 video-annotated
  steps, Shimmer3 at 15 Hz on wrist/hip/ankle): all three algorithm families 3–8 % error on regular
  gait regardless of site; 7–34 % on semi-regular and **11–466 % on unstructured gait**; the
  autocorrelation algorithm stayed under 12 % across gait types; the adjacent wrist Fitbit Charge 2
  read 0.97 ± 0.07 of steps on regular, 1.08 ± 0.21 semi-regular, 1.00 ± 0.38 unstructured [S16].
- **Steps/day interpretation.** Tudor-Locke et al. 2011: healthy adults 4,000–18,000 steps/day,
  10,000 reasonable; ≥ 100 steps/min a floor for moderate intensity; 7,000–8,000 steps/day as a direct
  free-living estimate of minimal MVPA [S19]. Tudor-Locke et al. 2018 (38 studies): ≥ 100 steps/min ≈
  3 METs; population mean cadence 7.7 steps/min because 13.5 h/day sit below 60 steps/min [S20].
  Bassett et al. 2017: steps have biological day-to-day variability, so **3–7 days** of monitoring are
  needed for a valid estimate; accuracy standards and placement sites are still unsettled [S12].

**Implication.** Even a well-engineered wrist counter will disagree with an ankle or video criterion by
on the order of 10–20 % on an ordinary day and far more on slow or fragmented walking. Any
plausibility band NOOP derives for the strap's counter must be wide enough to contain that, and must
be stated as a percentile of observed days (R4), not an invariant.

### 2.2 Open step-detection algorithms for a wrist accelerometer (only relevant to the 100 Hz capture)

| Family | Representative, verified | Core idea | Reported accuracy |
|---|---|---|---|
| Peak detection with gait constraints | Gu et al. 2017 (IEEE Sensors J; metadata via Crossref, method as re-described by Mattfeld 2021 and Maylor 2022) [S17]; **Verisense** (Patterson; R source fetched) [S5]; GGIR integration [S7] | Vector magnitude → block maxima (`k`) → keep peaks above a magnitude threshold, with inter-peak period in `[period_min, period_max]`, amplitude similarity, and a variance-based continuity test; per-second counts | Rowlands 2022 (98 adults, 6 walks 92.9–127.9 steps/min, waist ActiGraph criterion): original MAPE 17–22 %, bias −21 to −26 steps/min; revised MAPE **~10–12 %**, bias ~−10 to −12 steps/min, LoA ~±30 steps/min [S6]. Maylor 2022 (n = 713, activPAL thigh criterion, free-living): v1 +913 steps/day with proportional bias (under-count above ~13,000/day), v2 **+742 steps/day = +7.9 %** with no proportional bias, but MVPA steps −1,204/day [S4]. On OxWalk (video) Verisense gave **63.5 % MAPE** [S1]. |
| Threshold crossing | Ducharme et al. 2021 (75 adults, treadmill 0.22–2.2 m/s + ADL, hand tally) [S15] | Demean, band-pass **0.25–2.5 Hz**, peak-pick the vector magnitude above a fixed threshold: **0.0359 g wrist**, 0.0267 g waist | Wrist RMSE < 481 steps (≤ 6.47 steps/min) across all activities, beating ActiLife (RMSE 2,913). But on free-living OxWalk: **231 % MAPE, +69 % bias** [S1]; on Clemson 47.5 % MAPE [S1]. |
| Autocorrelation / periodicity | Femiano et al. 2022 (22 cardiac-rehab patients, Axivity AX3 wrist, chest GoPro) [S3]; Mattfeld 2021 [S16] | Normalized autocorrelation over a sliding window; pick the lag with the strongest peak inside the gait band; count cycles; idle check on magnitude | Femiano: MAPE close to or below 10 % for walking, running, stairs, Nordic walking for both windowed peak detection and autocorrelation; over-count during arm movement without walking, under-count during walking/running/stairs [S3]. Mattfeld: < 12 % error on every gait type [S16]. |
| Template / stride segmentation | Karas et al. 2021 ADEPT (Biostatistics; 32 participants, 450 m outdoor walk, wrist/hip/ankle; R package GPL-3) [S18] | Covariance between data and scaled/translated data-derived stride templates (wavelet-like) | Validated for stride segmentation; no free-living step MAPE in the abstract. |
| Walking classifier + peak detection | **Small et al. 2024** (MSSE; OxWalk training n = 39, Clemson external n = 30; UK Biobank 75,263) [S1] | Self-supervised ResNet classifies 10-s/30-s windows as walking; peak detection (SciPy `find_peaks`, Euclidean norm −1 g, clipped ±2 g, 4th-order Butterworth low-pass 5 Hz) only inside walking windows | **12.5 % MAPE free-living, −1.3 % bias, r = 0.98** on OxWalk (cross-validated) vs 65–231 % for the reference models; walking-bout κ = 0.79. Software `stepcount` is under Oxford's **Academic Use Licence** (non-commercial, no product integration) [S2]. |
| Comparative | Marcotte et al. 2025 (21 adults, ActiGraph CPIW wrist, motion-capture heel strikes + StepWatch) [S21] | Four open methods compared | Single-parameter methods (peak / threshold) had the lowest bias in structured walking; the frequency-analysis method the lowest free-living error; **adding a locomotion classifier reduced error for two methods**. |

**Convergent finding.** Two independent groups (Small 2024, Marcotte 2025) found that gating step
detection on a "currently walking" classifier is what rescues free-living accuracy; raw peak or
threshold detectors over-count arm movement by 1.5–3×. This is structurally what the WHOOP firmware
already appears to do (a class byte alongside the counter) and what `StepsCounter` enforces by
discarding still-class ticks. The literature therefore endorses NOOP's gating design; it says nothing
about the strap's internal detector, which NOOP cannot observe.

### 2.3 Sampling-rate requirement (why 1 Hz gravity cannot count steps)

- Preferred walking cadence is 2 Hz (SD 0.13) across a full day of natural locomotion in 20 subjects,
  matching the 1.95 Hz (SD 0.19) laboratory value of Murray et al. 1964, with no dependence on sex,
  age, height, weight or BMI (MacDougall & Moore 2005) [S22]. Rowlands' walks spanned 92.9–127.9
  steps/min (1.55–2.13 Hz) [S6]; Ducharme's band-pass is 0.25–2.5 Hz [S15]; `ImuFeatureExtractor`
  searches 1.2–3.5 Hz to include running.
- Nyquist requires sampling at > 2× the highest gait frequency, i.e. > 5 Hz for a 2.5 Hz cadence, and
  in practice more: Quisbert-Trujillo & Vuillerme 2026 downsampled wrist signals and found 70–90 % of
  information lost at 2–5 Hz, < 24 % lost from 20 Hz, and step-counting "expected to be acceptable
  from approximately 11 Hz onward" [S23]. Validated open algorithms run at 15 Hz (Clemson/Verisense
  [S5][S16]), 25 Hz and 100 Hz (OxWalk [S2]), 100 Hz (CAPTURE-24 [S24]).
- A ~1 Hz gravity vector with multi-minute gaps is therefore an order of magnitude too slow. Any
  periodicity found in it sits at the record period, which is the artefact `AGENTS.md` warns about
  and the reason `WorkoutTypeClassifier` refuses spectral cadence. **Conclusion: no software step
  counter on the shipped motion stream, full stop.**

### 2.4 Calibrating one counter against another

The reference statistics are Bland–Altman mean bias with 95 % limits of agreement [S27], MAPE, and
a proportional-bias slope — Maylor 2022 found the slope was the decisive defect of Verisense v1
(over-count at low volumes, under-count above ~13,000/day) and removed it in v2 [S4]. Rowlands 2022
validated in the *cadence* domain (steps/min per walk) as well as totals [S6]; Maylor reports
MVPA-steps (≥ 100 steps/min) separately because "not all steps are equal" [S4]. Bassett 2017 asks
for 3–7 days per estimate [S12]. For a single wearer with a phone reference this translates to:
fit a through-origin ratio on log scale, inspect the slope against daily volume, and publish the
percentile band of the residuals — the design `StepsEstimateEngine` already has for the 4.0 motion
path (motion-weighted median of ratios, confidence from sample count and spread).

### 2.5 Activity recognition from the wrist

CAPTURE-24 (151 participants, 3,883 h at 100 Hz ±8 g on the dominant wrist, camera + diary labels)
reports baseline HAR on 4 classes (sleep / sedentary / light / MVPA): RF + HMM F1 0.789, κ 0.772;
CNN + HMM F1 0.800, κ 0.814; on 10 daily-living classes CNN + HMM F1 0.576, κ 0.735 [S24][S25]. Small
2024's walking-vs-not classifier reached κ 0.79 [S1]. The strap's 3-class byte (still/walk/run) is
coarser than any of these label sets but is produced from the full-rate signal inside the firmware;
NOOP's coarse classifier over 1 Hz data cannot be expected to beat it, and no published wrist HAR
model is small enough to justify shipping on-device without 100 Hz input.

### 2.6 Steps to energy

- Brooks et al. 2005 (72 adults, Douglas-bag calorimetry, self-paced ~5.2–5.5 km/h, 3.8–4.1 METs):
  **≈ 0.75 kcal·kg⁻¹ per km** of level walking for both sexes [S26]. With a 2 Hz cadence [S22] at
  5.3 km/h (88 m/min) the step length is ≈ 0.74 m, i.e. ≈ 1,350 steps/km, giving ≈ 0.00056
  kcal·kg⁻¹·step⁻¹ — about **0.039 kcal/step for 70 kg, gross**, at self-paced speed only. This
  is a derivation from two verified sources, not a published per-step constant; I found no
  citable "0.04–0.05 kcal/step" figure.
- Weyand et al. 2013 (78 subjects, 1.07–2.11 m, 16–112 kg, 0.4–1.9 m/s): walking metabolic rate
  from height, weight and speed predicts a validation group to 8.1 ± 6.7 %; the ACSM equation
  (no stature term) erred 18.0 ± 13.1 % [S28]. Hall et al. 2004: 1,600 m walking at 1.41 m/s cost
  340 ± 14 kJ (≈ 81 kcal) on the treadmill, running at 2.82 m/s 481 ± 20 kJ; ACSM and Pandolf
  equations matched walking well [S29].
- Fuller 2020 and Feehan 2018 both conclude consumer wearables are **not** accurate for energy
  expenditure under any condition [S9][S10]. NOOP's HR-based day estimate should remain the primary
  path; a step-based figure is a last-resort fallback for hours with no HR, never an addition.

---

## 3. Gap analysis

| # | Gap | Expected accuracy impact | Why |
|---|---|---|---|
| G1 | **No calibration estimator for the 5.0 counter.** `stepTicksPerStep` is a hand-set scalar with default 1.0; the auto-fit machinery in `StepsEstimateEngine` is 4.0-only. Reads of Apple hourly steps (`appleStepHour`) already exist but are unused for this. | **High** on the displayed number. The counter's relation to steps is unknown (protocol doc), and R4 shows the remembered ratio was wrong on 43 % of days. A data-derived ratio with a stated confidence is the single largest honest improvement available. | §2.4; `StepsEstimateEngine` design already matches the literature's robust-ratio approach. |
| G2 | **No plausibility band / completeness check** on a day's step total. A truncated offload or a counter reset reads as a low-step day with no flag. | **Medium.** Does not change correct days, but prevents silent wrong ones; R4 showed input coverage separates truncated days with zero false positives. | Pair the tick total with sample coverage (classed samples / 86,400) and a trailing percentile band of the log-ratio vs phone steps. |
| G3 | **Proportional bias unexamined.** If the strap over-counts at low volumes and under-counts at high ones (Verisense v1's defect), a single ratio is biased at both ends. | **Medium**, unknown sign until measured. | Bland–Altman slope on log(ticks/phone) vs mean daily volume, ≥ 14 days. |
| G4 | **Cadence byte 59 unused.** Protocol doc says it is not a steps/min unit, but it may be monotone with cadence and would let NOOP report MVPA-type steps (≥ 100 steps/min) separately, as Maylor 2022 recommends. | **Low** for the daily total; **medium** for interpretation. | Needs an on-device correlation of byte 59 against IMU-derived cadence during capture sessions before any use. |
| G5 | **Slow / unstructured gait.** Every wrist counter in §2.1 degrades 3–30× on slow or fragmented walking. NOOP's class gate and `maxTicksPerSecond 4` bound over-count but nothing bounds under-count. | **Low–medium**, inherent to the wrist site; a calibration cannot fix a per-bout miss. | Document it; a per-user ratio absorbs the wearer's typical mix but not day-to-day gait changes. |
| G6 | **No step detector for captured 100 Hz IMU.** `ImuFeatureExtractor` gives cadence strength but not a count, so a capture session cannot be scored against the strap counter. | **None on shipped metrics; high for validation.** It is the only way to measure the counter's bias per bout without a second device. | §6.3: walk-gated peak detection + autocorrelation cross-check, research only. |
| G7 | **Steps and energy are decoupled.** Correct today (HR-only kcal) but there is no fallback when HR is absent for hours and the counter still ran. | **Low.** | §6.4 fallback only, never summed with Keytel. |
| G8 | **In-sleep gating thresholds are unvalidated** (`minGaitBoutTicks 6`, etc.). | **Low** (night ticks are a small share) but cheap to test with a capture-session overnight. | Report accepted/rejected tick classes per night; the funnel already counts them. |

Things that are *not* gaps: the wrap-aware delta, the walk/run class gate, and the per-second rate
guard are all consistent with the literature's "count only while walking" finding (§2.2) and should
stay.

---

## 4. WHOOP 5.0 input constraints

| Input | Status | Consequence |
|---|---|---|
| Hardware counter byte 57 + class byte 63 | Present, 1 Hz when banked | Only continuous step signal. Semantics (rollover, reset, relation to WHOOP-app steps) unresolved; treat as a per-user-scaled proxy. |
| Cadence byte 59 | Present, unit unknown | Do not convert; log alongside IMU cadence when both exist. |
| Gravity/dynamic accel (41, 45–56) | ~1 Hz, sparse, gaps | Cannot count steps (§2.3). Usable only for coarse still/moving and sedentary bouts, as now. |
| 100 Hz six-axis IMU | Opt-in capture, bounded sessions, file-backed; battery/storage cost undocumented | Research instrumentation only; whether continuous capture is viable is a product/battery question outside this brief. |
| Phone / Apple Health steps | Available when the user permits; NOOP already reads daily and hourly | Reference for calibration; itself a wrist-or-pocket estimate with its own 5–15 % error (§2.1), so the band must include both errors. |

**Graceful degradation.**
- No reference days yet → show the raw-scaled total with the existing "low confidence" badge and the
  tick/step ratio shown as "uncalibrated"; never withhold the number the user already sees today.
- Reference present but < 3 overlapping days → `needsMoreDays` as `StepsEstimateEngine` does.
- Counter coverage below a stated floor for the day (e.g. < 80 % of expected classed samples) →
  mark the day "partial" rather than low.
- Counter reset / reboot (delta ≥ 512) → already dropped; count and surface the event.
- No IMU capture → every IMU-based feature in §6.3 is simply absent; nothing shipped depends on it.

---

## 5. Validation plan

### 5.1 Public datasets (all fetched this session)

| Dataset | URL | License / access | Size | Sensors | Labels | Use for NOOP |
|---|---|---|---|---|---|---|
| **OxWalk** (Small et al. 2022) | https://ora.ox.ac.uk/objects/uuid:19d3cb34-e2b3-4177-91b6-1bad0e0163e7 | CC BY 4.0, open download | 289.8 MB zip | 39 adults, Axivity AX3 ×2 on dominant wrist (100 Hz and 25 Hz) + ×2 on hip, free-living | Per-step heel-strike annotations from belt camera | Primary ground truth for a 100 Hz wrist step detector; 25 Hz copy answers "what if capture ran slower". |
| **Clemson Pedometer Evaluation** (Mattfeld et al. 2017/2021) | https://cecas.clemson.edu/~ahoover/pedometer/ (summary: https://sites.google.com/view/rmattfeld/pedometer-dataset) | No license stated on the pages fetched — confirm before redistribution; download includes video | not stated | 30 adults, Shimmer3 at 15 Hz, wrist/hip/ankle, ±2 g; adjacent Fitbit Charge 2 | 60,805 video-annotated steps across regular / semi-regular / unstructured gait | Stress test by gait regularity; the Fitbit column is a ready consumer-wrist comparator. |
| **CAPTURE-24** (Chan et al. 2024) | https://doi.org/10.5287/bodleian:NGx0JOMP5 (ORA record uuid:99d7c092-…) | CC BY 4.0 | 6.4 GB zip | 151 adults, Axivity AX3 100 Hz ±8 g, dominant wrist, ~24 h each | Activity classes from camera + diary (no step counts) | Activity-class validation only (still/walk/run vs its labels); too large to be a first step. |
| **PAMAP2** | https://archive.ics.uci.edu/dataset/231 | CC BY 4.0 | 656 MB | 9 subjects, 3 IMUs at 100 Hz (wrist, chest, ankle) + HR | 18 activities incl. walking, running, cycling, stairs | Walk/run/cycle classifier sanity checks; no step ground truth. |
| **WISDM 2019** | https://archive.ics.uci.edu/dataset/507 | CC BY 4.0 | 295 MB | 51 subjects, smartwatch + phone accel/gyro at 20 Hz | 18 activities, ~3 min each | Low-rate HAR; illustrates what 20 Hz can still do. |

All go under the git-ignored `research-data/` folder (brief §2.6). None contain WHOOP data, so they
validate an *algorithm*, not the strap's counter; the counter can only be validated with the owner's
own concurrent data (§5.3).

### 5.2 Metrics to report

- Per-day and per-bout **MAPE** and **mean percentage error** (sign matters: under- vs over-count).
- **Bland–Altman** mean bias and 95 % limits of agreement on daily totals, plus the regression slope
  of difference on mean (proportional bias), after Maylor 2022 [S4][S27].
- Split by **cadence band** (< 100 vs ≥ 100 steps/min) and by **gait regularity** where labels allow
  (Clemson) — the two axes along which wrist counters fail [S13][S16].
- For an IMU detector: step **sensitivity/precision at ±0.5 s** against heel-strike times (OxWalk).
- Always alongside the **input coverage** of the day (classed samples / expected) per R4, and the
  percentile the plausibility band covers.
- Temporal hold-out (R5): calibrate on the first N days, report on the later ones.

### 5.3 Owner validation (what the user can do with a WHOOP 5.0, a phone and optionally a watch)

1. **Daily ratio log (≥ 14 days, ideally 30).** Wear the strap on the wrist; carry the phone as usual.
   NOOP already imports Apple Health daily and hourly steps. Record per day: counter ticks (classed),
   phone steps, coverage, and whether the strap was on wrist or bicep. Output: ratio median, P5–P95,
   slope vs volume. This produces the calibration and the band in one pass.
2. **Hourly ratio.** Using `appleStepHour`, compare ticks and phone steps per hour; hours where the
   phone was demonstrably not carried (0 phone steps, many ticks) are excluded from the fit rather
   than averaged in — the motion-weighted-median idea from `StepsEstimateEngine`.
3. **Manual-count walks (3 speeds × 2).** Hand-tally ≥ 500 steps at slow (~80 steps/min), normal
   (~110) and brisk (~130) cadence with the Raw Data Collector running. Gives: counter bias by cadence,
   byte-59 vs IMU cadence, and the detector's per-bout accuracy. Use a metronome app for cadence.
4. **Unstructured-gait session (30 min housework / shopping)** with capture on: the regime where wrist
   counters are worst [S16]; compare counter, IMU detector and phone.
5. **Apple Watch, if owned:** a second wrist estimate; it is not a criterion (wrist 7–15 % MAPE itself
   [S13][S14]) but a cross-check with a known accuracy class.
6. **Overnight capture once** to verify the in-sleep gait-bout gate (G8).
7. Keep every log outside git. The one number to publish is "band covers P5–P95 of N days,
   re-derived on YYYY-MM-DD" — never the ratio alone.

---

## 6. Implementation sketch

All pure, DB-free, Swift + Kotlin twins with a Swift-stdout oracle in the Kotlin test (AGENTS.md).
Non-medical wording in any string.

### 6.1 Counter calibration estimator (extend `StepsEstimateEngine` to the 5.0 counter) — **Effort S–M, risk low**

```
input : days[i] = { ticks: Int (classed, sleep-gated), phoneSteps: Int, coverage: 0…1, onWrist: Bool }
params: minDays = 3, goodDays = 14, minCoverage = 0.80, minPhoneSteps = 1000, minTicks = 1000

usable = days where coverage ≥ minCoverage and phoneSteps ≥ minPhoneSteps and ticks ≥ minTicks and onWrist
if usable.count < minDays → .needsMoreDays(have, need)

// robust through-origin fit on the log ratio, weighted by volume (busy days pin the ratio)
r_i = ln(ticks_i / phoneSteps_i)
w_i = phoneSteps_i
k_log = weightedMedian(r_i, w_i)              // ticks per phone step, log domain
ticksPerStep = exp(k_log)

// proportional bias check (G3): slope of r_i on ln(mean volume); if |slope| > 0.15 and n ≥ 14,
// surface "ratio depends on volume" and fit two bins (below / above median volume) instead of one
spread = weightedMAD(r_i, w_i)
confidence = clamp(n / goodDays, 0, 1) · clamp(1 − spread / 0.35, 0, 1)
return .calibrated(ticksPerStep, n, confidence)
```

Apply as today: `steps = round(ticks / max(ticksPerStep, 0.5))`. Keep the manual slider as an
override that wins. Both platforms: fit in Swift, dump a 40-case table (n, spread, slope cases) as
the Kotlin expected literal.

### 6.2 Plausibility band and completeness flag — **Effort S, risk low**

```
input : history of usable days (as 6.1) → residuals e_i = r_i − k_log
band  = [P5(e), P95(e)] over the trailing 30 usable days (recomputed, never stored as a constant)
today : if coverage < minCoverage           → flag .partialDay   (input problem; R4 row 5)
        else if phoneSteps available and e_today ∉ band → flag .outsideBand(percentile)
        else                                 → .plausible
```

The flag is informational on the steps tile ("partial data" / "unusual ratio vs phone"), never an
alert. Publish the percentile the band covers in the diagnostic line.

### 6.3 Research-only step counter over captured 100 Hz IMU — **Effort M, risk medium**

Purpose: score the strap counter per bout, not to ship a number. Lives next to
`ImuFeatureExtractor`, output to the capture session export only. Reimplemented from the papers'
descriptions (Verisense parameters are published [S4]; `stepcount` code is under a non-commercial
academic licence and must not be copied [S2]).

```
input : samples at fs = 100 Hz, ax ay az in g; window = 10 s, hop = 10 s
pre   : m = sqrt(ax²+ay²+az²) − 1.0 ; clip ±2 g ; 4th-order Butterworth low-pass 5 Hz  [S1]
        (band-pass 0.25–2.5 Hz is the Ducharme alternative [S15]; pick one, state it)

gate  : walking = (ImuFeatureExtractor.cadenceStrength ≥ 0.20 and cadenceHz ∈ 1.2…3.5)   // §2.2 lesson:
        and accelEnergyG ≥ 0.05                                                            // count only while walking
if !walking → steps = 0 for the window

peaks : Verisense-style, parameters rescaled from 15 Hz to 100 Hz [S4 Table 1, v2]:
        k = round(4 · 100/15) ≈ 27 samples block maxima; keep a block max only if it is the max within ±k/2
        magThreshold = 1.25 g on raw |a| (or 0.25 g on m after −1 g)
        periodMin = 4·(100/15) ≈ 27 samples (3.7 Hz), periodMax = 20·(100/15) ≈ 133 samples (0.75 Hz)
        similarity: drop a peak whose −|second difference of peak amplitudes| < −1.0 g
        continuity: ≥ 4 of the previous 4 sub-windows with variance > 0.01 g²
cross : stepsAC = round(windowSeconds · cadenceHz) from the autocorrelation peak
        report both; disagreement > 20 % marks the window "uncertain"  [S16: AC is the robust one on irregular gait]
output: per-window { steps_peak, steps_ac, cadenceHz, strength, uncertain } + per-bout totals
```

Validation before anything reads it: MAPE and ±0.5 s step sensitivity on OxWalk 100 Hz (and the 25 Hz
copy), per-gait error on Clemson (resample 15 Hz → parameters in seconds, not samples). Target to be
considered useful: ≤ 15 % free-living MAPE on OxWalk, which is the Small 2024 class [S1]; anything
near Verisense's 63 % means the gate is not working. Per `AGENTS.md`, it must recover multiple
injected cadences in unit tests and never feed a physiological gate.

### 6.4 Steps → energy fallback (only for HR-less hours) — **Effort S, risk low**

```
if hour has HR → Keytel path (unchanged)
else if calibratedSteps_hour > 0:
     kcal_hour = 0.75 · weightKg · (calibratedSteps_hour · stepLengthM / 1000)       [S26]
     stepLengthM default 0.74 (2 Hz at 5.3 km/h), user-adjustable; label "walking estimate, no heart rate"
never add this to an hour that has an HR estimate; never feed strain.
```

Height-dependent variants (Weyand 2013 [S28]) are a later refinement; the fallback is already
coarser than the ~8 % those models achieve because the step count itself carries 10–20 % error.

### 6.5 Effort and risk summary

| Item | Effort | Risk | Depends on |
|---|---|---|---|
| 6.1 calibration estimator | S–M | Low (pure, reuses existing fit pattern) | Apple/Health Connect step reads (exist) |
| 6.2 band + completeness | S | Low | 6.1 |
| 6.3 IMU research counter | M | Medium (licence hygiene; needs OxWalk harness) | Raw Data Collector sessions; `research-data/` |
| 6.4 kcal fallback | S | Low | 6.1 |
| Byte-59 cadence study (G4) | S (logging) | Low | 6.3 capture sessions |

---

## 7. Sources (verified)

Fetch route in brackets. "EPMC" = Europe PMC REST abstract; "EPMC-FT" = Europe PMC full-text XML of
the open-access PMC copy.

- **[S1]** Small SR, Chan S, Walmsley R, von Fritsch L, Acquah A, Mertes G, Feakins BG, Creagh A,
  Strange A, Matthews CE, Clifton DA, Price AJ, Khalid S, Bennett D, Doherty A. *Self-Supervised
  Machine Learning to Characterize Step Counts from Wrist-Worn Accelerometers in the UK Biobank.*
  Med Sci Sports Exerc 2024;56(10):1945–1953. DOI 10.1249/MSS.0000000000003478, PMID 38768076,
  PMC11402590 [EPMC + EPMC-FT]. Verified: OxWalk n = 39 training, Clemson n = 30 external; hybrid SSL
  walking classifier + SciPy peak detection on low-passed (5 Hz) norm; 12.5 % MAPE, −1.3 % bias,
  r = 0.98 free-living; Verisense 63.5 % MAPE and Ducharme threshold 231 % MAPE on OxWalk; on Clemson
  Ducharme 47.5 % MAPE / +46.9 %, Verisense 17.3 % MAPE / −17.6 %; walking κ 0.79; AX3 at 100 and 25 Hz.
  (Not Scientific Reports, as the brief's lead suggested.)
- **[S2]** Small SR, von Fritsch L, Doherty A, Khalid S, Price A. *OxWalk: Wrist and hip-based activity
  tracker dataset for free-living step detection and gait recognition.* University of Oxford, ORA,
  2022. https://ora.ox.ac.uk/objects/uuid:19d3cb34-e2b3-4177-91b6-1bad0e0163e7 [fetched]. CC BY 4.0,
  289.8 MB, 39 adults, AX3 ×2 wrist (100/25 Hz) + ×2 hip, heel-strike annotations. Software:
  https://github.com/OxWearables/stepcount [fetched] and its LICENSE.md [fetched] — Oxford "Academic
  Use Licence", non-commercial, no product integration; SSL ResNet18 default, RF alternative.
- **[S3]** Femiano R, Werner C, Wilhelm M, Eser P. *Validation of open-source step-counting algorithms
  for wrist-worn tri-axial accelerometers in cardiovascular patients.* Gait Posture 2022;92:206–211.
  DOI 10.1016/j.gaitpost.2021.11.035, PMID 34864486 [EPMC]. Verified: 22 patients, AX3 wrist, chest
  GoPro; windowed peak detection and autocorrelation both ≤ ~10 % MAPE for walking, running, stairs,
  Nordic; over-count with arm movement, under-count during locomotion.
- **[S4]** Maylor BD, Edwardson CL, Dempsey PC, Patterson MR, Plekhanova T, Yates T, Rowlands AV.
  *Stepping towards More Intuitive Physical Activity Metrics with Wrist-Worn Accelerometry: Validity
  of an Open-Source Step-Count Algorithm.* Sensors 2022;22(24):9984. DOI 10.3390/s22249984, PMID
  36560353, PMC9786909 [EPMC + EPMC-FT incl. Table 1]. Verified: n = 713, non-dominant wrist 100 Hz
  ±8 g vs activPAL thigh; v1 +913 (LoA 772–1054) steps/day with proportional bias, v2 +742
  (592–891) = +7.9 % without; MVPA steps −2,207 / −1,204; parameter table v1→v2: peak block 3→4
  samples, period 5–15 → 4–20 samples, similarity −0.5 → −1.0 g, continuity 4/4, variance 0.001 →
  0.01, magnitude 1.2 → 1.25 g.
- **[S5]** Patterson MR. `verisense_count_steps.R`, Verisense-Toolbox (ShimmerEngineering), GitHub
  [fetched]. Verified: `fs = 15` hard-coded; magnitude → block maxima → magnitude / periodicity /
  similarity / continuity filters → per-second counts; attributed to Gu et al. 2017; no licence header.
- **[S6]** Rowlands AV, Maylor B, Dawkins NP, Dempsey PC, Edwardson CL, Soczawa-Stronczyk AA, Bocian M,
  Patterson MR, Yates T. *Stepping up with GGIR: Validity of step cadence derived from wrist-worn
  research-grade accelerometers using the verisense step count algorithm.* J Sports Sci
  2022;40(19):2182–2190. DOI 10.1080/02640414.2022.2147134, PMID 36384415 [EPMC]. Verified: 98 adults,
  six ~500 m walks at 92.9–127.9 steps/min, three wrist brands, waist ActiGraph criterion; original
  MAPE 17–22 %, revised ~10–12 %, bias halved, LoA ~±30 steps/min.
- **[S7]** GGIR documentation, *External functions* vignette,
  https://wadpac.github.io/GGIR/articles/ExternalFunction.html [fetched]. Verified: lists the
  Verisense wrist step algorithm as a collaborator-released external function (newer copy in GGIR's
  user-scripts); no parameters or licence stated on that page.
- **[S8]** Gu F, Khoshelham K, Shang J, Yu F, Wei Z. *Robust and Accurate Smartphone-Based Step
  Counting for Indoor Localization.* IEEE Sensors J 2017. DOI 10.1109/JSEN.2017.2685999 [Crossref
  metadata fetched; IEEE abstract page not retrievable]. Method (peaks + periodicity, similarity,
  continuity; motion state from inter-peak variance) taken from its re-descriptions in [S4] and [S16].
  Venue is IEEE Sensors Journal, not ACM TOSN as the brief's lead said.
- **[S9]** Fuller D, Colwell E, Low J, et al. *Reliability and Validity of Commercially Available
  Wearable Devices for Measuring Steps, Energy Expenditure, and Heart Rate: Systematic Review.* JMIR
  mHealth uHealth 2020;8(9):e18694. DOI 10.2196/18694, PMID 32897239 [EPMC]. Verified: 158
  publications, 9 brands; steps accurate in lab for Fitbit/Apple/Samsung; EE inaccurate for all.
- **[S10]** Feehan LM, Geldman J, Sayre EC, et al. *Accuracy of Fitbit Devices: Systematic Review and
  Narrative Syntheses of Quantitative Data.* JMIR mHealth uHealth 2018;6(8):e10527. DOI 10.2196/10527,
  PMID 30093371 [EPMC]. Verified: 67 studies; ±3 % controlled / ±10 % free-living criteria met about
  half the time; under-count controlled, over-count free-living; worst at slow walking.
- **[S11]** Toth LP, Park S, Springer CM, Feyerabend MD, Steeves JA, Bassett DR. *Video-Recorded
  Validation of Wearable Step Counters under Free-living Conditions.* Med Sci Sports Exerc
  2018;50(6):1315–1322. DOI 10.1249/MSS.0000000000001569, PMID 29381649 [EPMC]. Verified: 12 adults,
  14 methods, GoPro hand tally; wrist Fitbit Charge 69–84 %, wrist ActiGraph 109–122 % (no-LFE) and
  128–220 % (LFE); StepWatch 95.3–102.8 %.
- **[S12]** Bassett DR, Toth LP, LaMunion SR, Crouter SE. *Step Counting: A Review of Measurement
  Considerations and Health-Related Applications.* Sports Med 2017;47(7):1303–1315. DOI
  10.1007/s40279-016-0663-1, PMID 28005190 [EPMC]. Verified: 3–7 days needed; accuracy standards and
  placement unsettled; interventions +2,500 steps/day.
- **[S13]** Mora-Gonzalez J, Gould ZR, Moore CC, Aguiar EJ, Ducharme SW, Schuna JM, Barreira TV,
  Staudenmayer J, McAvoy CR, Boikova M, Miller TA, Tudor-Locke C. *A catalog of validity indices for
  step counting wearable technologies during treadmill walking: the CADENCE-adults study.* Int J
  Behav Nutr Phys Act 2022;19:117. DOI 10.1186/s12966-022-01350-9, PMID 36076265 [EPMC]. Verified:
  n = 258, 21 devices; wrist MAPE 15 % at normal speeds, ankle/thigh 1 %, waist 3 %; slow speeds 40 %;
  wrist GT9X 52 %.
- **[S14]** Moore CC, McCullough AK, Aguiar EJ, Ducharme SW, Tudor-Locke C. *Toward Harmonized
  Treadmill-Based Validation of Step-Counting Wearable Technologies: A Scoping Review.* J Phys Act
  Health 2020;17:840–852. DOI 10.1123/jpah.2019-0205, PMID 32652514, PMC7855895 [EPMC]. Verified: 77
  studies; weighted median MAPE 7–11 % wrist, 1–4 % waist, ≤ 1 % thigh at 1.1–1.8 m/s.
- **[S15]** Ducharme SW, Lim J, Busa MA, Aguiar EJ, Moore CC, Schuna JM, Barreira TV, Staudenmayer J,
  Chipkin SR, Tudor-Locke C. *A Transparent Method for Step Detection using an Acceleration
  Threshold.* J Meas Phys Behav 2021;4(4):311–320. DOI 10.1123/jmpb.2021-0011, PMID 36274923 [EPMC].
  Verified: 75 adults, band-pass 0.25–2.5 Hz, VM peak threshold 0.0359 g wrist / 0.0267 g waist;
  wrist RMSE < 481 steps vs ActiLife 2,913.
- **[S16]** Mattfeld R, Jesch E, Hoover A. *Evaluating Pedometer Algorithms on Semi-Regular and
  Unstructured Gaits.* Sensors 2021;21(13):4260. DOI 10.3390/s21134260, PMID 34206289, PMC8272166
  [EPMC + EPMC-FT]. Also Mattfeld R, Jesch E, Hoover A. *A new dataset for evaluating pedometer
  performance.* IEEE BIBM 2017, DOI 10.1109/BIBM.2017.8217769 [Crossref]; dataset page
  https://sites.google.com/view/rmattfeld/pedometer-dataset [fetched]. Verified: 30 participants,
  Shimmer3 15 Hz ±2 g wrist/hip/ankle, 60,805 annotated steps; 3–8 % regular, 7–34 % semi-regular,
  11–466 % unstructured; autocorrelation < 12 % on all; Fitbit Charge 2 figures as quoted in §2.1.
- **[S17]** = [S8] (listed once above; kept for table cross-reference).
- **[S18]** Karas M, Strączkiewicz M, Fadel W, Harezlak J, Crainiceanu CM, Urbanek JK. *Adaptive
  empirical pattern transformation (ADEPT) with application to walking stride segmentation.*
  Biostatistics 2021;22(2):331–347. DOI 10.1093/biostatistics/kxz033, PMID 31545345 [EPMC]. Verified:
  method, 32 participants, 450 m walk, wrist/hip/ankles; R package `adept` GPL-3 (CRAN page via search).
- **[S19]** Tudor-Locke C, Craig CL, Brown WJ, et al. *How many steps/day are enough? For adults.* Int J
  Behav Nutr Phys Act 2011;8:79. DOI 10.1186/1479-5868-8-79, PMID 21798015 [EPMC]. Verified:
  4,000–18,000 steps/day; 10,000 reasonable; ≥ 100 steps/min floor; 7,000–8,000 and 7,100–11,000.
- **[S20]** Tudor-Locke C, Han H, Aguiar EJ, Barreira TV, Schuna JM, Kang M, Rowe DA. *How fast is fast
  enough? Walking cadence (steps/min) as a practical estimate of intensity in adults: a narrative
  review.* Br J Sports Med 2018;52:776–788. DOI 10.1136/bjsports-2017-097628, PMID 29858465 [EPMC].
  Verified: 38 studies; ≥ 100 steps/min ≈ 3 METs; mean daily cadence 7.7 steps/min.
- **[S21]** Marcotte RT, Bachman SL, Zhai Y, Clay I, Lyden K. *Analytical Validation of Wrist-Worn
  Accelerometer-Based Step-Count Methods during Structured and Free-Living Activities.* Digit
  Biomark 2025;9:10–22. DOI 10.1159/000542850, PMID 39872700, PMC11771982 [EPMC]. Verified: 21
  adults, four open methods, motion-capture + StepWatch criteria; locomotion classifier reduced error.
- **[S22]** MacDougall HG, Moore ST. *Marching to the beat of the same drummer: the spontaneous tempo
  of human locomotion.* J Appl Physiol 2005;99:1164–1173. DOI 10.1152/japplphysiol.00138.2005, PMID
  15890757 [EPMC]. Verified: 2 Hz (SD 0.13) over 10 h in 20 subjects; Murray 1964 1.95 Hz (SD 0.19);
  no correlation with sex, age, height, weight, BMI.
- **[S23]** Quisbert-Trujillo E, Vuillerme N. *An Information-Driven Approach for the Early Health
  Technology Sustainability Assessment and the Frugal Design of the Internet of Medical Things:
  Exploratory Study of Wearable Activity Monitoring Devices.* JMIR mHealth uHealth 2026. DOI
  10.2196/88237, PMID 42543907 [EPMC]. Verified: 70–90 % information lost at 2–5 Hz, < 24 % from 20 Hz;
  step counting acceptable from ~11 Hz; secondary analysis of a wrist dataset (not a device validation).
- **[S24]** Chan S, Hang Y, Tong C, Acquah A, Schonfeldt A, Gershuny J, Doherty A. *CAPTURE-24: A
  large dataset of wrist-worn activity tracker data collected in the wild for human activity
  recognition.* Sci Data 2024;11:1135. DOI 10.1038/s41597-024-03960-3, PMID 39414802 [EPMC]; arXiv
  2402.19229 HTML [fetched] for baseline tables (4-class RF+HMM F1 .789 κ .772; CNN+HMM F1 .800
  κ .814; 10-class CNN+HMM F1 .576 κ .735); 100 Hz ±8 g AX3 dominant wrist.
- **[S25]** CAPTURE-24 ORA record https://ora.ox.ac.uk/objects/uuid:99d7c092-d865-4a19-b096-cc16440cd001
  [fetched]: CC BY 4.0, 151 participants, 6.4 GB zip, > 2,500 labelled hours.
- **[S26]** Brooks AG, Gunn SM, Withers RT, Gore CJ, Plummer JL. *Predicting walking METs and energy
  expenditure from speed or accelerometry.* Med Sci Sports Exerc 2005;37:1216–1223. DOI
  10.1249/01.mss.0000170074.19649.0e, PMID 16015141 [EPMC]. Verified: ≈ 0.75 kcal·kg⁻¹·km⁻¹ level
  walking; self-paced 5.2–5.5 km/h at 3.8–4.1 METs; Douglas bag.
- **[S27]** Bland JM, Altman DG. *Statistical methods for assessing agreement between two methods of
  clinical measurement.* Lancet 1986;i:307–310. DOI 10.1016/S0140-6736(86)90837-8, PMID 2868172 [EPMC].
- **[S28]** Weyand PG, Smith BR, Schultz NS, Ludlow LW, Puyau MR, Butte NF. *Predicting metabolic rate
  across walking speed: one fit for all body sizes?* J Appl Physiol 2013;115:1332–1342. DOI
  10.1152/japplphysiol.01333.2012, PMID 23928111 [EPMC]. Verified: 78 subjects, 0.4–1.9 m/s; 8.1 ± 6.7 %
  validation error vs ACSM 18.0 ± 13.1 %.
- **[S29]** Hall C, Figueroa A, Fernhall B, Kanaley JA. *Energy expenditure of walking and running:
  comparison with prediction equations.* Med Sci Sports Exerc 2004;36(12):2128–2134. DOI
  10.1249/01.mss.0000147584.87788.0e, PMID 15570150 [EPMC]. Verified: 1,600 m walking 340 ± 14 kJ,
  running 481 ± 20 kJ; ACSM/Pandolf fit walking.
- **[S30]** Bai J, Di C, Xiao L, Evenson KR, LaCroix AZ, Crainiceanu CM, Buchner DM. *An Activity Index
  for Raw Accelerometry Data and Its Comparison with Other Activity Metrics.* PLoS ONE
  2016;11(8):e0160644. DOI 10.1371/journal.pone.0160644 [publisher page fetched]. Verified: AI = summed
  per-axis variance over 1-s epochs minus device noise variance; 194 women, GT3X+ hip 30 Hz; R² for
  METs 0.72 (AI) vs 0.62 (ENMO) vs 0.54 (counts). Relevant only if a continuous 100 Hz stream ever
  exists; an epoch variance is a plausible cheap "activity volume" there.
- **[S31]** PAMAP2 Physical Activity Monitoring, UCI ML Repository, DOI 10.24432/C5NW2H [fetched]:
  9 subjects, 100 Hz IMUs wrist/chest/ankle, 18 activities, 656 MB, CC BY 4.0.
- **[S32]** WISDM Smartphone and Smartwatch Activity and Biometrics Dataset, UCI ML Repository, DOI
  10.24432/C5HK59 [fetched]: 51 subjects, 20 Hz, 18 activities, 295 MB, CC BY 4.0.

---

## 8. Unverified leads

Not fetched, or fetched and found not to match the brief's description. Nothing in §2–§6 rests on them.

- **"Ahmadi 2024" step-count algorithm** — no such wrist step-detection paper surfaced; searches
  resolved to Small et al. 2024 [S1]. (An Ahmadi-led epidemiology paper on step counts may exist;
  not an algorithm source.)
- **"Zhang 2023" open wrist-algorithm comparison** — not found; the matching comparison is Marcotte
  2025 [S21].
- **"Small/Doherty 2024, Scientific Reports"** — wrong venue; the paper is MSSE [S1].
- **"Gu 2017, ACM TOSN"** — wrong venue; IEEE Sensors J [S8]; abstract itself not retrieved.
- **Ducharme 2021 "treadmill speeds" paper** — the 2021 Ducharme paper is the threshold method [S15];
  the speed catalog is Mora-Gonzalez 2022 [S13] with Ducharme as co-author.
- **Murray MP, Drought AB, Kory RC. J Bone Joint Surg 1964;46A:335–360** — cited inside [S22] for the
  1.95 Hz value; not fetched.
- **Rai et al.** autocorrelation algorithm reimplemented by Mattfeld 2021 — cited in [S16] full text;
  not fetched.
- **Walmsley et al. 2022** (UK Biobank 4-class activity labels used by CAPTURE-24) and **Willetts et al.
  2018** (6-class) — named in [S24]; not fetched.
- **Weyand et al. 2010, J Exp Biol** (per-stride energy independent of stature) — predecessor of [S28];
  not fetched.
- **Lankford et al. 2020, Eur J Appl Physiol** walking-cost equation — search hit only.
- **Saint-Maurice et al.** 1-min peak cadence definition — cited in [S1]; not fetched.
- **ACSM metabolic equation for walking** — characterised only through [S28] and [S29].
- **Tudor-Locke & Bassett 2004** steps/day categories (< 5,000 sedentary …) — not fetched; only the
  2011 ranges in [S19] are used.
- **MAREA and Kluge gait datasets** — listed in [S16]'s comparison table; not fetched.
- **WHOOP's own claim that its step count is "validated for on-wrist use"** — only secondary
  (review/forum) pages surfaced; no peer-reviewed validation of a WHOOP step count was found. Forum
  reports of 5.0 under-counting vs Apple Watch are anecdotes and are not used here.
- **Clemson dataset licence** — no terms stated on the two pages fetched; confirm with the authors
  before any redistribution of derived fixtures.

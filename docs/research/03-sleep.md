# 03 – Sleep detection and sleep staging from wrist HR + motion

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Every literature
figure below was taken from a page fetched in this session (§7 lists the URL/DOI per source). Every
NOOP figure is marked **INHERITED** (quoted from the tree's own documentation or harness README, not
re-run here: no Xcode and no `sleep-accel` copy on this machine) or **CONFIRMED** (read in source this
session). Conclusions drawn from those figures are marked **INFERRED**. The repo's
`docs/VALIDATION_PROTOCOL.md` rules R1–R8 govern how any of this may later be claimed as an
improvement; §5 is written against them.

Wording note: the stages NOOP emits are approximations of a laboratory convention; nothing here is a
clinical measurement, and nothing proposed here should feed a diagnostic claim (`docs/SCOPE.md`).

---

## 1. What NOOP does today

### 1.1 Files and functions (CONFIRMED by reading source this session)

| Layer | Swift (`Packages/StrandAnalytics/Sources/StrandAnalytics/`) | Kotlin (`android/app/src/main/java/com/noop/analytics/`) |
|---|---|---|
| Session detection (V1 "Stage 0") | `SleepStager.detectSleep` (gravity-stillness spine + Cole–Kripke cross-check + HR confirmation) | `SleepStager.kt` (`detectSleep`) |
| Sparse-gravity bridging | `SleepStager.isGravitySparse` (line ~404), `hrSleepBandAcross`, `buildRuns` HR-vouched gap bridge | `SleepStager.kt` `isGravitySparse` (line 510) |
| HR-only detection | `SleepStager.hrOnlyBaseline`, `hrPercentile`, `hrOnlySleepRuns`, `hrOnlySessions` (lines ~505–700) | `SleepStager.kt` lines 556–745 (`hrOnlyAnchorPercentile`, `hrOnlyBaseline`, `hrOnlySleepRuns`, `hrOnlySessions`) |
| Staging (default) | `SleepStagerV2.stageSession` → `features` → `stageEpochs` → `viterbi` | `SleepStagerV2.kt` (header states byte-identical twin; `PAD_LO/PAD_HI` are 360/420 vs Swift 330/390 — a wider clip, output-identical by construction) |
| Staging (legacy, flag) | `SleepStager.stageSession` (percentile-band classifier + median smoothing + physiology re-imposition) | `SleepStager.kt` |
| Post-pass (default OFF) | `WakeMotionRefinement` (step-counter cadence + per-minute posture variance; density self-gate) | `WakeMotionRefinement.kt` |
| Band reference | `sleepStateSample` table (WhoopStore `Database.swift` line 416); `SleepStager.bandStateWakeVetoEnabled = false` (line ~1130); `AnalyticsEngine` grids band state per session (#175) | twin constants per source comments |
| Harnesses | `Tools/SleepPSG` (PhysioNet `sleep-accel` vs shipped V2; `RecipeConfig.shipped` equivalence test), `Tools/SleepBench` (wearer DB, band `sleep_state`, E.-1 self-comparison audit) | — |

### 1.2 Detection method and constants (CONFIRMED)

Stage 0 of `SleepStager`:

- Movement proxy = L2 norm of the gravity-vector change between consecutive records; "still" if
  `< gravityStillThresholdG = 0.01 g`. A 15-minute window (`stillWindowMin`) whose still fraction is
  `≥ stillFraction = 0.70` is called sleep at its centre. Runs break on a gap `> maxGapMin = 20` min;
  runs `< mergeMin = 15` min are absorbed; a session must exceed `minSleepMin = 60` min.
- HR confirmation: run median HR must be `≤ hrSleepBaselineMult = 1.05 ×` the day's median HR
  (`confirmSleepWithHR`); the band widens to ×1.30 when the run is deeply motion-quiescent (the
  "elevated-but-still is not wake" rule, `docs/ANALYTICS.md`).
- Cole–Kripke index computed per 30 s epoch as a citable cross-check, with the te Lindert weights
  `[106, 54, 58, 76, 230, 74, 67]` and `ckScale = 0.001`, sleep iff `SI < 1` (`coleKripke`, line ~1880).
- Sparse gravity (`isGravitySparse`): gravity span `< sparseGravitySpanFrac = 0.5` of the HR span, OR
  largest gravity gap `> maxGapMin`. When true, `buildRuns` may bridge a gravity gap if
  `hrSleepBandAcross` vouches that the HR median stayed in band (`sparseBridgeGapMin = 90`).
- HR-only path (`hrOnlySessions`, #1801/#1884): anchor = nearest-rank 10th percentile of the window's
  bpm (`hrOnlyAnchorPercentile = 0.10`); per-60 s epoch (`hrOnlyEpochS`) median bpm
  `≤ anchor × hrOnlyBandMult (1.05)` is "sleep"; runs built like `buildRuns` but with no gap bridge
  (the gap is in HR itself); `mergePeriods`, then `minSleepMin`; each surviving run is staged by V2 with
  an empty gravity array. Sessions carry `hrOnly = true`; `restingHR`/`avgHRV` are measured and reported.

### 1.3 Staging recipe (`SleepStagerV2`, CONFIRMED)

Per 30 s epoch, all normalisation within the night:

| Feature | Definition |
|---|---|
| `hr` | epoch-mean bpm |
| `hrVar` | population std of per-second HR over a centred 5-min window |
| `hrFlat11` | std over a centred 11-min window; its within-night percentile rank `fpct` is the deep gate |
| `moveFrac` | fraction of in-epoch per-second gravity jerks above `jerkScale × jerkFloorMoveMult (38)` |
| `jerkMax` | peak per-second jerk; wake boost `+2.0` when `> jerkScale × jerkFloorGateMult (55)` |
| `respReg` | RSA spectral peakedness of the 4 Hz-resampled R-R tachogram over `[e−90, e+120)` s, 0.15–0.40 Hz band (needs ≥ 12 beats, ≥ 16 grid points) |
| `clock`, `minutesSinceOnset` | session fraction; minutes from the first sustained 5-min non-wake run (two-pass) |

Emissions (log domain), with `z·` the night z-scores and `gate = 5·max(0, fpct − 0.25)`:

```
deep  = −1.1·zhv − 0.5·zmv − gate + ln 0.15 + 1.2·max(0, 1 − c/0.55)       (+0.6·zrg)
rem   =  0.6·zhv − 0.6·zmv + 0.4·zhr + ln 0.22 + 1.0·c − guard(minutes)     (−0.6·zrg)
light =  ln 0.50
awake =  1.0·zmv + cardiac + ln 0.10   (+2.0 jerk gate); cardiac = 0.8·zhv + 0.4·zhr, clamped ≤ 0 when motion-quiescent
```

Viterbi over the sticky matrix (`deep 0.86`, `rem 0.88`, `light 0.85`, `awake 0.90` self-loops;
`awake→deep = awake→rem = 0`, floored to `1e−9` before `ln`). The REM-latency guard is `3.0` log-odds at
onset decaying linearly to zero over 60 min. Every coefficient is a-priori; nothing is fit to labels.

### 1.4 What is cited in code and docs (CONFIRMED)

Cole–Kripke 1992 via te Lindert & Van Someren 2013 (weights); Walch et al. 2019 (`sleep-accel`,
PhysioNet, with the #2835 correction that Walch reports 2- and 3-class tasks only); AASM roll-up
conventions (N1+N2 → light, N3 → deep). `AGENTS.md` cites #345 (WHOOP 4.0 motion too sparse to stage
sleep or tell in-bed from out-of-bed).

### 1.5 NOOP's own measured numbers (INHERITED from `Tools/SleepPSG/README.md`; regenerate with
`cd Tools/SleepPSG && swift run -c release sleeppsg --dataset <sleep-accel root>`)

| Quantity | Value | Domain |
|---|---|---|
| 4-class κ, shipped recipe (deep prior 0.15) | 0.371 pooled / 0.357 mean per-subject | 31 subjects, 26 773 PSG epochs, labelled span only (session detection NOT exercised) |
| Deep share | pred 15.09 % vs truth 13.76 % → **+1.32 pp** pooled (+0.40 pp per-subject mean) | pooled |
| Light share | 54.33 % vs 55.19 % | pooled |
| REM share | ~26.96 % per-subject mean vs ~21 % (REM over-called; residual vs the previous harness unresolved) | per-subject mean |
| Wake share / sensitivity | 4.15 % vs 9.07 % true (**−4.92 pp**); wake sensitivity 30.8 % | pooled |
| Onset (first sustained 5-min non-wake run) vs PSG onset | bias −3.8 min, MAE 7.4 min | n = 31 (`SleepStagerV2.onsetSustainedEpochs` doc) |
| V2 vs V1, 44-subject LOSO (AAUWSS + sleep-accel) | κ 0.35 vs 0.03; deep recall 55 % vs 1 % | source-comment claim; harness for the AAUWSS half not in tree (see §8) |
| RSA term | **untested against PSG** — `sleep-accel` has no R-R, so `zrg ≡ 0` on every epoch | — |
| Sleep/wake vs the strap's own band, one wearer | κ 0.795 whole-record vs 0.095 in-session (same nights) | `docs/VALIDATION_PROTOCOL.md` R1 |
| HR-only threshold drift, one wearer | optimal threshold moved > 10 bpm in 3 weeks; −5.7 pp balanced accuracy early→late | R5 |

Two facts about the benchmark input matter for everything below. The `sleep-accel` Apple Watch HR was
sampled **every 8–10 s** (Walch 2019, Discussion; fetched) — *sparser* than a banked WHOOP 5.0 R18
stream at 1 Hz — and its acceleration is ~50 Hz raw collapsed to a per-second mean by the harness.
So the published κ 0.37 is measured on HR that is thinner than the owner's, on motion that is denser,
and with the R-R channel silent (INFERRED from the README and the Walch text).

---

## 2. Recommended method(s) from the literature

### 2.1 Sleep/wake detection

**Classic count-based actigraphy (Cole–Kripke, Sadeh, Oakley).** Cole et al. 1992 (n = 41: 18 normal,
23 with sleep/psychiatric disorders) report ~88 % epoch sleep/wake agreement with PSG. Sadeh et al.
1994 (20 adults + 16 adolescents) report 91–93 % overall agreement, with sleep agreement consistently
higher than wake agreement. Both were derived on proprietary activity counts; te Lindert & Van Someren
2013 is the bridge NOOP uses from raw MEMS acceleration (50 Hz) to those counts, and it validates
against **actigraph counts, not PSG** (κ 0.83–0.87 vs an Actiwatch, n = 15 healthy adults at home).
On a large modern cohort (MESA, 1 817 subjects, Actiwatch Spectrum, 30 s epochs), Palotti et al. 2019
measure Cole–Kripke at **75.4 % accuracy / F1 81.2** for the night task against PSG, Sadeh 73.4 / 80.3,
Oakley θ=10 77.5 / 81.0, the device's own algorithm 76.2 / 81.3, and an LSTM on counts alone 83.1 / 85.5.
No HRV was used in that benchmark. The structural weakness is the same in every source: specificity to
wake is low because a still, awake wearer is motionless (Walch 2019 Discussion; Chinoy 2021 Actiwatch
sensitivity 0.97 / specificity 0.39).

**Raw-accelerometer heuristics without counts (van Hees).** van Hees et al. 2015 define sustained
inactivity as no change in the arm's z-angle larger than 5° over ≥ 5 min (angle from a 5-s rolling
median of the three axes); against PSG in 28 clinic patients the sleep-period accuracy was 83 % with a
~31 min overestimate of sleep duration. van Hees et al. 2018 (HDCZA: "heuristic algorithm looking at
distribution of change in z-angle") drops the diary requirement: the sleep-period-time window is found
from the variance of the z-angle plus simple rules about interruptions, with a C-statistic of **0.86 in
28 clinic patients and 0.83 in 22 healthy sleepers** vs PSG, and a +10.9 min (men) / +2.9 min (women)
SPT difference vs diary in 3 752 older adults. Sundararajan et al. 2021 (134 training / 24 test adults,
GENEActiv) put the heuristics side by side on one test set: **van Hees κ 0.42, Sadeh 0.37, Cole–Kripke
0.36**, and a random forest on 36 features of ENMO / z-angle / LIDS at **κ 0.50**; stage classification
from acceleration alone "proved to be more challenging due to the absence of discriminative features"
(N3 F1 21 %, REM 12 %).

**HR + motion learned classifiers.** Walch et al. 2019 (31 healthy adults, Apple Watch S2/3, PSG):
sleep/wake ~90 % accuracy, sensitivity 93 %, specificity 59.6 %, AUC 0.878, κ ≈ 0.455 with motion +
local-HR-std + clock proxy; the clock proxy alone added ~14 % specificity at fixed 90 % sensitivity.
Externally on 188 MESA subjects: sensitivity 90 %, specificity 60 %, κ 0.525. Fonseca et al. 2017
(wrist PPG + accelerometer, 51 healthy middle-aged adults / 80 validation nights): sleep/wake **κ 0.55 ±
0.14, accuracy 91.5 %, wake sensitivity 58.2 %**, significantly above actigraphy on the same nights (κ
0.40, wake sensitivity 45.5 %). Roberts et al. 2020 (8 participants × 4 lab nights, Apple Watch + Oura
+ actigraph + ECG): wearable-trained classifiers reached sensitivity 0.883–0.977 and specificity
0.407–0.821, versus research devices at 0.366–0.647 specificity.

**HR-only detection.** Perez-Pozuelo et al. 2022 is the one open, device-agnostic HR-only sleep-period
detector found with a PSG comparison. Method (fetched): per-person, per-24-h-window quantile threshold on
HR (Q = 0.325 for full-day data, 0.80 for night-only), epoch sleep iff HR below it, 5-min rolling
median, discard sleep blocks < 20 min, merge blocks closer than 90 min (full-day) / 420 min (night-only),
reject a block preceded by > 90 min of wake in the prior 4 h, then **refine onset/offset by searching
−240…+60 min for the last/first epoch whose 10-min rolling HR std exceeds 6 bpm**. Against PSG on the
PhysioNet Apple Watch set (n = 22 of 31 used): **κ 0.59, TST −29.1 min, onset +20.7 min, offset −8.3
min**; on MESA (n = 1 154) TST −55.0 min, onset +40 min, offset −15 min, MSE 0.11. The angle-change
accelerometer method on the same PhysioNet nights scored κ 0.71, TST +44.4 min, onset −21.8 min, offset
+22.6 min. So HR alone finds the sleep period but places onset late and under-reads duration; motion
places it early and over-reads it (INFERRED from those two rows). Note the paper's own internal
inconsistencies (BBVS TST deviation 9.84 vs 2.70 min; Apple-Watch n 31 vs 22), recorded as fetched.

### 2.2 Four-class staging (wake / light / deep / REM)

What the literature's inputs actually are, task by task (never conflate):

| Study (fetched) | Input | Model | Population / n | Task | κ | Accuracy | Notes |
|---|---|---|---|---|---|---|---|
| Walch 2019 | Apple Watch HR (every 8–10 s) + 50 Hz accel + clock | LR / kNN / RF / MLP | 31 healthy, lab | **3-class** W/NREM/REM | 0.28 (all features); motion-only 0.084; **HR-only 0.040**; motion+HR 0.256 | ~72 % | No 4-class attempted |
| Fonseca 2017 | wrist PPG IBI (HRV) + accel counts | hand features, classical classifier | 51 healthy middle-aged, 80 nights | 4-class W/N1N2/N3/R | **0.42 ± 0.12** | 59.3 % | 3-class κ 0.46; 2-class κ 0.55 |
| Beattie 2017 | Fitbit Surge PPG + accel (breathing, HRV, movement features) | LDA, 54 of 180 features + rules, LOO | 60 healthy, home PSG | 4-class | **0.52 ± 0.14** | 69 % | REM over-estimated 102 vs 88 min; inter-scorer κ 0.72 |
| Radha 2019 | ECG HRV, 132 features (PSG-derived, not wrist) | 3-layer bi-LSTM | 292 subjects, 584 nights (SIESTA) | 4-class | **0.61 ± 0.15** | 77.0 % | N3 κ 0.53 weakest; κ falls with age (r −0.45) |
| Fonseca 2020 | ECG HRV + accel counts | LSTM | sleep-disordered hold-out | 4-class | **0.60** | 75.9 % | REM parasomnia 0.47; 2-class κ 0.65, wake sens 72.9 % |
| van Gilst 2020 | ECG-trained model applied unchanged to wrist PPG IBI | LSTM | 389 sleep-disordered recordings | 4-class | **0.56 (PPG) vs 0.60 (ECG)** | 73.0 vs 75.9 % | The PPG→ECG penalty is ~0.04 κ |
| Wulterkens 2021 | wrist PPG 32 Hz → 132 HRV features + 128 Hz accel counts | bi-LSTM, trained on 543 | 292 hold-out (244 adults, 48 children; mixed disorders) | 4-class | **0.62 ± 0.12** | 76.4 % | per-stage κ: W 0.66, N1N2 0.54, N3 0.60, REM 0.69 |
| Radha 2021 | wrist PPG, transfer from ECG | recurrent, transfer | 60 healthy, 101 recordings | 4-class | **0.65 ± 0.11** | 76.4 % | healthy only |
| Olsen 2023 | raw ACC + PPG | U-Net style | 301 train; 35-recording wrist hold-out | 4-class | **0.58 ± 0.18** (wrist hold-out) | 69 % | PPG the most impactful modality |
| Sridhar 2020 | **instantaneous HR from ECG only**, resampled to 2 Hz | dilated CNN, full-night input | SHHS 800-night test; CinC 993 | 4-class | **0.66** (SHHS); 0.55 (CinC) | 77 / 72 % | deep recall 0.49 (weakest); PPG generalisation untested |
| Pini 2022 | **HR only** (RR tachogram from ECG), 30 s epochs | TCN, 1.03 M params | CinC 988; Z3Pulse wearable ECG 52 | 4-class | **0.51** (CinC), 0.53 (Z3Pulse) | 73 / 70 % | 3-class κ 0.60; 2-class κ 0.58; deep sens 0.38 |
| Kotzen 2022 (arXiv) | **raw PPG waveform** | SleepPPG-Net | 2 374 patients | 4-class | median **0.75** | — | not reachable from NOOP's inputs |
| Zhai 2020 | actigraphy + ECG HRV (MESA, 1 743) | CNN / LSTM / ensemble | MESA | **3-class** | not in abstract | 78.2 %, F1 69.8 | cardiac frequency features "critical" |

Consumer devices against PSG (all fetched; all 4-class unless noted):

| Device | Study | n | 2-class κ (sens / spec) | 4-class κ | Signed stage bias |
|---|---|---|---|---|---|
| WHOOP (2020) | Miller 2020 | 12, 86 sleeps | 0.49 (95 % / 51 %) | **0.47**, 64 % agreement | TST +8.2 ± 32.9 min; sens light 62, SWS 68, REM 70, wake 51 % |
| WHOOP 3.0 | Miller 2022 | 53 | 0.44 (86 % agreement) | **0.44**, 60 % | — |
| WHOOP 4.0 | Schyvens 2025 | 40 of 62 | sens 93.6 % / spec 40.1 % | **0.37 ± 0.16** | **deep +31.5 min, light −28.5, REM +15.3, wake −24.5, TST +24.5, WASO −19.2, SOL −11.0** |
| WHOOP 2.0 | Stone 2020 | 5, 98 nights (EEG headband ref.) | — | — | TST MAPE 8.8 %; deep MAPE 46 %, REM MAPE 58 % (best of nine, still "no device accurately quantified stages") |
| Oura gen 1 | de Zambotti 2017/19 | 41 adolescents/young adults | sens 95.5 % / spec 48.1 % | not reported | deep **−19.6 min** (under), REM **+17.2 min** (over); light 64.6 %, deep 50.9 %, REM 61.4 % agreement |
| Oura gen 2 | Miller 2022 | 53 | 0.51 | 0.43 | — |
| Oura Ring 3 | Lee 2023 | 75 (multicentre) | — | 0.35 | deep sens 0.78, REM 0.71, wake 0.38 |
| Apple Watch S6 / S8 | Miller 2022 / Lee 2023 | 53 / 75 | 0.30 | 0.20 / 0.30 | wake sens 0.45 (S8) |
| Fitbit Sense 2 / Alta HR | Lee 2023 / Chinoy 2021 | 75 / 20 | — / sens 0.95 spec 0.54 PABAK 0.80 | 0.42 / — | Alta HR: light +20.0, deep −6.0, REM −11.4 min |
| Galaxy Watch 5, Pixel Watch | Lee 2023 | 75 | — | 0.42, 0.40 | — |
| Somfit (forehead EEG-less patch) | Miller 2022 | 53 | 0.48 | 0.52 | — |
| Actiwatch 2 (actigraphy) | Chinoy 2021 | 34 (98 nights) | sens 0.97 / spec 0.39 / PABAK 0.78 | — | TST +23.9, WASO −16.6, SOL −7.6 min |

Human reference ceiling: AASM inter-scorer agreement over > 2 500 scorers and 1 800 epochs is 82.6 %
overall, with N1 63.0 % and N3 67.4 % (Rosenberg & Van Hout 2013); Beattie's two scorers agreed at κ 0.72.
Fitbit meta-analysis (Haghayegh 2019, 8 quantitative studies): staging models detect sleep epochs with
sensitivity 0.95–0.96 and specificity 0.58–0.69; non-staging (motion-only) models 0.87–0.99 / 0.10–0.52.

### 2.3 What to take from this (INFERRED unless a number is cited)

1. **The accuracy ceiling for wrist 4-class staging is κ ≈ 0.6–0.65** with beat-level HRV from PPG, a
   dense accelerometer, and a recurrent model trained on hundreds of nights (Wulterkens 0.62, Radha 2021
   0.65, Olsen 0.58 on a wrist hold-out). With hand-built features and a linear classifier the ceiling
   is **κ ≈ 0.42–0.52** (Fonseca 2017, Beattie 2017). Shipped consumer wrist devices cluster at
   **κ 0.20–0.44**, with WHOOP's own app at 0.47 → 0.44 → 0.37 across three independent cohorts (2020,
   2022, 2025). NOOP's V2 at 0.37 pooled (no R-R, HR every 8–10 s) therefore sits inside the consumer
   band and about 0.1–0.15 below the hand-feature research models. Cross-study κ are not like-for-like
   (different cohorts and class marginals, R4), so this is a band, not a ranking.
2. **HR alone can stage, but only with a full-night learned model.** The two HR-only results worth
   remembering point in opposite directions: Walch's HR-only hand feature (one local-std feature) gives
   3-class κ 0.04, while Sridhar's full-night CNN on 2 Hz instantaneous HR gives 4-class κ 0.66 on SHHS
   and Pini's TCN on the RR tachogram gives 0.51 on CinC. The difference is the model, not the signal.
   Neither of those models is realistic to ship as pinned constants in Swift and Kotlin.
3. **Deep is everyone's weakest stage** (Radha 2019 N3 κ 0.53; Sridhar deep recall 0.49; Pini deep
   sensitivity 0.38; Rosenberg N3 inter-scorer 67 %). NOOP's documented "light/deep is the weakest
   link" is the literature's finding too, so the realistic goal is calibrated deep *minutes* with small
   signed bias, not high deep κ.
4. **Wake is a motion problem.** Every source with low wake specificity is motion-starved or
   motion-only; the sources with wake sensitivity > 70 % (Fonseca 2020, Wulterkens) have dense
   accelerometry *and* HRV. NOOP's 31 % wake sensitivity on sleep-accel is consistent with a recipe that
   treats motion as a gate rather than a learned feature.
5. **The PPG→ECG penalty is small (≈ 0.04 κ, van Gilst 2020)**; the penalty from *sparse* beat
   intervals is not measured anywhere fetched. That is the gap WHOOP 5.0's ≤ 4 R-R words/s (with
   filler beats) falls into, and R8 applies: it cannot be claimed either way without a measurement.
6. **For detection, posture angle beats jerk when motion is sparse.** HDCZA operates on 5-s z-angle
   epochs and 5-min windows; it needs orientation, not high-rate dynamics, which is exactly what a
   1 Hz gravity vector provides. Its PSG C-statistic (0.83–0.86) and its known bias direction (late
   onset avoided, duration slightly over-read) are documented; NOOP's 0.01 g jerk-stillness spine has
   no such figure.

---

## 3. Gap analysis

Each gap names the NOOP mechanism (CONFIRMED in source), the literature counterpart (§2), and the
expected impact (INFERRED). Impact is on the metric the repo actually reports: 4-class κ with marginals,
signed per-stage bias in pp, onset/offset error in minutes.

| # | Gap | NOOP today | Literature | Impact | Why |
|---|---|---|---|---|---|
| G1 | **R-R used only as an RSA regularity scalar** | `respReg` = spectral peakedness, weight 0.6; no RMSSD/SDNN/LF/HF/pNN50 per epoch in V2 (V1 had RMSSD/SDNN) | Fonseca/Wulterkens/Radha: 132 HRV features per epoch are the dominant stage signal; Zhai: cardiac *frequency* features "critical"; Beattie: HRV + breathing + movement | **High** (where R-R is usable) | V2's cardiac evidence is HR mean and HR std only; the literature's deep/REM separation is carried by HRV. On a WHOOP 5.0 the R-R channel is sparse, so the gain is conditional (§4). |
| G2 | **Emission coefficients fixed a-priori** | every weight hand-set; `baseLogPrior` light/deep/rem/awake 0.50/0.15/0.22/0.10 | Beattie reaches κ 0.52 with *LDA on hand features*; Fonseca 2017 κ 0.42 with a classical classifier — i.e. a fitted linear emission over similar features, nothing deep | **High** | The step from a-priori to *fitted-offline-and-pinned* linear weights is the cheapest known move from the consumer band (0.37) toward the hand-feature band (0.42–0.52), and it keeps the HMM, the parity model and the on-device footprint. Fitting must be LOSO and temporal (R5). |
| G3 | **Wake under-called (−4.9 pp, sens 31 %)** | wake emission = `1.0·zmv + cardiac`; cardiac clamped ≤ 0 when quiescent; motion enters only as `moveFrac` and a jerk gate | wake sens 58–73 % with dense accel + HRV; Perez-Pozuelo's onset/offset refinement uses rolling HR std > 6 bpm | **Medium–High** | Efficiency, WASO and the Rest composite all read this. On a 5.0 with 1 Hz gravity the jerk floor median is dominated by decode noise; a *posture-angle* feature (already computed per minute in `WakeMotionRefinement.postureVariance`) is the motion-sparse-friendly alternative. |
| G4 | **Deep over-/under-call unmeasured where it matters** | deep bias +1.3 pp pooled on sleep-accel (no R-R); deep gate on 11-min HR flatness only | N3 is the weakest stage everywhere (N3 κ 0.53–0.60 at best; WHOOP 4.0 app +31.5 min) | **Medium** | Bias is small *on the benchmark*; the unmeasured risk is the RSA term flipping deep on WHOOP nights where filler beats make the tachogram artificially regular (§4). |
| G5 | **REM over-called (~27 % vs ~21 %)** | REM ramp `1.0·c` + latency guard; `rem` row self-loop 0.88 | Beattie also over-estimates REM (+14 min); Oura gen 1 +17 min; literature's REM evidence is HRV irregularity + HR rise, which NOOP only approximates via `zhv` | **Medium** | A fitted emission (G2) would recalibrate the REM intercept; the clock term's share of REM evidence should be reported (SleepPSG §5 already measures clock-only vs physiology-only). |
| G6 | **Detection spine is jerk-stillness, tuned for 4.0 counts, with a Cole–Kripke index on rescaled jerk** | `gravityStillThresholdG 0.01`, 15-min/0.70 window; Cole–Kripke weights applied to a quantity that is not an Actiwatch count (te Lindert's transform validates MEMS→counts at 50 Hz, not 1 Hz gravity) | HDCZA on z-angle (van Hees 2018), HR-only period detector with onset/offset refinement (Perez-Pozuelo 2022) | **Medium** (High on sparse nights) | Session bounds move every overnight vital (inventory §3.1). Neither NOOP spine has a PSG onset/offset figure; the literature spines do. |
| G7 | **HR-only anchor = p10 × 1.05 of the window** | `hrOnlyAnchorPercentile 0.10`, `hrOnlyBandMult 1.05`; no onset/offset refinement; gap breaks run | Perez-Pozuelo: quantile of the 24-h ECDF (Q 0.325 day / 0.80 night), 5-min median, 20-min min block, 90-min merge, rolling-std refinement; vs PSG onset +20.7 min, TST −29 min | **Medium** | NOOP's is structurally the same family; what it lacks is the refinement step and a measured onset/offset error. R5's > 10 bpm drift is a *multiplier* problem both share; within-window quantiles do not cross days. |
| G8 | **No validation of staging under sparse / gapped motion** | `isGravitySparse` switches the *detector*; the *stager* silently loses `moveFrac`/`jerkMax` (empty grav → `jerkScale = 1e−6`) | no fetched study degrades motion to 1 Hz with gaps; Walch's HR-only line (3-class κ 0.04) is the nearest lower bound | **High** for the owner, **unmeasurable today** | R8: state it. §5 proposes the ablation that makes it measurable (downsample sleep-accel to 1 Hz and inject gaps inside SleepPSG). |
| G9 | **Transition matrix a-priori; REM-latency guard a-priori** | fixed rows; guard 3.0 log-odds over 60 min | HMM transition rows are routinely estimated from training hypnograms (counts of stage pairs); Beattie uses post-processing rules | **Low** | SleepPSG's variant table already shows transition-row edits move κ by ~0.01; small lever. |
| G10 | **Band `sleep_state` veto default-off, evidence conflicting** | one wearer: band says asleep on ~2/3 of NOOP's wake epochs; PSG says NOOP already under-calls wake | de Zambotti/Chinoy/Schyvens: every consumer device under-calls wake (spec 40–54 %), so the band is likely *also* under-calling | **Low** as a scorer input; **useful as a reference** | Two devices agreeing are two estimates (R8). Keep the band as a sleep/wake reference for the owner's nights, not as truth. |

---

## 4. WHOOP 5.0 input constraints

Status column is CONFIRMED from `docs/research/00-inventory.md` §1 and `README.md` "WHOOP 5.0 / MG
analysis limits"; consequences are INFERRED.

| Input the recipe reads | 5.0 reality | Consequence for V2 / detection | Degradation recommendation |
|---|---|---|---|
| Per-second HR (`hr`, `hrVar`, `hrFlat11`) | 1 Hz R18 when banked; PPG-HR filler (`ppgHrSample`, conf ≥ 0.3) fills gaps; live BLE HR ~30 s | Dense enough — denser than sleep-accel's 8–10 s. The 5-/11-min std windows are well populated. | None needed. Record per-night HR coverage (samples / expected) next to every result (R4 coverage row). Exclude filler-HR seconds from `hrVar` if the filler is smoother than real HR (measure first). |
| Gravity x/y/z (`moveFrac`, `jerkMax`, `jerkScale`) | 1 Hz at best, **sparse and gapped**; `isGravitySparse` fires on span < 50 % or a gap > 20 min | Jerk floor = median of few samples → `moveThr` noisy; wake gate misfires or never fires; wake under-call worsens. With no gravity, `jerkScale = 1e−6` and `moveFrac = 0` → motion-quiescent on every epoch, so the wake cardiac term is clamped ≤ 0 everywhere (CONFIRMED in `motionQuiescent`) — an HR-only night can promote wake only through `zmv = 0` + prior, i.e. almost never. | (a) Replace jerk with **per-minute z-angle change / posture variance** (van Hees-style) as the motion feature when sample density < N/min; it needs orientation, which 1 Hz gives. (b) When motion is absent, *un-clamp* the cardiac wake term but require Perez-Pozuelo-style sustained HR volatility (10-min rolling std > a night-relative threshold) so wake is still callable. (c) Report `stagingSparse`/`hrOnly` on every session and never let an HR-only night move the wake-fraction baseline. |
| R-R intervals (`respReg`) | ≤ 4 words/s in R18; **500 ms filler beats at rest** flagged `tsSuspect = 1`; `beatAccurateFraction` and `classifyCoverage` gates exist for HRV | Filler beats produce a perfectly regular tachogram → spectral peakedness goes *up* → the RSA term votes **deep** on exactly the epochs the strap was least able to see beats. This is the #194 shape (a manufactured periodic peak). Untested because sleep-accel has no R-R. | **Before anything else**: feed only beats with `tsSuspect = 0` and only epochs whose beat window passes `beatAccurateFraction` into `respRegularity`; otherwise return nil (neutral). Then measure the term on a PSG set that *has* R-R (§5: DREAMT E4 IBI, CinC ECG). |
| Raw respiration (`resp`) | absent on 5.0 (4.0 only) | V2 does not consume it; no change | — |
| Band `sleep_state` byte 81 bits 4–5 (0 wake / 1 still / 2 sleep / 3 up) | present on banded nights | Independent sleep/wake *estimate*; carries no stage resolution | Use as the owner's nightly sleep/wake reference with the R1 domain stated (whole-record vs in-session), never as stage truth. |
| Step counter + activity class | present | Only `WakeMotionRefinement` reads it (default OFF, needs dense gravity *and* steps) | Keep OFF until a PSG-backed wake figure exists; on 5.0 the density gate is the right guard. |
| High-rate IMU | opt-in capture only | not a staging input | out of scope |

Net recommendation for graceful degradation (INFERRED): keep one recipe, but make the *feature
availability* explicit per epoch and let the fitted emission (G2) carry a per-feature "missing → neutral"
contract that is validated under three synthetic regimes on the PSG sets — full motion, 1 Hz gapped
motion, no motion — so the published κ/bias table has three columns rather than one. The literature
lower bound for the no-motion column with hand features is κ ≈ 0.04 (3-class, Walch HR-only); anything
NOOP claims there must beat a measured number, not that quote.

---

## 5. Validation plan

### 5.1 Public datasets with a PSG reference (all pages fetched this session)

| Dataset | What it has | Wrist HR / R-R / raw PPG | Access & licence | Size | Fit for NOOP |
|---|---|---|---|---|---|
| **PhysioNet `sleep-accel`** (Walch 2019), doi 10.13026/hmhs-py35 | 31 healthy adults; Apple Watch accel (x/y/z in g, ~50 Hz), PPG HR (bpm, every 8–10 s), steps; PSG labels W/N1/N2/N3/REM per 30 s | HR yes; **no R-R, no raw PPG** | Open, ODC-By 1.0 (attribution required) | 550 MB zip / 2.2 GB | Already wired into `Tools/SleepPSG`. Stage κ, bias, onset. Cannot test the RSA term or HR-only-on-sparse-HR realism (its HR is already sparse). |
| **PhysioNet DREAMT v2.2.0** (Wang et al. 2024/2025), doi 10.13026/0vrv-nn81 | 100 patients from a sleep-disorders lab; Empatica E4 BVP 64 Hz, ACC 32 Hz, EDA/TEMP 4 Hz, **HR 1 Hz, IBI (ms)**; technician-scored PSG 30 s (P/W/N1/N2/N3/R/Missing); v2.2.0 fixed an ACC–PSG misalignment | HR yes; **IBI yes**; raw BVP yes | **Restricted**: PhysioNet account + Restricted Health Data Use Agreement 1.5.0 (no credentialing course stated) | not stated | The one open-ish set that exercises every V2 input incl. the RSA term and 1 Hz HR. Clinical population (sleep disorders) — report that stratum. The CHIL 2024 paper's own result (F1 0.823, κ 0.695) is a sleep/wake-type task per its abstract wording, not 4-class (INFERRED). |
| **PhysioNet/CinC 2018 "You Snooze, You Win"**, doi 10.13026/6phb-r450 | 1 985 MGH lab subjects (994 training with labels); EEG/EOG/EMG/**ECG 200 Hz**/SaO2; stages W/1/2/3/REM per 30 s + arousals | **No wrist signal**; R-R derivable from ECG → synthesise 1 Hz HR + R-R | Open, ODC-By 1.0 | **266 GB** (135 GB training) | Large-n test of the **HR-only / HR+R-R** path (NOOP's `hrOnlySessions` + V2 with empty gravity) and of the RSA term with *clean* beats, plus a way to inject WHOOP-shaped sparsity (keep ≤ 4 beats/s, add 500 ms fillers) and measure the damage. Sridhar and Pini publish HR-only κ on it (0.55 / 0.51) — a yardstick. |
| **NSRR MESA Sleep** (Chen 2015; Zhang 2018) | 2 230 adults aged 54–93; home PSG with ECG; wrist actigraphy (Actiwatch Spectrum, 30 s counts per Palotti 2019) | counts only; R-R from PSG ECG | NSRR data-use agreement + IRB evidence (Zhang 2018); the sleepdata.org pages were not reachable this session (TLS error) | large | Older cohort; the external set in Walch (188) and the benchmark in Palotti/Zhai. Useful mainly as a *detection* reference for count-based spines; NOOP has no counts. |
| **NSRR SHHS** (Quan 1997) | planned 6 600 adults ≥ 40; home PSG incl. ECG | no wrist | NSRR DUA | large | HR-only staging training ground (Sridhar); same caveats as MESA. |
| **Wearanize+** (Radboud, data.ru.nl) | 130 healthy adults 18–39, one night; Zmax EEG, **Empatica E4**, activPAL; full PSG scored by an expert and by U-Sleep | E4 BVP/IBI/ACC (rates not on the page) | licence not stated on the page (a secondary listing says CC BY 4.0 — unverified) | not stated | Second E4+PSG set, *healthy* stratum to pair with DREAMT's clinical one. |
| **Haaglanden HMC** (PhysioNet, doi 10.13026/t79q-fr32), Sleep-EDF, CAP | PSG only (HMC: 4 EEG, 2 EOG, EMG, ECG at 256 Hz, 151→148 recordings, CC-BY 4.0, 15.7 GB) | no wrist | open | — | ECG→R-R only; smaller than CinC. Sleep-EDF/CAP were not fetched (no wrist channel; listed for completeness). |
| **BiHeartS** (arXiv 2308.06811) | 10 participants × 30 nights in the wild, research + commercial wearables, self-reports | — | CC BY-SA 4.0 | — | **No PSG**; not a validation set. |
| AAUWSS | referenced in-tree only | — | — | — | **Could not be located** (§8). |

Recommended order: `sleep-accel` (already running) → **DREAMT** (sign the DUA; it is the only set
with wrist IBI + 1 Hz HR + PSG) → CinC 2018 (HR-only at scale, synthetic sparsity) → Wearanize+ if its
licence permits. All downloads go to the git-ignored `research-data/`.

### 5.2 Metrics (per `docs/VALIDATION_PROTOCOL.md`)

Every number is reported with its regenerating command, date, input, n, instrument, units and
measured-vs-inherited (R3, R7), and the pre-registered prediction is written before the run (R1).

| Question | Instrument | Reporting rule |
|---|---|---|
| Better than chance at staging? | 4-class Cohen's κ **printed beside the class marginals** (predicted and true %) — pooled *and* mean per-subject, both labelled | R4; SleepPSG §3 already does this |
| Are stage fractions right? | **signed per-stage bias in pp** of all scored epochs (wake/light/deep/REM), pooled and per-subject mean; per-stage precision/recall/F1 | never κ alone; the #348 reversal is the reason |
| Is sleep/wake timing right? | **onset and final-wake error in minutes** (bias ± SD, MAE) vs PSG; TST and WASO bias in minutes | separate from stage κ |
| Is detection right? | sleep/wake κ and sensitivity/specificity on the **whole record** (not only inside detected sessions) with the domain named; plus the in-session figure, labelled | R1's 0.70 swing |
| Does it generalise? | **leave-one-subject-out** on public sets; **temporal hold-out** on the owner's nights (fit on the early block, report on the late block, print both and the gap) | R5 |
| Is the RSA term helping or hurting? | ablation: `respWeight ∈ {0, 0.6}` on DREAMT/CinC, with the filler-beat hygiene on and off; report deep bias and REM bias per cell | R6 mechanism check |
| Motion-sparsity robustness | the same recipe on sleep-accel motion downsampled to 1 Hz, with random 20–90 min gaps, and with motion removed; three columns of κ/bias | makes G8 measurable (R8) |
| Did behaviour change at all? | replay old vs new on identical input, epoch agreement + `--section port` equivalence | before any reference comparison |
| Is the input complete? | per-night coverage (HR samples / expected; gravity samples / expected; R-R beat-accurate fraction) | never an outlier test on the output |

Raw % agreement is published only beside the constant-"light" predictor on the same epochs (R4).

### 5.3 How the owner validates with personal data

The owner has no PSG, so stage truth does not exist for personal nights (R8); what *can* be measured:

1. **WHOOP app export (pre-NOOP era).** The official export carries per-sleep totals (onset, wake time,
   minutes per stage, disturbances) rather than an epoch hypnogram (INFERRED — read the actual column
   set from the file). Measurable against NOOP re-staging the same nights from the raw strap history, if
   that history was ever offloaded: onset/offset error in minutes, TST/WASO bias, **signed per-stage
   bias in minutes**. Not measurable: κ (no epochs). Caveat the result as *agreement between two
   estimators*, since WHOOP's own stages are κ 0.37–0.47 against PSG (Schyvens 2025, Miller 2020).
2. **Manual diary (lights-off, estimated onset, final wake, any remembered awakenings).** Gives onset/
   offset error in minutes against a human-recorded reference — the same reference van Hees 2018 and
   Perez-Pozuelo 2022 used, with their known limitations. Keep it for ≥ 4 weeks so the temporal split has
   an early and a late block; pre-register which nights are excluded (travel, illness) *before* looking.
3. **Band `sleep_state`.** Nightly sleep/wake agreement with the strap's own classifier, whole-record and
   in-session, both labelled. It is an independent estimate, not truth.
4. **A chest strap (Polar H10) worn for a few nights** gives clean R-R beside the WHOOP's sparse R-R:
   measure how often `respRegularity` returns a *different* verdict on the WHOOP tachogram than on the
   H10 tachogram for the same epochs. This isolates the filler-beat risk without any PSG.
5. **`Tools/SleepBench` E.-1 audit** on every DB copy before any of the above, with its printed exclusion
   list; < 5 surviving reference nights → "cannot be measured on this reference set".

---

## 6. Implementation sketch

All items are Swift + Kotlin, dependency-free, parity-oracle-tested (`AGENTS.md`: compile the Swift
helper standalone, paste its stdout as the Kotlin expected literal). No source changes until Phase 3
approval. Ordered by evidence-per-effort.

### 6.1 Item A — R-R hygiene for the RSA term (S, low risk)

Mechanism: `respRegularity` currently receives every `rrInterval` row in `[e−90, e+120)` clamped to
300–2000 ms. Add two guards before the DFT:

```
beats ← rr rows with tsSuspect == 0 (drop 500 ms fillers) and srcChannel ∈ scored set
if beatAccurateFraction(beats, window) < 0.5 → respReg = nil   // neutral, exactly as "too few beats"
```

Validation: DREAMT (IBI) and CinC (ECG R-R) with/without synthetic WHOOP sparsity; report deep and REM
signed bias and κ for `respWeight 0.6` vs `0` in each cell. Pre-registered prediction: on sparsified
input the un-guarded term increases deep share; the guarded term does not. Risk: low — the only
behaviour change on current WHOOP nights is "fewer epochs carry an RSA vote". Parity: a pure
function; oracle over a sweep of synthetic tachograms.

### 6.2 Item B — fitted linear emission, pinned as constants (M, medium risk)

Keep the whole V2 pipeline (features, night z-scoring, deep gate, cycle prior, Viterbi, transition
matrix). Replace the hand-set emission coefficients with a **multinomial logistic regression** fitted
offline in Python (numpy only, no framework) on per-epoch features, LOSO across subjects, on
`sleep-accel` + DREAMT (+ CinC for the no-motion regime):

```
x = [zhr, zhv, fpct, zmv, jerkGate(0/1), zrg (or 0 + missing flag), angleVar (new), c, guard(min), hrSlope5 (new)]
log p(stage | x) ∝ W·x + b            (4 × ~11 weights + 4 biases)
em[s] = log softmax(W x + b)[s]       → feeds the existing viterbi unchanged
```

Pin `W`, `b` as `static let` arrays with the fit's provenance (dataset, split, date, commit) in the
doc comment; the same literals in Kotlin; an oracle test over a fixed feature grid. Fit three variants
(full motion / 1 Hz gapped / none) and ship either one set with missing-feature neutrality or three
sets selected by the measured density (the `WakeMotionRefinement.isMotionDense` precedent).

Pre-registered thresholds (R1): pooled κ on the held-out subjects +0.05 over 0.371; |deep bias| and
|wake bias| not larger; REM bias toward zero; onset MAE not worse. Effort M (Python fit script in
`Tools/` or `research-data/`, Swift + Kotlin constants, tests, SleepPSG `RecipeConfig` extension).
Risk: medium — a fit on 31 healthy + 100 clinical subjects can overfit cohorts; the LOSO and the three
regimes are the guard, and the result ships behind the existing `PuffinExperiment` flag until the
held-out column clears (CONTRIBUTING rule).

### 6.3 Item C — posture-angle motion feature and HDCZA-style spine for sparse gravity (M, low–medium)

Features (both already partially exist: `postureVariance` in `WakeMotionRefinement`):

```
angleZ(t) = atan2(z, sqrt(x² + y²)) · 180/π     per gravity sample (1 Hz is enough)
epochAngleRange = max − min of angleZ over the 30 s epoch (or 5-min window for the spine)
```

Spine (van Hees 2018 shape): 5-min rolling median of |ΔangleZ|; "inactive" when < 5°; sleep-period
candidates = inactivity blocks, gaps < 60 min bridged, blocks < 30 min dropped; the longest block per
night is the SPT window. Use it in place of the jerk-stillness spine **only when** `isGravitySparse`
is true and gravity density is still ≥ 1 sample/min; otherwise fall through to `hrOnlySessions`.
Staging: add `angleVar` to the emission (Item B) so wake can be promoted by posture change at 1 Hz.

Validation: onset/offset minutes and sleep/wake κ (whole-record) on sleep-accel with motion
downsampled to 1 Hz and gapped; prediction: onset MAE not worse than the current spine on dense
motion and better on sparse. Effort M. Risk: low–medium (detection moves every overnight vital, so
Item C ships with a replay-diff over the owner's history and a flag).

### 6.4 Item D — HR-only onset/offset refinement (S, low risk)

Port the Perez-Pozuelo refinement into `hrOnlySessions` after `mergePeriods`:

```
σ10(t) = rolling 10-min std of 1 Hz HR
onset  = last t in [runStart − 240 min, runStart + 60 min] with σ10 > τ, else runStart
offset = first t in [runEnd − 60 min, runEnd + 240 min] with σ10 > τ, else runEnd
τ = max(6 bpm, k · night-median σ10)           // night-relative floor, same idiom as the jerk floor
```

Also raise the minimum block to 20 min and bridge gaps ≤ 90 min *inside the HR-only path* when the
HR median on both sides is in band (the current path deliberately never bridges; this is a measured
change, not a rule change). Validation: CinC (synthetic 1 Hz HR from ECG) and the owner's diary;
report onset/offset bias ± SD in minutes early vs late block. Prediction: onset bias moves from
late toward zero (the literature says HR-only onset is +20 min late). Risk: low; `hrOnly` flag stays.

### 6.5 Item E — un-clamp wake on motion-absent nights, gated on HR volatility (S, medium risk)

In `stageEpochs`, when `jerkScale ≤ 1e−6` (no gravity at all), treat `motionQuiescent` as *unknown*
rather than *true*, and allow the cardiac wake term only when `hrVar` percentile > 0.9 for ≥ 2
consecutive epochs. Measure on CinC-derived HR-only nights (wake fraction and WASO bias) before
flipping; otherwise it re-creates the #437 wake blow-out on hot-but-still nights. Risk medium; do after
Item B so the weight is fitted, not guessed.

### 6.6 Not recommended now

- Small gradient-boosted trees or a tiny LSTM exported as weights: feasible in principle (both are
  plain arithmetic), but a 100 k-parameter model cannot be oracle-verified by reading, the parity
  contract becomes a binary blob, and the fetched evidence says the gain over a fitted linear emission
  is ~0.1 κ *with beat-level HRV the 5.0 does not reliably provide*. Revisit if DREAMT/CinC show the
  linear ceiling has been reached.
- Flipping `bandStateWakeVetoEnabled`: PSG says NOOP under-calls wake; the veto only removes wake.
- Deep-prior or transition retuning by hand: the variant table shows ~0.01 κ levers; Item B subsumes it.

Effort summary: A S · B M · C M · D S · E S. Suggested order A → D → C → B → E, because A and D need
no new reference data beyond CinC and the owner's diary, and C/B need DREAMT access first.

---

## 7. Sources (verified)

Each entry: citation · DOI/URL fetched · what was verified from the fetched text.

1. Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. *Automatic sleep/wake identification from
   wrist activity.* Sleep 1992;15(5):461–469. doi:10.1093/sleep/15.5.461 (Europe PMC record, PMID
   1455130). Verified: 41 subjects (18 normal, 23 disordered), ~88 % sleep/wake agreement, r 0.82/0.90
   for sleep % and latency.
2. Sadeh A, Sharkey KM, Carskadon MA. *Activity-based sleep-wake identification: an empirical test of
   methodological issues.* Sleep 1994;17(3):201–207. doi:10.1093/sleep/17.3.201, PMID 7939118. Verified:
   20 adults + 16 adolescents, 91–93 % agreement, sleep > wake agreement.
3. te Lindert BHW, Van Someren EJW. *Sleep estimates using microelectromechanical systems (MEMS).*
   Sleep 2013;36(5):781–789. doi:10.5665/sleep.2648, PMID 23633761, PMC3624832. Verified: 50 Hz MEMS →
   counts via Passing–Bablok; κ 0.87/0.85/0.83 vs actigraph at three thresholds; n = 15; **no PSG**.
4. van Hees VT et al. *A novel, open access method to assess sleep duration using a wrist-worn
   accelerometer.* PLoS ONE 2015;10(11):e0142533. doi:10.1371/journal.pone.0142533. Verified: z-angle,
   5°/5-min rule, PSG n = 28 accuracy 83 %, +31 min; diary κ 0.32/0.39.
5. van Hees VT et al. *Estimating sleep parameters using an accelerometer without sleep diary.* Sci
   Rep 2018;8:12975. doi:10.1038/s41598-018-31266-z, PMC6113241 (Europe PMC record). Verified: C-stat
   0.86 clinic (n 28) / 0.83 healthy (n 22); SPT +10.9/+2.9 min vs diary (n 3 752).
6. Walch O, Huang Y, Forger D, Goldstein C. *Sleep stage prediction with raw acceleration and
   photoplethysmography heart rate data derived from a consumer wearable device.* Sleep
   2019;42(12):zsz180. https://academic.oup.com/sleep/article/42/12/zsz180/5549536. Verified: n 31;
   2-class ~90 %/93 %/59.6 %, AUC 0.878, κ ≈ 0.455; 3-class ~72 %, κ 0.277 (all), HR-only 0.040,
   motion-only 0.084; no 4-class; HR every 8–10 s; accel ~50 Hz; DoG HR feature σ 120/600 s; MESA 188
   κ 0.525 / 3-class ~69 %.
7. Walch O. *Motion and heart rate from a wrist-worn wearable and labeled sleep from polysomnography*
   (v1.0.0). PhysioNet 2019. doi:10.13026/hmhs-py35. Verified: ODC-By 1.0, 31 subjects, labels
   0/1/2/3/5, no R-R, no raw PPG, 550 MB zip.
8. `ojwalch/sleep_classifiers` GitHub, MIT. https://github.com/ojwalch/sleep_classifiers. Verified:
   MIT licence; count + cosine clock features; note that REM/NREM labels are swapped in two figure lines.
9. Fonseca P et al. *Validation of photoplethysmography-based sleep staging compared with
   polysomnography in healthy middle-aged adults.* Sleep 2017;40(7):zsx097. doi:10.1093/sleep/zsx097,
   PMID 28838130 (Europe PMC abstract). Verified: 2-class κ 0.55 ± 0.14 / 91.5 %; 3-class 0.46 ± 0.15 /
   72.9 %; 4-class 0.42 ± 0.12 / 59.3 %; actigraphy κ 0.40.
10. Fonseca P et al. *Automatic sleep staging using heart rate variability, body movements, and
    recurrent neural networks in a sleep disordered population.* Sleep 2020;43(9):zsaa048.
    doi:10.1093/sleep/zsaa048, PMID 32249911. Verified: 4-class κ 0.60 / 75.9 %; insomnia 0.62; REM
    parasomnia 0.47; 2-class κ 0.65, wake sens 72.9 %.
11. van Gilst MM et al. *Direct application of an ECG-based sleep staging algorithm on reflective
    photoplethysmography data decreases performance.* BMC Res Notes 2020;13:513.
    doi:10.1186/s13104-020-05355-0, PMC7653690. Verified: n 389; κ 0.56 vs 0.60; 73.0 vs 75.9 %.
12. Wulterkens BM et al. *It is all in the wrist: wearable sleep staging in a clinical population versus
    reference polysomnography.* Nat Sci Sleep 2021;13:885–897. doi:10.2147/NSS.S306808, PMC8253894.
    Verified: PPG 32 Hz + accel 128 Hz, 132 HRV features, bi-LSTM; hold-out 292; κ 0.62 ± 0.12 / 76.4 %;
    per-stage κ W 0.66, N1N2 0.54, N3 0.60, R 0.69.
13. Radha M et al. *Sleep stage classification from heart-rate variability using long short-term memory
    neural networks.* Sci Rep 2019;9:14149. doi:10.1038/s41598-019-49703-y, PMC6775145. Verified: ECG HRV
    (SIESTA), 292 subjects, 132 features; κ 0.61 ± 0.15 / 77.0 %; N3 κ 0.53; age r −0.45.
14. Radha M et al. *A deep transfer learning approach for wearable sleep stage classification with
    photoplethysmography.* npj Digit Med 2021;4:135. doi:10.1038/s41746-021-00510-8, PMID 34526643
    (abstract via search result + record). Verified: PPG, 60 healthy / 101 recordings; κ 0.65 ± 0.11 /
    76.36 %.
15. Beattie Z et al. *Estimation of sleep stages in a healthy adult population from optical
    plethysmography and accelerometer signals.* Physiol Meas 2017;38:1968. doi:10.1088/1361-6579/aa9047.
    Verified: Fitbit Surge, n 60, LDA 54 features LOO; 69 % / κ 0.52 ± 0.14; REM 102 vs 88 min; sleep
    sens 94.6 %, wake spec 69.3 %; inter-scorer κ 0.72.
16. Sridhar N et al. *Deep learning for automated sleep staging using instantaneous heart rate.* npj
    Digit Med 2020. doi:10.1038/s41746-020-0291-x, PMC7441407. Verified: ECG IHR at 2 Hz; SHHS test 800
    nights κ 0.66 / 77 %; CinC 993 κ 0.55 / 72 %; deep recall 0.49; PPG generalisation untested.
17. Pini N et al. *An automated heart rate-based algorithm for sleep stage classification.* Front
    Neurosci 2022. doi:10.3389/fnins.2022.974192. Verified: RR-tachogram TCN; CinC 988: 2-/3-/4-level κ
    0.575 / 0.603 / 0.512; Z3Pulse 52: 0.588 / 0.611 / 0.525; deep sens 0.38–0.48; Neurobit affiliation.
18. Perez-Pozuelo I et al. *Detecting sleep outside the clinic using wearable heart rate devices.* Sci
    Rep 2022;12:7956. doi:10.1038/s41598-022-11792-7, PMC9106748. Verified (full text via publisher):
    algorithm steps (Q 0.325/0.80, 5-min median, L 20 min, G 90/420 min, σ10 > 6 bpm refinement);
    PhysioNet κ 0.59, TST −29.1, onset +20.7, offset −8.3 min; MESA TST −55.0, onset +40, offset −15;
    angle method κ 0.71 on PhysioNet; internal inconsistencies noted.
19. Sundararajan K et al. *Sleep classification from wrist-worn accelerometer data using random
    forests.* Sci Rep 2021;11:24. doi:10.1038/s41598-020-79217-x, PMC7794504. Verified: 134 train / 24
    test; RF κ 0.50 vs van Hees 0.42, Sadeh 0.37, Cole–Kripke 0.36; stage F1 N3 21 %, REM 12 %.
20. Palotti J et al. *Benchmark on a large cohort for sleep-wake classification with machine learning
    techniques.* npj Digit Med 2019;2:50. doi:10.1038/s41746-019-0126-9, PMC6555808 (Europe PMC full
    text). Verified: MESA 1 817 (1 454/363), Actiwatch Spectrum; Cole–Kripke 75.4 % / F1 81.2; Oakley
    θ10 77.5; LSTM 83.1 / 85.5; no HRV features.
21. Zhai B et al. *Making sense of sleep: multimodal sleep stage classification in a large, diverse
    population using movement and cardiac sensing.* Proc ACM IMWUT 2020;4(2):67. doi:10.1145/3397325
    (Northumbria portal abstract). Verified: 1 743 participants; 3-stage 78.2 % / F1 69.8; cardiac
    frequency features critical.
22. Olsen M et al. *A flexible deep learning architecture for temporal sleep stage classification using
    accelerometry and photoplethysmography.* IEEE Trans Biomed Eng 2023;70:228–237.
    doi:10.1109/TBME.2022.3187945 (DTU Orbit abstract). Verified: 301 training recordings; wrist hold-out
    35: κ 0.58 ± 0.18 / 0.69; internal κ 0.58/0.64/0.59. **Not** a *Sleep* paper as the brief's lead said.
23. Kotzen K et al. *SleepPPG-Net: a deep learning algorithm for robust sleep staging from continuous
    photoplethysmography.* arXiv:2202.05735 (v4, 2022). doi:10.48550/arXiv.2202.05735. Verified: raw
    PPG, 2 374 patients; median κ 0.75; 0.74 external after transfer.
24. Miller DJ et al. *A validation study of the WHOOP strap against polysomnography to assess sleep.*
    J Sports Sci 2020;38(22):2631–2636. doi:10.1080/02640414.2020.1797448, PMID 32713257. Verified: n 12,
    86 sleeps; 2-stage 89 % / κ 0.49 / sens 95 % / spec 51 %; 4-stage 64 % / κ 0.47; stage sens 62/68/70/51;
    TST +8.2 ± 32.9 min.
25. Miller DJ, Sargent C, Roach GD. *A validation of six wearable devices for estimating sleep, heart
    rate and heart rate variability in healthy adults.* Sensors 2022;22(16):6317. doi:10.3390/s22166317,
    PMID 36016077. Verified: n 53; per-device 2-state / multi-state κ (WHOOP 3.0 0.44 / 0.44; Oura 2
    0.51 / 0.43; Apple Watch S6 0.30 / 0.20; Garmin 0.35 / 0.25; Polar 0.44 / 0.28; Somfit 0.48 / 0.52).
26. Schyvens AM et al. *A performance validation of six commercial wrist-worn wearable sleep-tracking
    devices for sleep stage scoring compared to polysomnography.* SLEEP Advances 2025;6(2):zpaf021.
    doi:10.1093/sleepadvances/zpaf021. Verified: n 62; WHOOP 4.0 n 40: sens 93.6 %, spec 40.1 %, 4-state
    κ 0.37 ± 0.16; biases TST +24.5, WASO −19.2, deep +31.5, light −28.5, REM +15.3, SOL −11.0 min.
27. Schyvens AM et al. *Accuracy of Fitbit Charge 4, Garmin Vivosmart 4, and WHOOP versus
    polysomnography: systematic review.* JMIR mHealth uHealth 2024;12:e52192. doi:10.2196/52192,
    PMC11004611. Verified: 8 studies; WHOOP least disagreement for TST (−1.4), light (−9.6), deep (−9.3)
    min, largest for REM (21.0 min).
28. Chinoy ED et al. *Performance of seven consumer sleep-tracking devices compared with
    polysomnography.* Sleep 2021;44(5):zsaa291. doi:10.1093/sleep/zsaa291, PMC8120339. Verified: n 34;
    per-device sensitivity/specificity/PABAK (Fitbit Alta HR 0.95/0.54/0.80; Actiwatch 0.97/0.39/0.78;
    Garmin 0.99/0.18–0.19); stage biases in minutes; misclassified wake/deep/REM mostly → light.
29. de Zambotti M et al. *The sleep of the ring: comparison of the ŌURA sleep tracker against
    polysomnography.* Behav Sleep Med 2019;17(2):124–136 (online 2017).
    doi:10.1080/15402002.2017.1300587, PMC6095823. Verified: n 41 (14–22 y); sens 95.5 %, spec 48.1 %;
    light 64.6 / deep 50.9 / REM 61.4 %; deep under by 19.6 min, REM over by 17.2 min; κ not reported.
30. Roberts DM et al. *Detecting sleep using heart rate and motion data from multisensor consumer-grade
    wearables, relative to wrist actigraphy and polysomnography.* Sleep 2020;43(7):zsaa045.
    doi:10.1093/sleep/zsaa045, PMID 32215550, PMC7355403 (Europe PMC abstract). Verified: 8 × 4 nights;
    wearable classifiers sens 0.883–0.977, spec 0.407–0.821; research devices spec 0.366–0.647.
31. Stone JD et al. *Evaluations of commercial sleep technologies for objective monitoring during
    routine sleeping conditions.* Nat Sci Sleep 2020;12:821–842. doi:10.2147/NSS.S270705. Verified: 5
    adults, 98 nights, Sleep Profiler reference; WHOOP 2.0 TST MAPE 8.78 %; stage MAPE deep 46 % / REM
    58 % (best), "no device accurately quantified stages". **Not** J Biol Rhythms as the lead said.
32. Haghayegh S et al. *Accuracy of wristband Fitbit models in assessing sleep: systematic review and
    meta-analysis.* J Med Internet Res 2019;21(11):e16273. doi:10.2196/16273, PMID 31778122. Verified:
    22 reviewed / 8 pooled; non-staging sens 0.87–0.99, spec 0.10–0.52; staging sens 0.95–0.96, spec
    0.58–0.69; staging models: SOL underestimated, TST/SE/WASO n.s.
33. Lee T et al. *Accuracy of 11 wearable, nearable, and airable consumer sleep trackers: prospective
    multicenter validation study.* JMIR mHealth uHealth 2023;11:e50983. doi:10.2196/50983, PMC10654909
    (Europe PMC full text). Verified: n 75; 4-stage κ Apple Watch 8 0.30, Galaxy Watch 5 0.42, Fitbit
    Sense 2 0.42, Oura Ring 3 0.35, Pixel Watch 0.40; per-stage F1/sens/spec table.
34. Kanady JC et al. *Validation of sleep measures in a wearable device (Basis B1)* — J Clin Sleep Med
    2020, doi:10.5664/jcsm.8362 (fetched by accident while resolving Roberts 2020; retained because it
    is a clean example of the failure mode): sens 98.9 %, spec 8.1 %; "not useful for the assessment of
    wake".
35. Rosenberg RS, Van Hout S. *The American Academy of Sleep Medicine inter-scorer reliability program:
    sleep stage scoring.* J Clin Sleep Med 2013;9(1):81–87. doi:10.5664/jcsm.2350, PMC3525994. Verified:
    82.6 % overall; W 84.1, N1 63.0, N2 85.2, N3 67.4 %; > 2 500 scorers, 1 800 epochs.
36. Berry RB et al. *AASM scoring manual updates for 2017 (version 2.4).* J Clin Sleep Med
    2017;13(5):665–666. doi:10.5664/jcsm.6576 (Europe PMC metadata only; the manual page itself
    returned 403). Verified: bibliographic record; stage nomenclature W/N1/N2/N3/R and the 30 s epoch are
    taken from the fetched validation studies that apply it (Beattie, Fonseca, Chinoy, Rosenberg).
37. Khosla S et al. *Consumer sleep technology: an American Academy of Sleep Medicine position
    statement.* J Clin Sleep Med 2018;14(5):877–880. doi:10.5664/jcsm.7128. Verified: CSTs "cannot be
    utilized for the diagnosis and/or treatment of sleep disorders at this time"; validation against PSG
    and raw-data access called for.
38. Wang K, Yang J, Shetty A, Dunn J. *DREAMT: Dataset for Real-time sleep stage EstimAtion using
    Multisensor wearable Technology* (v2.0.0 and current v2.2.0). PhysioNet. doi:10.13026/0vrv-nn81;
    https://physionet.org/content/dreamt/. Verified: 100 participants, E4 BVP 64 Hz / ACC 32 Hz / EDA,
    TEMP 4 Hz / HR 1 Hz / IBI ms; PSG 30 s labels; Restricted Health Data Licence 1.5.0 + DUA; v2.2.0
    (2026-06-02) fixed ACC–PSG misalignment.
39. Wang WK et al. *Addressing wearable sleep tracking inequity: a new dataset and novel methods for a
    population with sleep disorders.* Proc CHIL 2024, PMLR 248:380–396.
    https://proceedings.mlr.press/v248/wang24a.html; code https://github.com/WillKeWang/DREAMT_FE.
    Verified: Duke Sleep Disorders Center, E4 + PSG; F1 0.823 ± 0.019, AUROC 0.926, κ 0.695 ± 0.025 for
    a sleep-onset/wakefulness task (abstract wording); PDF text not extractable here.
40. Ghassemi MM et al. *"You Snooze, You Win": the PhysioNet/Computing in Cardiology Challenge 2018*
    (v1.0.0). doi:10.13026/6phb-r450 (dataset), 10.22489/CinC.2018.049 (paper). Verified: 1 985 subjects
    (994 training labels), EEG/EOG/EMG/ECG at 200 Hz, SaO2, 30 s stages + arousals, ODC-By 1.0, 266 GB.
41. Alvarez-Estevez D, Rijsman R. *Haaglanden Medisch Centrum sleep staging database* (v1.1).
    PhysioNet. doi:10.13026/t79q-fr32. Verified: 151 (→148) PSGs, 256 Hz EEG/EOG/EMG/ECG, CC BY 4.0,
    15.7 GB, no wearable channel.
42. Zhang GQ et al. *The National Sleep Research Resource: towards a sleep data commons.* J Am Med
    Inform Assoc 2018;25(10):1351–1358. doi:10.1093/jamia/ocy064, PMC6188513. Verified: 10 cohorts,
    26 808 subjects, 31 166 EDFs; dataset-specific DUAs and IRB evidence.
43. Chen X et al. *Racial/ethnic differences in sleep disturbances: the Multi-Ethnic Study of
    Atherosclerosis (MESA).* Sleep 2015;38(6):877–888. doi:10.5665/sleep.4732, PMC4434554. Verified:
    MESA Sleep n 2 230, ages 54–93, PSG + actigraphy 2010–2013.
44. Quan SF et al. *The Sleep Heart Health Study: design, rationale, and methods.* Sleep
    1997;20(12):1077–1085. doi:10.1093/sleep/20.12.1077. Verified: planned 6 600 adults ≥ 40, home PSG.
45. Sikder NS et al. *Wearanize+: a multimodal dataset (N = 130) with wearable-based at-home overnight
    sleep recordings.* Radboud Data Repository, https://data.ru.nl/collections/di/dcmn/DSC_wearanize_t0000657a_579.
    Verified: 130 adults 18–39, Zmax + Empatica E4 + activPAL + PSG (expert + U-Sleep scores); licence and
    rates not on the page.
46. *BiHeartS* dataset, arXiv:2308.06811, doi:10.48550/arXiv.2308.06811. Verified: 10 participants × 30
    nights in the wild, CC BY-SA 4.0, self-reports, **no PSG**.

---

## 8. Unverified leads

- **AAUWSS.** Named in `SleepStagerV2.swift` (44-subject LOSO benchmark) and in the Kotlin fixture tests
  (`HrvGoldAgreementTest.kt`: "AAUWSS Empatica E4 wrist IBI, AAUWSS PSG 200 Hz ECG"; fixtures generated
  locally from "public datasets", not committed; default path on a contributor's Windows machine). Two
  web searches found no dataset by that name. The description (E4 IBI + 200 Hz PSG ECG) matches DREAMT's
  recording setup, but that is an inference, not a finding. Action: ask the contributor which dataset
  and version this was, and whether the 44-subject LOSO harness still exists; until then the "κ 0.35 vs
  0.03" claim in both V2 headers is a number without a regenerating command (R3).
- **Oakley 1997 Actiwatch algorithm** (Mini Mitter technical report) — used as a comparator by Palotti
  2019 and Sundararajan 2021; the report itself was not fetched.
- **AASM Manual for the Scoring of Sleep and Associated Events** (current version text) — aasm.org
  returned 403; the conventions were taken from papers applying it.
- **Fonseca 2017 per-stage sensitivities** — the PDF fetched as binary; only the abstract-level κ values
  are verified.
- **Lee 2023 TST/WASO per-device bias** and **Schyvens 2025 non-WHOOP device rows** — in the unread
  remainder of those pages.
- **NSRR dataset landing pages** (sleepdata.org/datasets/mesa, /shhs) — TLS certificate error from this
  environment; access terms are taken from Zhang 2018 instead.
- **A 2024–2025 PSG validation of Oura gen 3 or WHOOP 5.0** — none found; WHOOP 4.0 (Schyvens 2025) is
  the most recent independent WHOOP figure.
- **Effect of motion sampling rate / gaps on actigraphy algorithms** — one search found only epoch-length
  comparisons (15/30/60 s on Actical), nothing on 1 Hz gravity or gapped input; treated as unmeasured
  (§3 G8).
- **Perez-Pozuelo 2022 companion code** — the paper says open-source; the repository was not fetched, so
  its licence is unknown. Item D is written from the paper's description, per the brief's licence rule.
- **Olsen 2023 internal-set naming** and **Zhai 2020 κ** — not in the abstracts fetched.

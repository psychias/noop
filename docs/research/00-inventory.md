# 00 — Analytics inventory (Phase 0 of `RESEARCH_BRIEF.md`)

Written 2026-11-10 on branch `research/metrics-literature`, from the tree at `2a1de760`
(`feat(analytics): give women Banister's published multiplier`). This is the map the Phase 1
research agents work from. Every claim here is CONFIRMED by reading the source on this date unless
marked INFERRED. Line numbers drift; function names are the stable handle.

Repo rules that bind the research (read before proposing anything):

- `AGENTS.md` — parity contract (Swift and Kotlin byte-identical analytics; oracle-tested, not eyeballed),
  no new BLE/protocol code here, no CoreBluetooth/UIKit under `Packages/`, design tokens only, migrations
  additive, "derive a physiological signal → validate against the artifact, not one match; land as
  instrumentation or default-off experimental".
- `docs/VALIDATION_PROTOCOL.md` — R1 pre-register, R2 never score against the scorer's own output
  (SleepBench `E.-1` audit), R3 every number ships with its regenerating command, R4 instrument matches
  question (signed per-stage bias, not only kappa), R5 temporal hold-out, R6 base rate + mechanism
  reachable, R7 n/instrument/units/measured-vs-inherited, R8 "cannot be measured" is a result.
- `docs/SCOPE.md` — no diagnostic / arrhythmia language, no alerts off unproven signals, non-medical wording.
- `CONTRIBUTING.md` — a scoring change with no held-out number may ship behind a flag but may not be
  called an improvement.

---

## 0. Toolchain and test baseline (measured 2026-11-10)

| Item | Result |
|---|---|
| Swift toolchain | Apple Swift 6.3.3, `xcode-select -p` = `/Library/Developer/CommandLineTools` (no Xcode.app installed). |
| `cd Packages/StrandAnalytics && swift test` | **Cannot run on this machine.** Sources compile (613/615 compile steps succeed), then every test file fails with `error: no such module 'XCTest'` — the Command Line Tools do not ship XCTest. `swift build` of the package is green. |
| StrandAnalytics test corpus | 201 test files, 2,152 `func test…` cases (counted with `grep -c`). CI (`swift-packages.yml`, macos-15) runs them; the last `main` CI state is the baseline until Xcode is installed locally. |
| Android | JDK 17.0.13 present; `android/local.properties` absent and `~/Library/Android/sdk` absent → `./gradlew testFullDebugUnitTest` not run. 247 Kotlin test files under `android/app/src/test/java/com/noop/analytics` (incl. `agreement/`). |
| Real-data harnesses | `Tools/SleepBench` (replays stagers over a wearer's DB copy), `Tools/SleepPSG` (replays shipped `SleepStagerV2` over PhysioNet `sleep-accel`, Walch 2019). Neither run here yet; `sleep-accel` is ~577 MB and belongs in `research-data/` (git-ignored as of this branch). |

**Action for the user:** installing Xcode (or `xcode-select -s /Applications/Xcode.app/...`) is required
before Phase 3 can run any Swift test locally. Until then Swift tests are CI-only.

---

## 1. What the WHOOP 5.0 actually gives NOOP (inputs)

Storage is `Packages/WhoopStore` (GRDB), decoded by `Packages/WhoopProtocol`. Per-second tables keyed
`(deviceId, ts)` unless noted. Status column is for a **5.0/MG bonded exclusively to NOOP**
(the user's situation), per `README.md` "WHOOP 5.0 / MG analysis limits" and `docs/PROTOCOL_SENSORS.md`.

| Signal | Table / struct | Resolution & source on 5.0 | Status on 5.0 |
|---|---|---|---|
| Heart rate | `hrSample(bpm)` | R18 history record byte 22, nominally 1 Hz when the strap banks v18; live standard BLE HR ~every 30 s while connected. | Reliable when offloaded. Gaps occur on v26-heavy (PPG-waveform) stretches. |
| PPG-derived HR (gap filler) | `ppgHrSample(bpm, conf)` (v12) | `WhoopProtocol.PpgHr`: 8-s autocorrelation over the 24 Hz v26 optical buffer; 30–220 bpm band; `minConfidence 0.3`. Reads `COALESCE(hrSample, ppgHrSample)`. | Default-on filler for HR continuity only. Flagged "Building" confidence. Explicitly **no HRV / no motion** from it. |
| R-R intervals | `rrInterval(rrMs, seq, ord, srcChannel, tsSuspect)` | R18 carries **≤ 4 R-R words per second** (1/1024 s ticks); standard BLE 0x2A37 live carries R-R too. Scored channels = `srcChannel IN (5, 7)` (`Whoop5RRReadPolicy`). | **Sparse/intermittent.** The strap emits a 500 ms filler beat at rest (flagged `tsSuspect=1` by `v47-rr-whoop5-fill` when same-second HR < 100). `HRVAnalyzer.classifyCoverage` / `beatAccurateFraction` gate over-/under-counted nights. README: "Overnight HRV and respiratory rate incomplete unless sufficient R-R intervals are captured." |
| Gravity / motion | `gravitySample(x,y,z,dynAccel)` | R18 f32 gravity x/y/z (bytes 45–56) + dynamic accel (byte 41), **1 Hz at best, sparse in practice**. | **Sparse** → `SleepStager.isGravitySparse` (gravity span < 50 % of HR span OR a gap > 20 min) switches to HR-vouched bridging; fully HR-only nights go through `hrOnlySessions` and are flagged `hrOnly` / `sleepHrOnly`. |
| High-rate IMU | file-backed `.imus` (not SQLite); `rawImuSample` dropped in v41 | 100 Hz 6-axis, opt-in capture only (cmd 81/106). | Research instrumentation; `ImuFeatureExtractor` (cadence, jerk, gyro energy) exists but nothing scores from it. |
| Step / motion counter | `stepSample(counter, activityClass)` (v10, v19) | R18 u16 cumulative hardware pedometer byte 57 + activity class byte 63 (0 still / 1 walk / 2 run). | Present. Counter ≠ steps; per-user `stepTicksPerStep` calibration. |
| Skin temperature | `skinTempSample(raw, aux1Raw, aux2Raw)` | R18 byte 73, **centidegrees** (`raw/100 °C`, accept 5–45 °C) + two aux thermal channels /10 °C. | Present on supported layouts; README: "not available consistently across 5/MG firmware". Wear-gated nightly mean → `dailyMetric.skinTempC` (v40) and deviation `skinTempDevC` (v7). |
| Respiration waveform | `respSample(raw)` | **WHOOP 4.0 only** (type-47 v24 resp ADC). On 5.0 there is no raw respiration channel; `vendorResp` rows are Oura-only. | **Absent on 5.0.** Respiratory rate is derived from R-R via RSA (`SleepStager.respRateFromRR`). |
| SpO₂ | `spo2Sample(red, ir)` (4.0 raw ADC); R18 byte 82 "candidate" on 5.0 | 5.0: time-multiplexed optical in R20/R26; byte 82 is a sleep-adjacent raw byte with sentinels 0x80/0xA0. | **Not recoverable** (README). `spo2Pct` is nil for WHOOP; `spo2_candidate_82` is diagnostic-only, never scored; `v36` strips the `spo2` capability token. |
| Band sleep state | `sleepStateSample(rawByte)` (v21) | R18 byte 81 bits 4–5: 0 WAKE / 1 STILL / 2 SLEEP / 3 UP. | Present; used as an independent sleep/wake reference in SleepBench and a wake veto in staging. Not a hypnogram. |
| ECG | `ecgWaveformSample` (v48, MG only) | Flash-banked R16 records. | Stored, **nothing reads it** by design (#752). |
| Battery, events | `battery`, `event` | — | Not metrics-relevant. |

Derived/cached per-day row: `dailyMetric` (`totalSleepMin, efficiency, deepMin, remMin, lightMin,
disturbances, restingHr, avgHrv (RMSSD), avgSdnn (5-min SDNN index, v37), recovery, strain,
exerciseCount, spo2Pct, skinTempDevC, skinTempC, respRateBpm, steps, activeKcalEst, sleepHrOnly`);
per-session `sleepSession(startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON, userEdited,
startTsAdjusted, stagingSparse)`; long-format `metricSeries(key, day, value)`.

---

## 2. Per-metric inventory

Legend for the "5.0 inputs" column: ✅ available, ⚠️ sparse/conditional, ❌ absent.

### 2.1 HRV (RMSSD, SDNN index, pNN50, frequency domain)

| | |
|---|---|
| Swift | `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift` (`rmssdRaw`, `sdnnRaw`, `rangeFilter`, `rejectEctopic`, `cleanRR`, `cleanRRGapAware`, `rmssdGapAware`, `pnn50GapAware`, `analyze`, `sdnnIndex`, `rollingRmssd`, coverage/over-count gates `classifyCoverage`, `rrCoverage`, `collapseOverCount`, `beatAccurateFraction`); `HRVFreqDomain.swift` (Lomb–Scargle LF/HF, opt-in display only); `StressIndex.swift` (Baevsky SI, display only); `SleepStager.sessionHrvWindows` / `sessionAvgHRV`; `AnalyticsEngine.analyzeDay` (`avgHRVDaily`, `avgSDNNDaily`). |
| Kotlin | `android/app/src/main/java/com/noop/analytics/HrvAnalyzer.kt`, `HrvFreqDomain.kt`, `StressIndex.kt`, `SleepStager.kt`, `AnalyticsEngine.kt`. Header says "faithful port, verified on macOS". |
| Method | Task Force (1996) RMSSD / SDNN (ddof=1) / pNN50. Cleaning: range filter `[300, 2000]` ms → Malik-style ectopic rejection (`ectopicThreshold 0.20` vs local median over a 5-beat window, `ectopicWindowRadius 2`) → `minBeats 20`. Gap-aware successive differences skip any pair straddling a dropped beat (#204/#208). Spot readings refuse when > `defaultSpotMaxRejectedFraction 0.35` of beats were dropped (#585). |
| Nightly value | `sessionHrvWindows`: 5-min **tumbling** windows over `[start, end]` of each sleep session, each cleaned gap-aware, window RMSSD only if `nClean ≥ minBeats (20)`; `sessionAvgHRV` = plain mean of window RMSSDs; daily `avgHrv` = in-bed-duration-weighted mean over "physiology sessions" (motion-backed preferred; HR-only nights only if nothing else). Optional **deep-window** mode (`deepHrvWindow`, user pref `UnitPrefs.hrvWindowKey`, default OFF) pools only windows whose centre is in a `deep` stage. `avgSdnn` = Task Force **SDNN index** (mean of per-5-min SDNN) — chosen to be window-comparable with Apple Watch short-window SDNN. |
| Over-count gates | `classifyCoverage(coverage, collapsed)` with plausible band `[0.90, 1.10]` of `sum(rr)/wall-clock`; a main night refused by the gate is not replaced by naps (#1118). `beatAccurateFraction` (|gap − rr| ≤ 0.5 s on ≥ 50 % of beats) gates SDNN and RSA on banked streams. |
| Papers cited in code | Task Force ESC/NASPE 1996; Malik et al. 1989; Lipponen & Tarvainen 2019 (named as the method NOT implemented); Baek et al. 2015 (≈30-beat RMSSD floor, in `docs/RR-OPTIMIZATION.md`); Plews 2013, Buchheit 2014, Bellenger 2016; Lomb 1976, Scargle 1982, Laguna 1998, Clifford & Tarassenko 2005; Baevsky. |
| 5.0 inputs | ⚠️ R-R: ≤ 4 words/s in R18, filler beats, coverage often < 1. README calls overnight HRV "incomplete unless sufficient R-R". |
| Tests (Swift) | `HRVAnalyzerTests`, `HRVCleaningPreservationTests`, `HrvGapAwareTests`, `HrvOverCountGateTests`, `HrvCollapseOverCountTests`, `HrvWindowSweepOracleTests`, `HRVFreqDomainTests`, `HrvDiagnosticRowsTests`, `AnalyticsEngineRefusedMainNightHrvTests`, `HRVAnalyzerSampleOrdTests`, `HRVAnalyzerDuplicatePairTests`. |
| Tests (Kotlin) | `HrvAnalyzerGateTest`, `HrvAnalyzerRollingTest`, `HrvAnalyzerSdnnIndexTest`, `HrvArtifactDensityTest`, `HrvCleaningPreservationTest`, `HrvCollapseOverCountTest`, `HrvGoldAgreementTest`*, `HrvOpticalRobustnessTest`*, `HrvFreqAgreementTest`*, `RrVersionRundownTest`, `RealDataRundownTest`* (*fixture-backed, skip in CI). |
| Known issues / TODOs | (a) Malik 20 % rule is a stand-in for Lipponen–Tarvainen 2019 (file header says so). (b) `rollingRmssd` emits from 8 beats (`minBeatsPerWindow 8`) — below the ~30-beat reliability floor noted in `docs/RR-OPTIMIZATION.md`; nightly windows use 20. (c) Plain mean over windows (no quality weighting); `docs/RR-OPTIMIZATION.md` reports a second wearer's lowest-variance-window median moved LOO recovery correlation from −0.49 to +0.67 (n=20) — unshipped candidate. (d) `docs/RR-OPTIMIZATION.md` finding 4: **do not** default to a deep-window HRV to chase WHOOP's absolute value (stage-based selection refuted; quality-based is live). (e) ln(RMSSD) tried for recovery, parked (narrow range, n=8). (f) No handling of missed-beat insertion. |

### 2.2 Resting heart rate

| | |
|---|---|
| Swift | `SleepStager.sessionRestingHR` (lowest 5-min **non-overlapping bin mean**, bin qualifies only if `≥ rhrMinBinSamples 5` samples and mean `≥ rhrMinPlausibleBpm 25`; fallback lowest ungated bin, then all-sample mean); `AnalyticsEngine.analyzeDay`: daily RHR = that floor from the **primary (longest) session** (#2522, nap protection #2358), device-provided value wins (#804); `PrimarySessionRestingHR.swift` = shadow "primary-session MEAN" (`rhr_primary_session`, instrumentation only, #1169). |
| Kotlin | `SleepStager.kt`, `PrimarySessionRestingHR.kt`, `AnalyticsEngine.kt` (`primarySessionRestingHR`). |
| Baseline | `Baselines.swift` `resting_hr` cfg: bounds 30–120, floor spread 2.0 bpm, center half-life 14 n, spread half-life 21 n, Winsor ±3 spread, hard outlier 5×. `ReadinessEngine` uses a plain 30-night trailing mean/SD (`baselineWindow 30`, `minBaseline 7`). |
| Papers cited | Lamberts 2004 (RHR drift as overtraining/illness signal, in `ReadinessEngine`). #1169 experiment: n=1, 5 nights, Polar H10 + official WHOOP RHR reference; primary-session mean MAE 6.0→2.0 (dev), 7.5→0.8 (holdout) vs the floor. |
| 5.0 inputs | ✅ HR (with PPG filler). |
| Tests | `ManualWorkoutRescoreRestingHrTests`, `PrimarySessionRestingHR*` (Swift: via AnalyticsEngine tests), Kotlin `PrimarySessionRestingHRTest`; `rhr bins` diagnostic line. |
| Known issues | Two definitions coexist (5-min floor shipped; session mean shadow). #2284 proposes changing the session definition. The shipped floor is the **minimum** statistic, which the #1169 n=1 experiment found under-reads vs ECG mean; literature on wearables' "lowest 5-min average" vs "sleep mean" needs settling (Phase 1 topic 02). |

### 2.3 Sleep detection and staging

| | |
|---|---|
| Swift | `SleepStager.swift` (V1: detection `detectSleep` + percentile-band stager; constants `gravityStillThresholdG 0.01`, `stillWindowMin 15`, `stillFraction 0.70`, `maxGapMin 20`, `mergeMin 15`, `minSleepMin 60`, `hrSleepBaselineMult 1.05`, Cole–Kripke weights `[106,54,58,76,230,74,67]`, `ckScale 0.001`; sparse-motion bridging `sparseGravitySpanFrac 0.5`, `sparseBridgeGapMin 90`; quiescent-HR widening ×1.30; HR-only path `hrOnlySessions` with `hrOnlyAnchorPercentile 0.10`, `hrOnlyBandMult 1.05`, `hrOnlyEpochS 60`); `SleepStagerV2.swift` (**default** stager: per-night z-scored HR / HR-var / 11-min HR flatness / jerk / RSA-regularity emissions + log-priors light 0.50 / deep 0.15 / rem 0.22 / awake 0.10 + sleep-cycle prior + sticky Viterbi; `deepGateThresh 0.25`, `respWeight 0.6`, motion-quiescent wake clamp); `WakeMotionRefinement.swift` (post-pass, default OFF); `SleepStageTotals`, `SleepStageVocabulary.isWake`, `SleepWindowReclip`, `SleepDebt`, `AnalyticsEngine.Rest` composite (`wDuration 0.50, wEfficiency 0.20, wRestorative 0.20, wConsistency 0.10`, `restorativeTarget 0.50`, `deepShareTarget 0.13`, `deepFloorFactor 0.5`, personalised need = 75th percentile of trailing nights floored at the age target, `minNeedNights 7`, cap 9.5 h). |
| Kotlin | `SleepStager.kt`, `SleepStagerV2.kt`, `WakeMotionRefinement.kt`, `SleepStageTotals.kt`, `SleepDebt.kt`, `AnalyticsEngine.kt`. `docs/ANALYTICS.md` notes the motion-corroborated-wake work was Swift-first with the Kotlin twin "a deliberate follow-up" — **verify parity before touching**. |
| Papers cited | Cole–Kripke 1992 via te Lindert & Van Someren 2013; Walch et al. 2019 (`sleep-accel`, PhysioNet); AASM roll-up conventions. `Tools/SleepPSG` README: shipped V2 on 31 sleep-accel subjects / 26,773 epochs → 4-class κ ≈ 0.37 pooled (0.357 mean per-subject), deep bias +1.3 pp pooled, REM over-called (~27 % vs ~21 % truth), wake sensitivity ~31 %. 44-subject LOSO (AAUWSS + sleep-accel) picked V2 over V1 (κ 0.35 vs 0.03). **The R-R stream is empty in sleep-accel, so the RSA term is untested against PSG.** |
| 5.0 inputs | ⚠️ gravity sparse → HR-vouched bridging / HR-only sessions; ✅ HR; ⚠️ R-R (RSA term); ✅ band sleep state (reference only). README: sleep duration "experimental, HR fallback"; stages "approximate and not reliable". |
| Tests | `SleepStagerTests`, `SleepStagerV2*`, `MotionCorroboratedWakeTests`, `Live5NoGravityRestChainTests`, `AnalyticsEngineHrOnlyDayTests`, `HrOnlyPhysiologyIsolationTests`, `SleepStageTotals*`, `BridgedNightGroupsTests`, `WakeMotionRefinement*`, SleepPSG `--section port` equivalence (48 random + 7 degenerate nights). Kotlin twins for most. |
| Known issues | (a) Light/deep separation is the weakest link (documented). (b) REM residual vs the previous harness unresolved. (c) No 4-class PSG reference that includes R-R, so the RSA term's value is unmeasured. (d) HR-only detection uses a fixed 10th-percentile anchor ×1.05 band — `docs/VALIDATION_PROTOCOL.md` R5 shows a single-wearer threshold drifted > 10 bpm in 3 weeks. (e) V1 detection still gates V2 staging (V2 restages windows V1 found). |

### 2.4 Respiratory rate

| | |
|---|---|
| Swift | `SleepStager.respRateFromRR` (RSA: in-bed range-filtered R-R → beat-accuracy gate → cumulative-sum beat times → 5-min windows, detrend by centred mean (`rsaDetrendWindowS`), peak-pick intervals in the 6–24 bpm band, rate = 60/median interval per window, median across windows; splice skip `rsaGapToleranceS` #977); V1 feature `respRateAndRRV` (peak detector on the raw resp ADC, **4.0 only**); `AnalyticsEngine.vendorRespRateBpm` (Oura rate rows, `vendorRespMinSpanS 3600`); plausibility clamp `SleepStager.respPlausibleRangeBpm` (8–25). Daily `respRateBpm` = median/mean over matched sessions (see `AnalyticsEngine` ~L893). |
| Kotlin | `SleepStager.kt` twin; `RespRateGapAwareTests` twin. |
| Baseline | `Baselines` `resp` cfg: 4–40, floor 0.5 bpm. `ReadinessEngine` resp z: WATCH 1.5 / BAD 2.0 (wider than HRV/RHR). |
| Papers cited | None named in `respRateFromRR` beyond RSA as a concept; `HRVFreqDomain` cites Task Force HF band 0.15–0.40 Hz. |
| 5.0 inputs | ❌ raw respiration waveform; ⚠️ R-R (≤ 4/s, fill beats). So on 5.0 respiration = RSA from sparse R-R only. |
| Tests | `RespRateGapAwareTests`, `OuraRespScoringExclusionTests`, SleepStager resp tests; Kotlin twins. |
| Known issues | No validated accuracy figure for the RSA estimator anywhere in the tree; no PPG-based (amplitude/baseline modulation) alternative since the v26 waveform is only used for HR. The 13.33 bpm "floor" artefact on banked streams is documented (#882/#883). |

### 2.5 Strain / training load / energy expenditure

| | |
|---|---|
| Swift | `StrainScorer.swift` (Karvonen %HRR; **Edwards-STYLE** 5 zones at 50/60/70/80/90 **%HRR** × minutes (default) or Banister exponential with sex-paired `BanisterCoefficients` (0.64·e^1.92x men / 0.86·e^1.67x women); `Effort = 100·ln(TRIMP+1)/ln(D)`, `D = 7201` for Edwards, method-specific for Banister; gates `minReadings 600` dense or `minSparseReadings 20` + `minSpanSeconds 600`; `estimateHRmax` = max(observed 99.5th pct if ≥ 600 samples, Tanaka 208 − 0.7·age); `fitStrainDenominator`); steps/active-kcal floor; `TrainingLoadEngine.swift` (EWMA CTL 42 d / ATL 7 d / TSB, descriptive only); `ReadinessEngine` ACWR (7/28 d rolling means, `minChronic 14`, sweet spot 0.8–1.3, > 1.5 bad) and Foster monotony (mean/SD over 7 d, ≥ 2.0 flag); `WorkoutDetector.swift` + `Calories` (Keytel 2005 active kcal, fitness-adjusted variant when VO₂max known via Uth; revised Harris–Benedict BMR; `activeHRRFraction 0.30` bout / `dayActiveHRRFraction 0.50` day); `AutoWorkoutDetector`, `HRZones` (%HRmax display zones), `HeartRateRecovery`, `FitnessAgeEngine` (Nes 2011 HUNT), `VitalityEngine`. |
| Kotlin | `StrainScorer.kt`, `TrainingLoadEngine.kt`, `ReadinessEngine.kt`, `WorkoutDetector.kt`, `HrZones.kt`, `FitnessAgeEngine.kt`, `VitalityEngine.kt`; parity tests `BanisterParityOracleTest`, `EffortScoreFunnelTest`, `DayCaloriesTest`. |
| Papers cited | Karvonen 1957; Edwards 1993; Banister 1991 / Morton, Fitz-Clarke & Banister 1990; Tanaka 2001; Gabbett 2016; Foster 1998; Keytel 2005; Harris–Benedict (revised); Uth 2004 (VO₂max from HRmax/HRrest); Nes 2011; Kurtze 2008. |
| 5.0 inputs | ✅ HR (dense when offloaded; live standard HR ~30 s); ✅ step counter. |
| Tests | `StrainScorerTests`, `EffortScoreFunnelTests`, `EffortDayCalibrationTests`, `TrainingLoadEngine*`, `ReadinessEngineTests`, `WorkoutDetectorTests`, `DayCaloriesTests`, `HRZonesTests`, `HeartRateRecoveryTests`, `FitnessAgeEngineTests`; Kotlin twins. |
| Known issues | (a) Edwards zones cut on %HRR, not %HRmax (documented as deliberate, #2835). (b) `D = 7201` is a ceiling-derived constant, not a fitted or literature value; `fitStrainDenominator` exists but no published fit. (c) ACWR uses rolling means (the form criticised in later literature — topic 05 to verify). (d) Keytel equation assumes exercise-level HR; the day path uses a 0.50 HRR gate as a guard. (e) HRmax "observed 99.5th percentile" can be inflated by PPG artefacts. |

### 2.6 Recovery ("Charge") / readiness composites

| | |
|---|---|
| Swift | `RecoveryScorer.swift` (z-score + logistic: `wHRV 0.55, wRHR 0.20, wSleep 0.15, wResp 0.05, wSkinTemp 0.05` (+ optional `wRecoveryIndex 0.05`, `wActivityBalance 0.05`); robust z = (v − μ)/(1.253·spread); sleep term `(sleepPerf − 0.85)/0.12`; `logisticK 1.6`, `logisticZ0 −0.20` → z=0 ≈ 58 %; bands < 34 red / < 67 yellow; cold start nil below `Baselines.minNightsSeed 4`; parasympathetic-saturation guard **detected, not applied**); `Baselines.swift` (Winsorized EWMA, half-lives 14/21 nights, `minNightsSeed 4`, `minNightsTrust 14`, `staleDays 14`; `rollingMeanSD` alt path); `ChargeBaselines.swift` (21-day window, imports only seed, #2525); `HRVReadiness.swift` (opt-in Plews/Altini SWC: ln RMSSD, 7-night rolling vs 60-night (fallback 30) band ±0.5 SD, `minNights 14`, CV-trend overreaching watch); `ReadinessEngine.swift` (HRV z in log domain, RHR z, resp z, ACWR, monotony → primed/balanced/strained/rundown); `ScoreConfidence.swift`; `IllnessSignalEngine.swift` (≥ 2 of RHR↑/HRV↓/temp↑/resp↑ at |z| ≥ 2, confounder dampening 0.45) and `IllnessDistance.swift` (Mahalanobis, flagged alternative); `RecoveryForecast.swift`; `WatchRecovery.swift`. |
| Kotlin | `RecoveryScorer.kt` (constants verified identical incl. `satEnterZ 0.5 / satFullZ 1.5 / satMaxDampFraction 0.5`), `Baselines.kt`, `ChargeBaselines.kt`, `HRVReadiness.kt`, `ReadinessEngine.kt`, `IllnessSignalEngine.kt`, `IllnessDistance.kt`, `V5HealthSignals.kt` (Android-only plumbing: 30-night rolling z, min 14). |
| Papers cited | Plews 2013; Buchheit 2014; Bellenger 2016; Lamberts 2004; Gabbett 2016; Foster 1998; WHOOP published population mean 58 % (anchor only). `docs/RR-OPTIMIZATION.md`: on n=8 nights of one wearer, WHOOP recovery correlated most with sleep performance (r 0.80) and HRV/RHR ratio (0.78); an unfitted HRV/RHR + sleep composite raised r vs WHOOP from 0.817 to 0.849; `logisticK 1.6` found too steep (LOO MAE ~20 → ~9 with a gentler slope) — **all unshipped, n too small**. |
| 5.0 inputs | ⚠️ HRV (dominant driver, sparse R-R), ✅ RHR, ✅ sleep (approx.), ⚠️ resp (RSA), ⚠️ skin temp. |
| Tests | `RecoveryScorerTests`, `RecoverySaturationGuardTests`, `BaselinesTests`, `BaselinesRecentHrvCoverageTests`, `ChargeBaselinesTests`, `HRVReadinessTests`, `ReadinessEngineTests`, `IllnessSignalEngineTests`, `IllnessDistanceTests`, `ScoreConfidence*`; Kotlin `RecoveryAgreementTest` (numpy oracle), `HrvBaselineRecalibrationTest`, `ChargeEffortRestScoringTest`. |
| Known issues | (a) Weights are hand-set, not fitted; sleep weight likely too low vs the n=8 evidence. (b) Logistic slope saturates. (c) Three different baseline machineries coexist (EWMA `Baselines`, 30-night mean/SD in `ReadinessEngine`, 30-night z in `V5HealthSignals.kt`) — a "two readouts of one fact" risk the repo rules call out. (d) HRV z in `RecoveryScorer` is in raw ms; `ReadinessEngine` and `HRVReadiness` use ln RMSSD. (e) Cold start after 4 nights is aggressive vs the 14-night SWC literature. |

### 2.7 SpO₂

| | |
|---|---|
| Swift | `AnalyticsEngine.nightlySpo2RawMeans` (4.0 raw red/IR means, never a %), `spo2_candidate_82` diagnostic, `Spo2ReTrace.swift` (Test-Centre hex dump), `RecoveryScorer` folds SpO₂ only when imported. `Tools/linux-capture/validate_spo2_candidate.py`. |
| Kotlin | `Spo2ReTrace.kt`, `AnalyticsEngine.kt` twin. |
| Method | None. The project position (README, `docs/WHOOP5_DEEP_DATA.md`, migration v36) is that calibrated SpO₂ is **not recoverable offline** from time-multiplexed PPG without WHOOP's calibration curve, and the withdrawn PPG→HR #194 is the cautionary precedent. |
| 5.0 inputs | ❌ no simultaneous red/IR pair with calibration; R20/R26 optical blocks carry producer-identified but **wavelength-unlabelled** channels. |
| Tests | `Spo2ReTrace*`, `DaySpo2*` (raw means). |
| Known issues | Topic 07 must answer feasibility honestly; the expected answer is "no" unless the literature shows ratio-of-ratios survives channel multiplexing + unknown wavelength identity. |

### 2.8 Skin temperature

| | |
|---|---|
| Swift | `AnalyticsEngine.wornNightlySkinTempC` / `skinTempFunnel` (in-session samples, concurrent worn HR, plausible worn range ~28–40 °C, `minSkinTempSamples`; family-aware raw→°C via `WhoopProtocol.skinTempCelsius(raw:family:)` — 5.0 = raw/100); deviation `skinTempDevC` = nightly mean − personal EWMA baseline (`Baselines` `skin_temp` cfg 20–42 °C, floor 0.3 °C); absolute `skinTempC` stored since v40; `SkinTempBackfill.swift`; `SkinTempDisplay.swift` / `VitalBands.isAbsoluteSkinTemp` (bimodal column: imports absolute, live deviation); consumers: `RecoveryScorer` (symmetric penalty, scale 1 °C), `IllnessSignalEngine`, `CyclePhaseEngine` (temp 0.6 / RHR 0.2 / HRV 0.2 fused luteal index), `CircadianEngine` (nightly minimum corroborates cosinor phase). |
| Kotlin | `AnalyticsEngine.kt`, `SkinTempDisplay.kt`, `CyclePhaseEngine.kt`, `CircadianEngine.kt`, `V5HealthSignals.kt`. |
| Papers cited | PMC11294004 (wrist temp cycle tracking) in `CyclePhaseEngine`; Stanford/Snyder RHR-elevation line in `IllnessSignalEngine`. |
| 5.0 inputs | ⚠️ R18 byte 73 present on supported layouts, "not consistent across firmware". |
| Tests | `SkinTemp*`, `CyclePhaseEngineTests`, `CircadianEngineTests`, `VitalBands*`; Kotlin twins. |
| Known issues | (a) Nightly **mean** of worn samples (no distal-vs-ambient handling, no time-of-night weighting). (b) HealthKit: `.appleSleepingWristTemperature` is Apple-Watch-reserved; writing it crashes the app (#1366) → skin temp is **not exported** to Apple Health. (c) Deviation sign/scale conventions differ between the two consumers (`RecoveryScorer` symmetric, `Illness` one-sided). |

### 2.9 Steps and activity

| | |
|---|---|
| Swift | `StepsCounter.swift` (wrap-aware delta of R18 counter@57; count only walk/run-classed increments; `maxStepDelta 512`, `maxTicksPerSecond 4`), `SleepAwareStepCounter.swift` (gait-bout gating inside sleep), `StepsEstimateEngine.swift` (4.0 motion-volume × per-user `k`, calibrated vs phone steps, `minCalibrationDays 3`), `PhysiologicalSteps.swift` (day-cycle ownership), `StepsMotionCache`, `ImuFeatureExtractor.swift` (100 Hz cadence autocorrelation, research), `WorkoutTypeClassifier`, `SedentaryDetector`, `ActivityHeatmap`. `UserProfile.stepTicksPerStep` is the per-user calibration. |
| Kotlin | `StepsCounter.kt`, `SleepAwareStepCounter.kt`, `StepsEstimateEngine.kt`, `PhysiologicalSteps.kt`, `PhysiologicalStepCycleEngine.kt`, `ImuFeatureExtractor.kt`. |
| Method | 5.0: the strap's own hardware pedometer counter, calibrated by a user ratio; 4.0: calibrated motion volume. No on-device step detection from raw acceleration in the shipped path (1 Hz gravity cannot resolve cadence; 100 Hz IMU is capture-only). |
| 5.0 inputs | ✅ counter + activity class; ❌ continuous high-rate accel. |
| Tests | `StepsCounter*`, `SleepAwareStepCounter*`, `StepsEstimateEngine*`, `ImuFeatureExtractorTests` (recovers multiple injected cadences). |
| Known issues | Counter semantics (rollover, reset, relation to official steps) unresolved per `docs/PROTOCOL_SENSORS.md`; "ticks per step" is user-tuned; `docs/VALIDATION_PROTOCOL.md` R4 warns a remembered "2–6× phone steps" band held on only 57 % of days. |

### 2.10 Apple Health / Health Connect export

| | |
|---|---|
| iOS | `StrandiOS/Health/HealthKitBridge.swift` (1,952 lines). **Writes:** `.restingHeartRate` (count/min), `.heartRateVariabilitySDNN` (ms, from `avgSdnn` = 5-min SDNN index; RMSSD never written, #2264), `.oxygenSaturation` (imports only), `.respiratoryRate`, all stamped at that day's wake time (noon fallback); `.sleepAnalysis` with `inBed` span + `awake / asleepCore (light) / asleepDeep / asleepREM / asleepUnspecified` segments over bridged night groups; continuous 1-minute `.heartRate`; `HKWorkout` with `.activeEnergyBurned`, `.distanceWalkingRunning` / `.distanceCycling`. Dedup: `HKMetadataKeyExternalUUID = noop:<kind>:<identity>` (no device-id segment since #1503), delete-then-write scoped to `HKSource.default()`; open nights held back (`HealthWriteback.nightIsStillOpen`). **Not written:** skin temperature (`.appleSleepingWristTemperature` is share-denied, `writeDenied`), steps, VO₂max (read only), HRV as RMSSD. **Reads:** HR, RHR, SDNN, SpO₂, resp, body temp, steps (daily + hourly `appleStepHour`), active/basal energy, VO₂max, body comp, water, caffeine. |
| iOS sideload path | `Strand/Data/ShortcutHealthExport.swift` (#155): `Documents/noop_sync.txt`, one line per 15-min window `HR,HRV,Steps,yyyy-MM-dd HH:mm` (local time, no header); HRV here is **RMSSD** over the window's R-R; truncating, watermark-based; the user's Shortcut does the HealthKit write with no dedup. |
| Android | `android/app/src/main/java/com/noop/ingest/HealthConnectWriter.kt`: `RestingHeartRateRecord`, `HeartRateVariabilityRmssdRecord` (**RMSSD** — Health Connect has an RMSSD type, HealthKit does not), `OxygenSaturationRecord`, `RespiratoryRateRecord`, `HeartRateRecord`, `SleepSessionRecord` (with stages), `Vo2MaxRecord`, `ExerciseSessionRecord` + `DistanceRecord`. |
| Tests | `HealthWriteback*` (pure key/plan helpers), `ShortcutHealthExportTests`; Kotlin `HealthConnectWriterTest`. |
| Known issues | (a) The Shortcut path labels RMSSD as "HRV" and the user's Shortcut decides which HK type it lands in — a likely SDNN/RMSSD mislabel at the Shortcut end (topic 10 to check against Apple docs). (b) Nightly vitals are single samples stamped at wake; Apple's own RHR/SDNN semantics (and whether `HKDevice` / source metadata should be set) need checking. (c) Skin temperature has no exportable type on iOS. (d) iOS writes SDNN index, Android writes RMSSD — a cross-platform *semantic* difference, legitimate but worth stating in docs. |

### 2.11 Supporting engines (not primary targets, listed for completeness)

`CorrelationEngine` (Pearson r, OLS, normal-approx p), `BehaviorInsights` (Welch t, Cohen's d, n ≥ 5
gate), `ComparisonEngine`, `DoseResponseEngine`, `EffectRanker`, `CoachSuggestions`, `WeeklyDigest`,
`StreakCalculator`, `BatteryEstimator`, `HydrationGoal`, `CaffeineDecay` (Kotlin), `BreathPacer` /
`BreathProtocol`, `ResonanceEngine`, `DaytimeStress` / `StressOnsetDetector`, `LiveSessionEngine`,
`LiftMetrics`, `AdaptiveExpenditureEngine` (TDEE by energy balance, 7,700 kcal/kg). These are
statistics over daily rows, not sensor-derived metrics, and are out of the brief's scope unless a topic
needs them.

---

## 3. Cross-cutting observations for the research phase

1. **Window definitions are entangled.** HRV (`sessionHrvWindows`), RHR (`sessionRestingHR`), RSA
   respiration (`respRateFromRR`) and the SDNN index all run over the **detected sleep session bounds**.
   On a 5.0 with sparse gravity those bounds come from HR-only detection, so any sleep-detection
   improvement moves every overnight vital. Topics 01/02/03/04 must state which window they assume.
2. **Three baseline machineries** (EWMA `Baselines`, 30-night mean/SD in `ReadinessEngine`, 30-night z in
   `V5HealthSignals.kt`) answer the same "how unusual is tonight" question with different windows and
   different domains (ms vs ln ms). Topic 06 should recommend one.
3. **Parity is enforced by oracle tests** (`Tools/parity_*`, `BanisterParityOracleTest`,
   `RecoveryAgreementTest`). Any algorithm change needs a Swift-stdout-as-Kotlin-literal oracle per
   `AGENTS.md`.
4. **Validation infrastructure already exists** for sleep (`Tools/SleepPSG` over PhysioNet
   `sleep-accel`; `Tools/SleepBench` over a wearer DB) and partially for HRV (Kotlin fixture tests over
   AAUWSS PSG-ECG and GalaxyPPG Polar-H10 windows, fixtures not committed). There is **no** harness for
   RHR, respiration, strain/energy, skin temperature or steps.
5. **Prior negative results to respect** (`docs/RR-OPTIMIZATION.md`): stage-based HRV window selection
   is dead; ln RMSSD for the Charge z did not help at n=8; recovery re-weighting is blocked on sample
   size, not on ideas.
6. **What the 5.0 cannot give today**: calibrated SpO₂, a raw respiration waveform, dense motion. The
   research should design for HR-dense / R-R-sparse / motion-sparse nights as the *normal* case.

---

## 4. Deliverable checklist (Phase 0)

- [x] Branch `research/metrics-literature` created from clean `main` (2a1de760).
- [x] `RESEARCH_BRIEF.md` placed at the repo root (untracked; not to be committed upstream).
- [x] `research-data/` added to `.gitignore`.
- [x] Baseline recorded: Swift package compiles; XCTest unavailable locally (no Xcode); Android SDK absent.
- [x] This inventory.

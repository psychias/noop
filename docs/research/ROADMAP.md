# ROADMAP — literature-grounded metrics for NOOP on a WHOOP 5.0

Phase 2 synthesis of `docs/research/00-inventory.md` and the ten topic files `01`–`10`, written
2026-11-11 on branch `research/metrics-literature` (tree `2a1de760`). Nothing below is implemented.
Every numbered item cites the research file it comes from; the file carries the verified sources,
the pseudocode and the pre-registration notes. Impact ratings are the topic authors' INFERRED
ratings for the owner's case (WHOOP 5.0, bonded only to NOOP, HR-dense / R-R-sparse / motion-sparse
nights, metrics read in Apple Health). Nothing here is medical advice; wording in any shipped copy
stays within `docs/SCOPE.md`.

**Status: STOPPED, awaiting the owner's approval and prioritisation before any Phase 3 code.**

---

## 1. Executive summary

The research changed the picture in one important way: **NOOP's formulas are mostly fine; what the
literature says NOOP lacks is quality gating, confidence, and one consistent baseline.** On a 5.0 the
scarce input is R-R, and today a night built from a few minutes of beats enters the HRV baseline, the
respiratory-rate baseline, Charge, Readiness and the illness heads-up with the same weight as a full
night, and the respiratory-rate estimator emits a plausible number (13.3 breaths/min) from pure noise.
Three different "how unusual is tonight" machineries answer the same question with different windows
and domains, so two screens can disagree about one night. These are the biggest accuracy wins, and
they are small, additive, parity-testable changes.

The biggest wins, in order of evidence per effort:

1. **Quality-gated overnight vitals** (01, 04, 02, 08). Count only contiguous, beat-accurate R-R pairs;
   require ≥ 30 pairs per 5-min window and a minimum of usable windows per night; emit a tier
   (refuse / limited / normal) beside every nightly HRV and respiratory rate; refuse respiration when the
   tachogram carries no respiratory rhythm; use coverage fractions rather than sample counts for RHR
   and skin temperature. Limited nights are shown but kept out of baselines and gates.
2. **One baseline spine** (06, with 01, 02, 08 agreeing). Keep the Winsorized-EWMA `Baselines`, fold
   HRV in the ln domain everywhere, add a 7-night ln trend, raise cold start from 4 to 7 valid nights,
   retire the 30-night re-fold in `ReadinessEngine` and the Android-only `V5HealthSignals` z. Then let
   Charge degrade honestly: RHR baseline required, HRV preferred, respiration out of the score.
3. **Apple Health correctness** (10). Adopt Apple's atomic upsert (`HKMetadataKeySyncIdentifier` +
   `SyncVersion`) instead of delete-then-save, attach an `HKDevice`, add the sleep time zone, fix the
   Shortcut file so it does not label RMSSD as the SDNN type, and probe the new iOS 27 RMSSD type on a
   device. On Android, add the mandatory device metadata before the SDK bump breaks the writer, move
   daily records from noon to wake time, and export skin temperature (Health Connect has the exact
   type; HealthKit does not allow it).
4. **Sleep on sparse motion** (03). Feed the RSA term only beat-accurate, non-filler R-R (the 500 ms
   fillers make the tachogram artificially regular and vote "deep" exactly when the strap saw fewest
   beats); add onset/offset refinement to HR-only detection; use posture angle rather than jerk when
   gravity is sparse. A fitted-and-pinned linear emission is the one known move from the consumer
   band (κ ≈ 0.37) toward the hand-feature band (κ 0.42–0.52), but it needs the DREAMT dataset first.
5. **Strain honesty** (05). Remove "injury risk" / "illness risk" wording (the ACWR evidence base does not
   support it and the repo rules forbid it), compute ACWR/monotony/CTL-ATL on linear TRIMP instead of
   the log-compressed Effort, stop the silent `220 − age` fallback, and treat the Effort scale anchor
   as a documented calibration to be fitted on the owner's WHOOP export behind a flag.

What the literature says **not** to do: derive SpO₂ (infeasible, 07); count steps from the 1 Hz
gravity vector (Nyquist, 09); stage-based HRV window selection (already refuted, 01); interpolate
missing beats on the 5.0 stream (01); keep a single-night raw-ms HRV z as the dominant Charge driver
(06); write wrist temperature to HealthKit (10).

The gating prerequisite for all of it is **validation infrastructure** (§3): four public datasets
need downloading into the git-ignored `research-data/`, two need a PhysioNet data-use agreement,
and five of the ten topics have no harness at all today. Per `docs/VALIDATION_PROTOCOL.md`, a scoring
change with no held-out number may ship behind a flag but may not be called an improvement.

Local blocker: this Mac has no Xcode (Command Line Tools only), so `swift test` cannot run; the
Android SDK is also absent (inventory §0). Phase 3 needs at least Xcode installed.

---

## 2. Ranked improvement list

Columns: **Impact** on the owner's numbers (H/M/L) · **Effort** S/M/L · **Risk** · **Needs** (dependencies)
· **5.0 inputs** · **Scope** (Swift / Kotlin / iOS app / Android app) · **Source**. "Flag" means ships
behind a default-off `PuffinExperiment` flag until the held-out number exists. Every analytics item
carries a Swift-stdout-as-Kotlin-literal parity oracle (`AGENTS.md`). Items marked **PR-sized** are one
upstream PR each.

### Tier 0 — prerequisites

| # | Item | Impact | Effort | Risk | Needs | Scope | Source |
|---|---|---|---|---|---|---|---|
| 0.1 | Install Xcode (select it) so `swift test` and `StrandTests` run locally; optionally the Android SDK. | — | S (owner) | none | — | toolchain | 00 §0 |
| 0.2 | Dataset download scripts + `research-data/` layout (§3.1). | — | S | none | — | `Tools/` scripts | all |
| 0.3 | `Tools/MetricsBench` harness package (§3.2): WFDB reader, WHOOP-sparsity simulator, subcommands per metric. | — | M | low | 0.1 | Swift CLI | 01, 02, 04, 05, 06, 08 |
| 0.4 | Sign PhysioNet DUAs: DREAMT (wrist PPG + IBI + PSG), Malaga treadmill (HR + VO₂). | — | S (owner) | none | — | — | 03, 05 |

### Tier 1 — quality gating and confidence (small, additive, highest evidence per effort)

| # | Item | Impact | Effort | Risk | Needs | 5.0 inputs | Scope | Source |
|---|---|---|---|---|---|---|---|---|
| 1.1 | **HRV window quality + nightly tiers.** Thread `tsSec` into `sessionHrvWindows`; `validPairs` = contiguous ∧ beat-accurate pairs; window tier refuse/limited/full at 30/50 pairs; night tier at ≥ 3 windows / ≥ 150 pairs / ≥ 6 full windows; reuse the 0.35 rejected-fraction gate; store tier (additive nullable column + migration test); `Baselines.update` skips `limited`. Log tier distribution first. **PR-sized.** | **H** | S | low (refuse/normal), flag for `limited` | 0.3 | R-R sparse, fillers | Swift + Kotlin + 1 migration both | 01 §4.3, §6.2 |
| 1.2 | **Respiratory-rate quality gate + confidence.** Per-window spectral peakedness on the same 4 Hz detrended grid (reuse `SleepStagerV2.RespDFT`, widen to 0.10–0.40 Hz); drop windows below a fitted floor or with interpolated-hole fraction > 0.10; require ≥ 6 kept windows; store `windowsKept / windowsAvailable / medianPeakedness`; shuffled-input test must return nil (the 13.33 floor inverted). **PR-sized.** | **H** | S–M | low (correctness) / medium (more nil nights) | 0.3 (Fantasia + slpdb to fit the floor) | R-R sparse, no resp waveform | Swift + Kotlin + 1 migration both | 04 §6.1, §4.3 |
| 1.3 | **Sleep: R-R hygiene for the RSA term.** `respRegularity` sees only `tsSuspect = 0` beats in scored channels and returns nil when `beatAccurateFraction < 0.5`. Pre-registered prediction: sparsified input no longer inflates deep share. **PR-sized.** | H (conditional on usable R-R) | S | low | 0.3 (DREAMT or CinC to measure) | fillers | Swift + Kotlin | 03 §6.1 |
| 1.4 | **RHR hardening.** Minute medians → sliding 5-min windows → coverage-fraction gate (≥ 0.60) and filler-share gate (≤ 0.50) → nadir headline unchanged in definition; store `rhr_nadir_start`, `rhr_lower_quartile`, `rhr_session_mean`, `rhr_coverage` as `metricSeries` keys so the comparison runs on real nights. Optional ±60-min guard band + band-state veto on HR-only nights. **PR-sized.** | M (single nights), H (interpretability) | M | low users / medium parity (median-of-even, .5 rounding seams) | 0.3 | HR dense, PPG filler, HR-only bounds | Swift + Kotlin | 02 §6 |
| 1.5 | **Skin temperature nightly statistic + coverage.** Trimmed window (+90 min / −30 min), 17-min moving average, stable-max; require ≥ 2 h kept and ≥ 50 % coverage (replaces the 300-sample floor); keep mean and p50 beside it; `wornToleranceSec > 0` for 5.0 HR gaps; aux-channel instrumentation (read-only). Behind a flag, `metricSeries` only, until M1 (night-to-night SD) is measured. **PR-sized.** | H (cycle/illness sensitivity) | M | low | 0.3, byte-73 decode check on the owner's strap | skin temp "not consistent across firmware" | Swift + Kotlin | 08 §6.1, §6.3 |
| 1.6 | **Effort coverage + HRmax resolver.** Print credited minutes / 1 440 beside Effort and mark "Building" below 50 %; HRmax = manual > sustained multi-day strap-only peak (never `ppgHrSample`) > formula; remove the silent `220 − age` fallback (refuse instead). **PR-sized.** | M | S | low | — | HR dense, PPG filler | Swift + Kotlin | 05 I5, I7 |

### Tier 2 — one baseline, honest composites

| # | Item | Impact | Effort | Risk | Needs | 5.0 inputs | Scope | Source |
|---|---|---|---|---|---|---|---|---|
| 2.1 | **One baseline spine.** `PersonalBaselines` folded by `Baselines.foldHistory` for hrvLn / rhr / resp / skinTemp / effort; HRV in ln ms (`readinessHRVLnCfg`); `minNightsSeed` 4 → 7, trusted 14; delete `ReadinessEngine.zSignal`'s private re-fold, `V5HealthSignals.zAgainst`, `rollingMeanSD` callers; illness z keeps a **lagged** reference window (nights −21…−7, median/MAD) computed from the same series. Behaviour-preserving for Charge until 2.3. One oracle fixture pins all consumers. | **H** (trust/consistency) | M | low–medium | 1.1 (tiers decide which nights fold) | — | Swift + Kotlin + Android plumbing | 06 §3.2, §6A; 01 G6; 02 §3.3; 08 §3.5/3.7 |
| 2.2 | **HRV family driver.** Tonight ln z + 7-night ln trend z (≥ 3 valid of 7, Plews 2014), pinned blend 0.4/0.6, reduced weight when only one half exists. | H | S | low | 2.1 | R-R sparse | Swift + Kotlin | 06 §6B |
| 2.3 | **Charge composite with degradation.** RHR baseline required, HRV preferred; HR-only night scores from RHR + Rest + prior-day Effort (+ temp, + optional subjective rating) with `.building`; resp removed from Charge (stays in illness); candidate weights wHRV 0.40 / wRHR 0.25 / wSleep 0.25 / wLoad 0.05 / wTemp 0.05 / wFeel 0.10; gentler logistic k ≈ 1.0, z0 = 0; bands recomputed. **Flag until §3.3 held-out numbers exist.** | H on 5.0 (nights that score nothing today) | M | medium (headline change) | 2.1, 2.2, ReadinessBench | — | Swift + Kotlin + UI copy | 06 §4, §6D/E |
| 2.4 | **Strain wording + load units.** Replace "injury risk" / "illness risk" copy; drop the `.bad` flag at ACWR ≥ 1.5 and the "sweet spot" label; persist daily TRIMP (`metricSeries` key `trimp`); ACWR/monotony/CTL-ATL on TRIMP with **uncoupled** EWMAs (λ = 2/(N+1)) and absolute 7-day load shown; monotony descriptive, no 2.0 threshold. Two PRs (copy; units). | H (wording) / M (number) | S + M | none / low | 0.3 | HR | Swift + Kotlin + i18n catalogues | 05 I1, I2 |
| 2.5 | **Illness heads-up inputs.** Both platforms feed `IllnessSignalEngine` the same lagged z from 2.1; delete the iOS `dev / 0.3` fallback; sigma floor for temperature 0.1 °C (not 0.3); keep the ≥ 2-signal and confounder rules. | M | S | medium (changes which nights raise) | 2.1, 1.5; M4 base-rate count before/after | — | Swift + Kotlin | 08 §3.7, §6.2 |

### Tier 3 — Apple Health / Health Connect correctness (device-verified, not CI-verifiable)

| # | Item | Impact | Effort | Risk | Needs | Scope | Source |
|---|---|---|---|---|---|---|---|
| 3.1 | **Sync identifiers.** `HKMetadataKeySyncIdentifier` + `SyncVersion` (write-time epoch) on vitals, sleep, workouts; drop pre-save `deleteObjects` for them; one-off sweep of ExternalUUID-keyed samples (the #1503 pattern); keep explicit retraction. | M (robustness: closes the duplicate window) | M | medium (touches dedup) | device test §5 of 10 | iOS app | 10 §3(g), §6.3 |
| 3.2 | **`HKDevice` + metadata.** One device per active strap (model via `DeviceFamily.forRegistryModel`, firmware from registry, CB UUID as `localIdentifier`, UDI nil); `HKMetadataKeyTimeZone` on sleep; `WasUserEntered` false/true. Maintainer sign-off on the manufacturer string. | L–M (attribution) | S | low | — | iOS app | 10 §3(h), §6.5 |
| 3.3 | **Shortcut path correctness.** Column 2 becomes window SDNN (or a fourth column); calibrate or drop the steps column; state the Health type in the UI and `docs/IOS.md`; create the setup page the UI promises (the wiki link 404s). | H for sideloaded readers | S | low | — | Strand/Data + iOS UI + docs | 10 §3(b), §6.4 |
| 3.4 | **iOS 27 RMSSD probe.** Test-Centre-only share request for `.heartRateVariabilityRMSSD` behind an armed-flag guard (a disallowed share is an uncatchable exception, #1366); on success write `avgHrv` under it with the same key scheme; never fall back across SDNN/RMSSD. | M (RMSSD finally visible in Health) | M | medium (authorization) | 3.1 preferred first | iOS app | 10 §6.1 |
| 3.5 | **SDNN sample shape.** Per-5-min-window SDNN interval samples (Health's daily mean then equals the index) or span `[onset, wake]`. | L–M | S | low | 3.1 | iOS app | 10 §3(a), §6.2 |
| 3.6 | **Android metadata + timestamps.** `Metadata.autoRecorded(device = Device(TYPE_FITNESS_BAND…))` everywhere, `manualEntry` for manual workouts; daily records at the wake instant, not noon. Do before the `connect-client` bump that makes it mandatory. | H at next SDK bump | S–M | low | — | Android app | 10 §3(l)(m), §6.8 |
| 3.7 | **Android skin temperature export.** `SkinTemperatureRecord(deltas, baseline, MEASUREMENT_LOCATION_WRIST)` feature-gated; iOS states the wall. | M | S | low | 1.5 for the value | Android app | 10 §6.7; 08 §6.4 |
| 3.8 | **Workout HR attachment** + skip exported spans in the HR stream. | M (Health workout page) | M | low | 3.1 | iOS app | 10 §6.6 |
| 3.9 | **Docs.** `docs/CROSS_PLATFORM.md` row for the HRV-type asymmetry; `docs/IOS.md` list of written and unwritable types; source-priority sentence in the Apple Health screen. | — | S | none | — | docs + UI copy | 10 §3(k)(q), §6.10 |

### Tier 4 — sleep on sparse motion

| # | Item | Impact | Effort | Risk | Needs | 5.0 inputs | Scope | Source |
|---|---|---|---|---|---|---|---|---|
| 4.1 | **HR-only onset/offset refinement** (Perez-Pozuelo): rolling 10-min HR std with a night-relative floor, search ±4 h / ±1 h around run edges; raise min block to 20 min; bridge ≤ 90-min gaps when both sides are in band. Measured change: onset bias vs diary / CinC. | M (moves every overnight vital on HR-only nights) | S | low | 0.3 (CinC synthetic 1 Hz HR), owner diary | HR-only bounds | Swift + Kotlin | 03 §6.4 |
| 4.2 | **Posture-angle feature + HDCZA-style spine** when `isGravitySparse` and density ≥ 1/min; `angleVar` added to the emission. Ships with a replay-diff over the owner's history and a flag. | M–H on sparse nights | M | low–medium | 0.3 (sleep-accel downsampled to 1 Hz + gaps) | gravity sparse | Swift + Kotlin | 03 §6.3 |
| 4.3 | **Fitted linear emission, pinned.** Multinomial logistic over V2's epoch features (+ angleVar, hrSlope5), fitted offline in numpy LOSO on sleep-accel + DREAMT (+ CinC for the no-motion regime), three motion regimes; `W`, `b` pinned as literals with provenance; Viterbi unchanged; extend SleepPSG `RecipeConfig`. Pre-registered: pooled κ +0.05 over 0.371 with no worse |deep| / |wake| bias. **Flag until the held-out column clears.** | H | M | medium (cohort overfit) | 0.4 (DREAMT), 1.3, 4.2 | all | Swift + Kotlin + Python fit script | 03 §6.2 |
| 4.4 | **Un-clamp wake on motion-absent nights**, gated on sustained HR volatility. After 4.3. | M | S | medium (#437 shape) | 4.3 | HR-only | Swift + Kotlin | 03 §6.5 |
| 4.5 | **Export honesty for HR-only nights**: default-off toggle to write `.asleepUnspecified` instead of a full hypnogram when `sleepHrOnly`. | L–M | S | low | — | iOS + Android writers | 10 §3(i) |

### Tier 5 — formula upgrades with their own harness

| # | Item | Impact | Effort | Risk | Needs | 5.0 inputs | Scope | Source |
|---|---|---|---|---|---|---|---|---|
| 5.1 | **Lipponen–Tarvainen 2019 artifact classifier** (deterministic port; α 5.2, window 91, c1 0.13, c2 0.17, NumPy-linear quantiles) with NOOP's policy: merge EXTRA, split MISSED, delete ECTOPIC/LONGSHORT; never across a `tsSuspect` boundary; run once. **Instrumentation first**: log Malik-vs-LT per night for weeks before switching. | M (robustness across wearers, recovers scarce pairs) | M | medium (quantile/median parity seams) | 0.3 (PPG-DaLiA, GalaxyPPG) | fillers | Swift + Kotlin | 01 §6.1 |
| 5.2 | **Effort scale re-anchor** `100·ln(1+T/T₀)/ln(1+T_ref/T₀)` with documented anchors; two-parameter fit on the owner's WHOOP export with a temporal split; `strainScale = 2` on rows; Banister-on-%HRR as default, Edwards-style renamed `.hrrZones` or re-cut on %HRmax. **Flag.** | H (every Effort moves) | M | medium | 0.3 (LoadBench), WHOOP CSV | HR | Swift + Kotlin + importer | 05 I3, I4 |
| 5.3 | **Calories**: Mifflin–St Jeor BMR; drop the Uth VO₂max branch unless a measured VO₂max is entered; persist resting and active kcal separately; label "typical error 15–30 %"; %HRR-based active equation only once Hiilloskorpi's coefficients are verified. | M (bias, not order of magnitude) | M | low–medium | 0.3 (Malaga for per-bout error) | HR, profile | Swift + Kotlin + 1 migration | 05 I6 |
| 5.4 | **Respiration spectral cross-check** (Smart-Fusion agreement within 2 bpm, prominence-gated peaks, one spectral funnel shared with the stager) and **quiescence-weighted aggregation** (stage-free). | M | M + S | medium | 1.2, 0.3 | R-R | Swift + Kotlin | 04 §6.2, §6.3 |
| 5.5 | **Skin-temperature cycle component** (zero-phase Butterworth 1.5/28 cycles·day⁻¹ or cosinor, elevation above rolling minimum), opt-in only; `CyclePhaseEngine` consumes it. | H for cycle tracking (if applicable) | M | medium (filter literals must be byte-identical) | 1.5, 2.1 | skin temp | Swift + Kotlin | 08 §6.2 |
| 5.6 | **Steps calibration estimator + plausibility band.** Extend `StepsEstimateEngine`'s motion-weighted log-ratio median to the 5.0 counter vs Apple hourly/daily steps; proportional-bias check; trailing-30-day P5–P95 band; "partial day" flag from coverage. | H on the displayed number | S–M | low | Apple step reads (exist) | counter, class byte | Swift + Kotlin | 09 §6.1, §6.2 |
| 5.7 | **HRV stationarity selector** (lowest-variance-quartile windows, median RMSSD), trace/display only. | M (night-to-night reliability), unknown absolute | S | low | 1.1 | R-R | Swift + Kotlin | 01 §6.3 |
| 5.8 | **Charge ratio driver** (Buchheit ln RMSSD / mean R-R), flagged; retires the unapplied saturation guard if real firings agree. | M | S | medium (unvalidated premise) | 2.1, R6 base-rate count | — | Swift + Kotlin | 06 §6C |

### Tier 6 — research instrumentation and documentation

| # | Item | Impact | Effort | Risk | Needs | Scope | Source |
|---|---|---|---|---|---|---|---|
| 6.1 | **Citation and doc repairs** (one docs PR): `ReadinessEngine` Lamberts 2004 → Buchheit 2014; `StrainScorer` Banister pairs attributed to Banister 1991 not Morton 1990; `CyclePhaseEngine` "PMC11294004" is Gombert-Labedens 2024 (Oura finger ring, not wrist); `IllnessSignalEngine` "Stanford/Snyder" = Mishra 2020, which uses no temperature; `docs/ANALYTICS.md` steps/active-energy floor not found in `StrandAnalytics`; `populationMean 58` and the WHOOP 34/67 bands are unverified vendor figures; `docs/ANALYTICS.md` pointer to `07-spo2.md`. | L (correctness of record) | S | none | — | docs + comments | 02 §1.5; 05 G9; 08 §1.6; 06 G7; 07 §6 |
| 6.2 | **Research-only 100 Hz IMU step counter** (walk-gated Verisense-style peaks + autocorrelation cross-check) to score the strap counter per bout; validated on OxWalk/Clemson first. | none shipped / H for validation | M | medium (licence hygiene: no `stepcount` code) | Raw Data Collector sessions | Swift (+ Kotlin) | 09 §6.3 |
| 6.3 | **Respiration from v26 PPG bursts** (BW/AM/FM Smart Fusion) behind an Experimental flag, gated on a capture audit showing contiguous ≥ 32 s bursts exist. | M–unknown | L | high | burst-contiguity audit, 1.2 | Swift + Kotlin | 04 §6.4 |
| 6.4 | **Subjective wellness rating** in the journal (single 1–5 item), both as an optional Charge driver (2.3) and the cheapest validation proxy. | M | S | low | UI | iOS + Android UI + journal schema | 06 §2.1, §5.1 |
| 6.5 | **Steps→kcal fallback** for HR-less hours only (0.75 kcal·kg⁻¹·km⁻¹, step length 0.74 m default), never summed with Keytel, never fed to strain. | L | S | low | 5.6 | Swift + Kotlin | 09 §6.4 |

---

## 3. Validation infrastructure (build first)

### 3.1 Datasets into `research-data/` (git-ignored on this branch)

| Dataset | For | Access | Size |
|---|---|---|---|
| PhysioNet **sleep-accel** (Walch 2019) | sleep staging/detection; RHR window sensitivity; motion-sparsity ablation | open, ODC-By | 577 MB zip |
| PhysioNet **Fantasia** | RSA respiration (young vs elderly); artifact-detector unit tests | open, ODC-By | 293 MB |
| PhysioNet **MIT-BIH Polysomnographic (slpdb)** | respiration with stages; REM/quiescence aggregation | open, ODC-By | 632 MB |
| PhysioNet **BIDMC** | PPG respiration track; RMSSD formula checks | open, ODC-By | 208 MB |
| UCI **PPG-DaLiA** / **WESAD** | wrist PPG vs chest ECG artifact detection; HR under motion | open, CC BY 4.0 | 2.7 GB / — |
| Zenodo **GalaxyPPG** | wrist PPG vs Polar H10 IBIs (already used by Kotlin fixture tests) | open, CC BY 4.0 | 482 MB |
| ORA **OxWalk** | 100 Hz / 25 Hz wrist step detection ground truth | open, CC BY 4.0 | 290 MB |
| PhysioNet **Malaga treadmill tests** | HRmax formula SEE; HR→kcal error vs calorimetry | PhysioNet DUA (free) | 22 MB |
| PhysioNet **DREAMT v2.2.0** | the only wrist PPG + IBI + 1 Hz HR + PSG set: staging incl. RSA term, HRV PPG-vs-ECG, RHR | restricted: PhysioNet account + Restricted Health Data DUA 1.5.0 | not stated |
| PhysioNet/CinC **2018** (optional) | HR-only staging at scale; synthetic WHOOP sparsity | open, ODC-By | 135 GB training |
| Zenodo **WEEE** (optional) | wrist PPG → HR → kcal end-to-end | open, CC BY 4.0 | 652 MB |

Not available publicly: readiness ground truth, free-living calorimetry, wrist temperature with illness
labels, WHOOP strain beside raw HR, wrist red/IR PPG with arterial SaO₂, AAUWSS (referenced in-tree, no
landing page found). Each is stated as "cannot be measured on public data" (R8) in its topic file.

Scripts: one `Tools/research-data/fetch.sh <name>` per open dataset (curl + checksum + unzip into
`research-data/<name>/`), with the DUA sets documented as manual steps. No dataset is ever committed.

### 3.2 Harness: `Tools/MetricsBench`

One Swift package in the `Tools/SleepPSG` pattern (depends on `StrandAnalytics` and `WhoopProtocol`,
read-only, prints its regenerating command and run date per R3), with:

- a pure WFDB reader (signals + annotations) for the PhysioNet sets, and CSV readers for UCI/Zenodo;
- a **WHOOP-5.0 sparsity simulator**: whole-second `ts` stamping, ≤ 4 R-R words/s, 500 ms filler
  injection flagged like `v47`, random v26 holes, 1 Hz gravity downsampling with gaps;
- subcommands: `hrv` (window-floor sweep, Malik vs LT, PPG vs ECG agreement, Kim-style deletion Monte
  Carlo), `resp` (per-window and nightly MAE/LoA/CP2, false-emit rate on shuffled input, age/stage
  strata), `rhr` (statistic sensitivity to window shifts, definition comparison), `load` (HRmax SEE,
  HR→kcal MAPE, Effort old/new replay, WHOOP-CSV scale fit with temporal split), `readiness` (candidate
  composites over a DB copy + CSV + journal, LOO and temporal split), `skintemp` (per-night funnel,
  mean vs stable-max SD, aux gradients);
- sleep stays in `Tools/SleepPSG` (add the three-regime motion ablation and the DREAMT loader) and
  `Tools/SleepBench` (E.-1 audit before any personal-night claim).

Note: `swift-packages.yml`'s `tools` job lists `Tools/SleepBench`, `Tools/SleepPSG`, `Tools/Backfill`
explicitly; a new package needs that workflow edited to be CI-built, and the Linux-only `tools-python`
job has no path filter (so Python fitting scripts under `Tools/` get discovered by `unittest`).

### 3.3 Owner-data protocol (Phase 4, summarised; details per topic §5.3)

- **Polar H10 co-wear ≥ 14 nights (28 for RHR)** with a sleep diary (lights-off, final wake, alcohol,
  late training, illness). Align by wall clock then by 5-min mean R-R cross-correlation, never on
  RMSSD. Compute each statistic from the H10 stream over NOOP's bounds and over diary bounds to separate
  window error from sensor error. Temporal split 14/14 (R5). Pre-registered targets: whole-night RMSSD
  bias within ±8 ms on `normal` nights; RHR nadir vs nadir Bland–Altman; onset/offset error in minutes;
  resp nightly MAE ≤ 1.0 vs a breathing reference (sternum-phone accelerometer or belt).
- **WHOOP CSV export** (full account history): per-sleep totals → signed per-stage minutes bias only (no
  epochs); Day/Activity Strain + zone minutes → Effort scale fit on the early half, MAE on the late half;
  WHOOP recovery as a *reference estimate* for the Charge formula test (≥ 100 days per half; n = 8 is
  known to overfit).
- **Blind morning wellness rating** ≥ 60 mornings before any Charge weight is touched; tagged
  alcohol/illness days with base rates counted first (R6).
- **Phone steps** daily and hourly for ≥ 14 days; 3 metronome-paced hand-tally walks with capture on;
  one unstructured-gait session; one overnight capture.
- **Skin temperature**: waking oral thermometer daily, a bedroom temperature logger, illness diary;
  first check whether byte 73 decodes at all on this strap (`skinTempFunnel.totalSamples`).
- Everything stays under `research-data/`; results in `docs/research/results/<item>.md` with the
  regenerating command.

---

## 4. What is not feasible with current WHOOP 5.0 data

Stated plainly, with the topic that establishes it:

1. **SpO₂ from the optical records** — no wavelength identity, no same-pulse red/IR pair, compromised
   DC term, no calibration curve, no reference below ~94 % obtainable ethically. Keep `spo2Pct = nil`;
   imports only. Not even instrumentation of an "R from R20" ratio is recommended (07).
2. **A software step counter on the shipped motion stream** — ~1 Hz gapped gravity is an order of
   magnitude below the ~11 Hz floor; any periodicity found there is the record period (09).
3. **Respiratory rate when R-R is absent** (v26-heavy stretches) — unless the v26 bursts prove contiguous
   ≥ 32 s and the PPG-modulation research track (6.3) succeeds; otherwise those windows are correctly nil
   (04).
4. **Stage-level sleep truth for personal nights** — no PSG; only minutes-level agreement with the WHOOP
   export and diary onset/offset can be measured; κ cannot (03).
5. **Staging accuracy under 1 Hz / gapped / absent motion** — unmeasurable until the sleep-accel ablation
   and DREAMT run; today's κ 0.37 was measured with dense accelerometry (03 G8).
6. **Readiness against a gold standard** — none exists publicly; only owner proxies on a temporal split
   (06).
7. **Daily calorie accuracy** — no calorimeter; per-bout error from Malaga/WEEE only; label with a
   ±20–30 % band (05).
8. **Illness-detection validation** — no public wrist-temperature + illness dataset; owner diary only (08).
9. **Wrist temperature in Apple Health** — `.appleSleepingWristTemperature` is share-denied for third
   parties; `.bodyTemperature` would mislabel it (10). Health Connect can carry it.
10. **Deep-sleep-window HRV to chase WHOOP's absolute value** — refuted on real data; stage labels are
    κ ≈ 0.37 (01, `docs/RR-OPTIMIZATION.md`).
11. **Firstbeat-style respiration-aware energy expenditure** — needs dense R-R (05).

---

## 5. Cross-topic consistency notes

- **Sleep bounds are upstream of every overnight vital** (inventory §3.1). Tier 4 detection changes
  (4.1, 4.2) must ship with a replay-diff of HRV, RHR, respiration and skin temperature over the
  owner's history, and Tier 1 gates must be re-measured after them.
- **"Value + coverage/tier" is one pattern across 01, 02, 04, 05, 08.** Recommend one shared shape
  (`metricSeries` keys `<metric>_tier` / `<metric>_coverage`, or one nullable column each) and one rule:
  consumers (baselines, Charge, Readiness, illness, Health export) read the tier and skip `limited`.
- **Filler beats (`tsSuspect = 1`) are a hard gap everywhere** — HRV pairs (01), RSA regularity (03),
  respiration (04). The flag is protocol work; analytics never re-derives it.
- **One baseline spine, two reference windows.** 06 recommends the EWMA spine for readiness; 08
  recommends a lagged robust reference for illness. Both are computed from the same nightly series by
  the same code; the difference is which window a consumer asks for. This is the resolution of
  inventory §3.2.
- **Respiration leaves Charge** (06 G9) but stays in the illness engine (04, 08); its new confidence
  (1.2) is what the illness ≥ 2-signal rule should gate on.
- **HRV type asymmetry is legitimate**: iOS writes the SDNN index (and RMSSD on iOS 27 if share-able),
  Android writes RMSSD; document it rather than "fix" it (10 §3(k)).
- **Risk wording** (05 I1) and the saturation-guard premise (06 G12) are both cases of the repo rule "a
  diagnostic may only assert what it can attribute".

---

## 6. Open questions for the owner

1. **Toolchain**: will you install Xcode on this Mac (required for Swift tests and `StrandTests`)? And
   the Android SDK, or should Kotlin tests rely on CI?
2. **Data-use agreements**: are you willing to sign the PhysioNet DUAs for DREAMT (restricted health
   data) and the Malaga treadmill set? DREAMT gates items 4.3 and the PPG-vs-ECG HRV figures.
3. **Reference hardware**: do you have (or will you get) a Polar H10? It is the single most useful
   instrument for topics 01, 02, 04 and 05. Any breathing reference (belt, or a phone on the sternum)?
   A fingertip oximeter is only useful for imported SpO₂.
4. **WHOOP CSV export**: do you still have the full account export, and how many days does it cover?
   The Effort scale fit and the Charge formula test need ≥ 100 days per temporal half.
5. **iOS path**: are you on iOS 27 with a HealthKit-entitled build, or sideloaded via the Shortcut file?
   This decides whether 3.1–3.5 or 3.3 comes first.
6. **Wear site**: wrist or bicep band? Affects skin temperature, steps calibration and the HR-only
   detection anchor.
7. **Does byte 73 decode on your strap?** A quick check of `skinTempFunnel.totalSamples` over recent
   nights decides whether 1.5 / 5.5 / 3.7 are worth anything on your firmware.
8. **Cycle tracking**: relevant for you? If not, 5.5 drops out of scope.
9. **Appetite for headline changes**: items 2.3 (Charge composite) and 5.2 (Effort re-anchor) move
   every historical number. Both are proposed behind flags until held-out numbers exist. Do you want
   them pursued at all, or only the quality/consistency items?
10. **Subjective rating**: would you log a blind 1–5 morning rating for ~2 months? It is the best
    evidenced readiness input and the cheapest validation proxy.
11. **Prioritisation**: the suggested order is Tier 0 → 1.1, 1.2, 1.3 → 3.3, 3.6 → 2.1, 2.2 → 1.4, 1.5,
    1.6 → 2.4 → 3.1, 3.2 → 4.1 → remaining tiers as data access allows. Each Tier 1–3 item is one
    upstream PR. Which items do you approve, and in what order?

---

## 7. Deliverables produced in Phases 0–2

- `docs/research/00-inventory.md` (229 lines) and `01`–`10` (698 / 593 / 655 / 568 / 595 / 598 / 518 /
  490 / 573 / 548 lines), ~6,000 lines, every cited source fetched this session with its identifier
  and the finding verified, unfetchable leads quarantined in each file's §8.
- Citation audit (2026-11-12, after all ten files were written): every DOI and PubMed ID in
  `01`–`10` was re-resolved by script. 254 unique DOIs resolve at the doi.org handle API; 168
  unique PubMed IDs exist on NCBI; the Crossref or PubMed title of every identifier matched the
  title written beside it. This checks identifiers and titles, not every extracted number.
- `.gitignore`: `research-data/` added.
- `RESEARCH_BRIEF.md` at the repo root (untracked; not for upstream).
- Nothing committed yet; no source code touched; no protocol or BLE files read for modification.

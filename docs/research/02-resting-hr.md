# 02 — Resting heart rate

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Phase 1 topic 02 of
`RESEARCH_BRIEF.md`. Every source in §7 was fetched this session (Europe PMC records, PMC full texts,
PhysioNet / NSRR pages, vendor pages); anything that could not be fetched is in §8 and nothing in §2–§6
rests on it. Numbers carry n, instrument and units per `docs/VALIDATION_PROTOCOL.md` R7. Wording is
non-medical throughout: a resting heart rate here is a nightly approximation for trend-watching, not a
clinical measurement.

---

## 1. What NOOP does today

### 1.1 Per-session value — `SleepStager.sessionRestingHR` (Swift + Kotlin twin)

`Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStager.swift` (`sessionRestingHR`, ~L2918;
constants ~L84) and `android/app/src/main/java/com/noop/analytics/SleepStager.kt` (`sessionRestingHR`,
constants ~L61).

- Input: `HRSample` rows (`COALESCE(hrSample, ppgHrSample)`, nominally 1 Hz on a 5.0 when R18 is banked)
  filtered to the detected session `[start, end]`.
- Tumbling (non-overlapping) 5-minute bins anchored at `start`; the final bin closes on `end`.
- A bin may **win** only if it holds `≥ rhrMinBinSamples = 5` samples and its mean is
  `≥ rhrMinPlausibleBpm = 25` (#1943 artefact gate, shared with `rhrBinGateLogLine`).
- Result = `round(min(gated bin means))`; fallback lowest ungated bin mean; fallback all-sample mean.
  Never nil on data.
- Note the gate is a sample **count**, not a coverage fraction: 5 samples in a 300-s bin is 1.7 %
  coverage at 1 Hz, so a bin built from a short burst inside a wear gap can still win.

### 1.2 Daily value — `AnalyticsEngine.analyzeDay` (~L728–762)

- "Physiology sessions" = motion-backed sessions; HR-only sessions are used only when the day has no
  other kind (#1801/#1884).
- Primary session = longest physiology session (ties → first). Daily `restingHr` = that session's
  `sessionRestingHR` (#2522 reverted #2358's whole-session mean but kept its nap protection, #2358).
- A device-provided (imported) value for the same session wins (#804).
- Consumers of the daily value (from #2522's audit): `RecoveryScorer` (z vs baseline, `wRHR 0.20`),
  `StrainScorer` heart-rate reserve (`restForStrain = restingHRDaily`), `FitnessAgeEngine` (7-day
  median RHR), `IllnessSignalEngine`, `CyclePhaseEngine`, HealthKit `.restingHeartRate` and Health
  Connect `RestingHeartRateRecord`. A definition change moves all of them.

### 1.3 Shadow metric — `PrimarySessionRestingHR` (#1169)

`PrimarySessionRestingHR.swift` / `.kt`: arithmetic sample mean of valid (30…220 bpm) samples of the
longest session, nil below `defaultMinValidSamples = 30`; emitted as `rhr_primary_session` with a
`Coverage(validSamples, durationSec)` record. Instrumentation only, never scored. Evidence in the file
header: **one participant, 5 nights**, references = official WHOOP RHR and a Polar H10 whole-recording
mean; rounded MAE vs WHOOP 6.0→2.0 (dev, n=3) and 7.5→0.8 (holdout, n=2); vs H10 mean 8.3→1.4 / 8.9→0.8.

### 1.4 Baselines and deviation

- `Baselines.swift` / `Baselines.kt` `resting_hr` cfg: bounds 30–120 bpm, `floorSpread 2.0` bpm,
  Winsorized EWMA with centre half-life 14 nights and spread half-life 21 nights, Winsor ±3·spread,
  hard-outlier reject at 5·spread (suspended while `nValid < earlyAdaptNights`, early half-life 3),
  `minNightsSeed 4` (usable), `minNightsTrust 14`, `staleDays 14`; missing night = skip-and-hold.
  σ ≈ 1.253 × spread.
- `ReadinessEngine.swift` RHR signal: trailing `baselineWindow 30` nights, `minBaseline 7`, re-folded
  through the same EWMA spine with hard-outlier rejection off, linear domain, z bands
  good ≥ 0.5 / neutral / watch −1.0…−0.5 / bad < −1.0 (oriented so lower RHR is better).
- `RecoveryScorer`: robust z = (μ − rhr)/(1.253·spread), weight 0.20.
- `android/…/V5HealthSignals.kt`: a third, Android-only 30-night rolling z (inventory §2.6 (c)).

### 1.5 Papers cited in code

`ReadinessEngine.swift` L13–14 attributes "elevated resting HR vs baseline is a classic overtraining /
illness signal" to **Lamberts et al. 2004**. The fetched record (§7, S3) is *Variation in heart rate
during submaximal exercise: implications for monitoring training* — a 44-subject study of
**exercise and recovery** HR repeatability (CV 1.1–1.4 % at ~90 % HRmax); its abstract reports no resting
HR figure. The citation does not support the sentence it is attached to. Buchheit 2014 (S1) does, and is
already cited elsewhere in the tree.

### 1.6 Tests

Swift: `ManualWorkoutRescoreRestingHrTests`, `PrimarySessionRestingHR*` via `AnalyticsEngine` tests,
the `rhr bins` conformance line. Kotlin: `PrimarySessionRestingHRTest`. There is no fixture that pins
`sessionRestingHR` against an external reference, and no harness for RHR at all (inventory §3.4).

---

## 2. Recommended method(s) from the literature

### 2.1 What "resting heart rate" means in the sources that were fetched

There is no single research definition; the fetched sources split into three families.

| Family | Who uses it (fetched evidence) | Statistic |
|---|---|---|
| **Nocturnal nadir** | Speed 2023 (S9, Fitbit Charge 4, n=433): lowest inactive 1-min HR of the primary sleep period after ≥ 4 min of inactivity. Oura (V2): "lowest RHR value captured during the night", sampled every 10 min. Garmin, as quoted by Dial 2025 (S10): lowest 30-min average in 24 h. | minimum of short windows |
| **Sleep mean, restricted or weighted** | Natarajan 2020 (S7, Fitbit, n=2,745): "mean nocturnal heart rate during NREM sleep", REM excluded. WHOOP, as quoted by Dial 2025 (S10) and Bellenger 2021 (S11): a dynamic average weighted towards the last slow-wave-sleep episode; HR/HRV quantified "in the final SWS episode". Polar (S10): first 4 h after sleep onset. Dial 2025's own ECG reference: whole-night average. | mean over a stage / time subset |
| **Awake inactive** | Apple Health app text (V4, secondary): "average heart beats per minute measured when you've been inactive or relaxed for several minutes … does not include your heart rate while you're asleep". Fitbit (V3): RHR "estimated each day", sleeping HR "often lower than your resting heart rate". Buchheit 2014 (S1): 5–10 min supine/seated on waking. | morning / daytime still |

Two facts matter for NOOP:

1. **The families differ by several bpm on the same night, by construction.** Speed 2023 measured
   night nadir 50.5 ± 7.6 vs daytime nadir 54.5 ± 8.0 bpm (paired difference 3.9 ± 3.8, n=433). On one
   NOOP wearer over 23 nights (#2284, n=1), lowest 5-min bin 48.9, deep-sleep mean 54.9, whole-night mean
   58.1 bpm. A whole-night mean sits roughly 8–10 bpm above the 5-min nadir on the same wearer (#1169,
   #2284, #2522 — all n=1). This is why "matches WHOOP/Oura/Apple" is meaningless without the definition.
2. **Every family is defensible for trend-watching; none is validated as "the" resting HR.** The
   illness-tracking studies used an NREM mean (S7) or Fitbit's daily value (S4, S5) and a nadir-style
   lowest-inactive value (S9's authors derive their day/night choice from the Quer 2020/2021 pipeline);
   the athlete-monitoring literature uses a waking measurement (S1) or a night-time WHOOP value (S12).
   No fetched paper compares the predictive value of nadir vs mean head-to-head.

### 2.2 Stability (night-to-night noise)

| Measure | Value | Source (n, instrument) |
|---|---|---|
| Morning resting HR, day-to-day CV | ≈ 10 % (Table 1), SWC ≈ −2 % for a positive adaptation, signal-to-noise 0.7 | S1 (review) |
| Nocturnal HR (WHOOP 3.0 SWS value), mean weekly CV | 7.6 ± 1.3 % | S12 (11 elite water-polo players, 16 weeks) |
| Nocturnal HR CV during last-SWS window | 10–11 %; SWC 5–5.5 % | S11 (6 adults, ECG-timed) |
| Lowest 5-min bin, night-to-night SD | 2.2 bpm (whole-night mean 2.2; deep mean 3.1; last deep run 4.4) | #2284 (n=1, 23 nights, WHOOP 5.0 in NOOP) |
| HRV-CV reliability: nights needed per week | ≥ 5 of 7 nights for ICC ≥ 0.80 vs the full week | S14 (>21,000 users, ~2 M nights) |

Reading: a nocturnal statistic is at least as stable as a morning one (S12 vs S1), and on the one NOOP
wearer the nadir was *not* noisier than the mean (both SD 2.2 bpm) while the stage-restricted variants
were noisier (3.1–4.4) because they inherit staging error. The single-sample minimum that Speed 2023
uses is the most artefact-exposed form; a 5-min window is the smallest that clears Speed's observed
4-minute stabilisation time.

### 2.3 Device accuracy for a nocturnal value (wrist / finger PPG vs ECG)

| Device | Statistic | Bias / LoA / other | Source |
|---|---|---|---|
| WHOOP 4.0 | vendor nocturnal RHR vs Polar H10 whole-night mean | bias −1.41 ± 1.69 bpm, LoA −4.72…1.90, MAPE 3.00 ± 2.15 %, CCC 0.91 | S10 (13 adults, 536 nights) |
| Oura Gen 3 / Gen 4 | same | −0.88 ± 1.00 (LoA −2.84…1.08), MAPE 1.67 % / −0.94 ± 1.43 (LoA −3.75…1.87), MAPE 1.94 % | S10 |
| Polar Grit X Pro | first-4-h window vs matched H10 | −0.01 ± 2.13, LoA −5.36…2.06, MAPE 2.71 % | S10 |
| WHOOP 3.0 | sleep-period mean HR from raw R-R vs ECG | bias −0.3 bpm, LoA ±1.9 | S13 (53 adults, 1 lab night) |
| Apple Watch S6 / Oura Gen 2 / Polar Vantage V / Garmin FR245 | night HR vs ECG | 0.5 ±4.0 / 0.1 ±8.8 / −1.1 ±4.4 / 5.0 ±25.0 bpm | S13 |
| WHOOP (strap gen. not stated) | HR in final 5 min of final SWS vs ECG | bias ≤ 0.39 ± 0.38 %, LoA ≤ 1.56 % | S11 |
| Oura ring | nightly average HR vs medical ECG | r² 0.996, bias −0.63 bpm | S15 (49 adults) |
| Six consumer wearables vs ECG (24 h, various activities) | absolute error at rest vs activity | activity error ≈ 30 % higher than rest; no significant skin-tone effect | S8 (abstract) |
| Apple Watch 3 / Fitbit Charge 2 | 24-h ambulatory ECG | mean diff −1.80 / −3.47 bpm, MAPE 5.86 / 5.96 % | S16 (n=1) |
| Polar H10 (reference candidate) | vs Holter ECG, RR signal quality | 99.6 % correct RR overall, 99.4 % at high intensity, r 0.997 | S17 (10 adults) |
| Polar H10 | vs ECG, resting ICC(3,1) | 0.95 pre-exercise, 0.85 post | S18 (25 adults) |

Conclusion for NOOP: **the WHOOP strap's night HR is not the limiting error** — ECG agreement at rest is
within ~1–2 bpm on multiple independent datasets. The uncertainty in NOOP's RHR is dominated by the
*definition* and by the *sleep window*, not by the sensor.

### 2.4 Baseline and deviation methods that were actually used in outcome studies

| Method | Where | Parameters as fetched |
|---|---|---|
| Personal rolling z-score | S7 (Fitbit, NREM mean HR) | rolling mean and SD of the metric; window length not stated in the fetched text |
| Residual vs 28-day sliding baseline + CuSum | S6 (Mishra, smartwatch RHR) | baseline window 28 d; RHR at 15-s resolution with 0 steps in the previous 12 min; CuSum threshold = half the 90 % (short-term) / 99 % (long-term) quantile of baseline residuals; alarm at p < 0.01, red if elevated 24 h; detected intervals < 24 h dropped. Offline RHR-Diff: median 4 d before symptoms, 7 d before diagnosis; 26/32 (81 %) showed an alteration |
| Population-level elevated RHR + longer sleep | S4 (Radin, Fitbit, 47,249 users) | weekly fraction of users above a threshold (threshold not in abstract); Pearson gain +0.12 (SD 0.07) over CDC-only model |
| Sensor + symptoms | S5 (Quer, 30,529 enrolled) | AUC 0.80 (IQR 0.73–0.86) vs 0.71 symptoms alone; abstract does not name which sensor metric |
| Weekly averaging + SWC | S1, S2 (Plews/Buchheit) | correlations with performance only appear once ≥ 3–4 days are averaged; SWC for HR ≈ −2 % (S1); Hopkins' default SWC = 0.2 × between-subject SD, typical error from a reliability study (S19, S20) |
| HRV-CV reliability | S14 | ≥ 5 of 7 nights for a trustworthy weekly CV |

Synthesis: a **~28–30-night personal window** with a **robust (Winsorized / EWMA) centre and spread**,
flagged at roughly **1 SD** for watch and **2 SD** for a strong deviation, is what both the Stanford and
Fitbit pipelines reduce to; the athlete literature adds **7-day rolling means** as the unit of
interpretation and a SWC of about 2 % (≈ 1 bpm at 50 bpm) — well inside NOOP's `floorSpread 2.0` bpm,
which means NOOP's spread floor already prevents sub-SWC noise from reaching |z| ≥ 1.

### 2.5 Within-night structure and confounders

- Timing of the nadir: 53 % of nightly minima fell between 03:00 and 07:00 (S9, mean bedtime 23:02,
  rise 06:27); Oura (V2) describes the ideal as a minimum in the first half of the night. HR shows a
  time-of-night (circadian) effect that is separate from stage (S21, 14 adults, PSG); mean NN lengthens
  across successive SWS periods, SWS3 (~02:40) lowest, ~7 bpm below the adjacent REM period (S22,
  children/adolescents, PSG). Stage mix explains most of the stage-linked variation; sleep itself drives
  the sympathetic rhythm (S23).
- Late vigorous exercise ending ~2 h before bed raised whole-night HR 51 → 54 bpm (p < 0.01), most in the
  first 3 h of sleep, with no whole-night HRV change (S24, 11 adults). Alcohol dose-dependently shifts
  autonomic balance in the first hours of sleep (S25, 4,098 employees, R-R recording), so an early-night
  elevation with a normal late-night nadir is the expected signature of both.
- Implication: a **nadir** statistic is relatively immune to a first-3-hours elevation (it reads the
  late-night floor), while a **mean** carries it. Which is "right" depends on the question: a mean
  measures the night's autonomic load; a nadir measures the lowest level reached. For a recovery
  composite that already carries HRV (which does respond to these confounders), the two are not
  redundant — see §3.3.

---

## 3. Gap analysis

### 3.1 NOOP's floor vs the fetched definitions

| Property | NOOP shipped (`sessionRestingHR`) | Closest published analogue | Gap |
|---|---|---|---|
| Statistic | min of tumbling 5-min bin means | Oura lowest-of-night at 10-min granularity (V2); Speed 2023 lowest inactive minute after 4 min still (S9) | Same family. NOOP's 5-min mean is a reasonable middle between Speed's 1-min minimum (most artefact-exposed) and Garmin's 30-min (least). |
| Window alignment | bins anchored at session start, non-overlapping | not specified by vendors | A tumbling grid can straddle the true nadir and report up to a few bpm high; a sliding window removes grid dependence (**low** impact, but free). |
| Artefact gate | ≥ 5 samples and ≥ 25 bpm | Speed: inactivity (MET < 1.5) + 4-min stabilisation; Mishra: 0 steps in prior 12 min | NOOP has no motion/stillness gate (cannot on a 5.0 with sparse gravity) and a count gate that is cadence-blind. **Medium** impact on gap-ridden nights: a 5-sample bin can win. |
| Session choice | longest motion-backed session | Speed: device "primary sleep period"; Natarajan: NREM only | Equivalent; nap protection matches the literature's primary-sleep choice. |
| Stored name | `restingHr` on `dailyMetric` / Health "resting heart rate" | Fitbit, Oura and Apple each *name* their statistic differently (sleeping HR vs RHR vs awake RHR) | NOOP exports a sleep nadir as HealthKit `.restingHeartRate`, which Apple defines as an awake-inactive average (V4). A systematic ~4–10 bpm offset against the Apple Watch definition is expected and should be documented, not "fixed" (topic 10). |

### 3.2 Is the shadow "primary-session mean" (#1169) better supported?

**Not on the fetched evidence.** What the literature supports:

- A *whole-session unweighted mean* is used by **no fetched vendor** as its RHR (Dial 2025 used it as the
  ECG *reference* statistic, S10; Miller 2022 computed it from WHOOP 3.0 raw R-R for validation, S13).
  Vendors that average restrict the window (NREM only, first 4 h, SWS-weighted).
- The #1169 experiment is n=1 / 5 nights with the official WHOOP value as the target. Matching a
  black-box number is not validation (`docs/VALIDATION_PROTOCOL.md` R2; #2522 §4). The H10 reference in
  that experiment was itself a whole-recording mean, so "mean agrees with mean" is close to tautological.
- #2284's deep-sleep mean inherits staging error: on 14/14 nights of one wearer, segments staged "deep"
  had a higher mean HR than REM (#2522 §3), which is the reverse of PSG physiology (S22). With NOOP's
  4-class κ ≈ 0.37 vs PSG (inventory §2.3), a stage-restricted mean is the least defensible choice today.
- The one thing the mean does better is **comparability with imported history**: a wearer whose baseline
  was seeded from an official export carries a value ~8 bpm above NOOP's floor, and their first computed
  nights then read as "unusually low" (#2284's second bullet). That is a real problem, but it is a
  *baseline-seeding* problem (`ChargeBaselines` imports only seed, #2525) and should be solved there — by
  refusing to mix statistics, or by offsetting the import seed from the first ≥ 7 paired nights — not by
  changing the shipped statistic.

Recommendation: keep a **nadir-family headline** (it is the shipped definition, it is Oura's and
Speed 2023's, and it needs no staging), harden it (§6), and keep the mean as a **separately named**
stored metric (`sleepHrMean`), which #1169 itself proposed for the floor in reverse. Do not promote
either to the other's slot without the §5 holdout.

### 3.3 Baseline machinery

Three implementations answer "how unusual is tonight" (EWMA `Baselines`, `ReadinessEngine` 30-night
re-fold, `V5HealthSignals.kt`). The literature does not prefer one window; 28 d (S6) and 30 d
(`ReadinessEngine`) are the same choice. What the literature does say:

- **Cold start**: `minNightsSeed 4` is below every fetched threshold (Buchheit/Plews ≥ 3–4 *averaged*
  days before a value is interpretable, S1; 5 of 7 nights for a weekly CV, S14; NOOP's own
  `HRVReadiness.minNights 14`). Usable at 4 nights with a 2-bpm floor spread is tolerable for display,
  but RHR should not feed the illness/readiness *flags* before ~7 valid nights (`ReadinessEngine.minBaseline 7`
  already does this; `RecoveryScorer` does not).
- **Missing nights**: skip-and-hold with a 14-day stale cut-off is consistent with S6's treatment (Mishra
  imputed missing days as zeros only for the offline detector, which NOOP should not copy).
- **Deviation scale**: `floorSpread 2.0` bpm ≈ 4 % of 50 bpm, i.e. twice Buchheit's −2 % SWC and about
  half Oura's "3–5 bpm" vendor band. Reasonable. A 7-night rolling mean of the nightly value (not shipped
  for RHR, shipped for HRV in `HRVReadiness`) is what S1/S2 recommend for reading trends.

Expected accuracy impact of fixing each gap: sliding window + coverage gate **low–medium** (changes
single nights on gap-ridden data, not the trend); naming/exporting both statistics **high for
interpretability**, zero for the number; baseline-seed mismatch fix **medium** for imported-history users
(it is the actual cause of the "Charge inflated after import" complaint).

---

## 4. WHOOP 5.0 input constraints

| Input | Status on a NOOP-only 5.0 | Effect on RHR |
|---|---|---|
| HR (`hrSample`, R18 byte 22, 1 Hz when banked; `ppgHrSample` filler) | reliable (inventory §1) | None for the nadir once a bin has coverage; the PPG filler is confidence-flagged and should be excluded from *winning* a bin (it may fill a gap but a bin whose majority is filler should not set the night's floor). |
| Motion / gravity | sparse | No stillness gate possible (Speed's MET < 1.5, Mishra's 0-steps rule). The sleep-session bound is the only "inactive" proxy. |
| Sleep bounds | HR-only detection on many nights (`hrOnlySessions`, 10th-percentile anchor × 1.05) | **This is the main propagation path.** A nadir needs the window to *contain* the true minimum (03:00–07:00 for most people, S9). An HR-only window that starts late or ends early can miss it and bias the floor **up**; a window that over-extends into quiet wake rarely lowers the floor (wake HR is higher) but adds bias to a *mean* of ≈ (wake − sleep HR) × (over-extension / window), e.g. 30 min at +15 bpm over 7 h ≈ +1.1 bpm. `docs/VALIDATION_PROTOCOL.md` R5 documents > 10 bpm drift of the HR-only threshold within 3 weeks on one wearer, so HR-only nights carry a window error that is not constant. |
| Band sleep state (byte 81) | present, reference only | Could veto bins whose band state is WAKE/UP from winning (cheap, 5.0-available, not a hypnogram). Not currently read by `sessionRestingHR`. |
| Stages | κ ≈ 0.37 | A stage-weighted RHR (WHOOP-style, #2284) is not advisable on 5.0 today. |

Graceful degradation recommendation:

1. Compute the nadir over the **union of the primary session and a ±60-min guard band**, gated by band
   sleep state ≠ WAKE where byte 81 exists; the floor is insensitive to including quiet wake, and the
   guard band protects against a late-starting / early-ending HR-only window missing the nadir.
2. Emit a per-night **coverage fraction** (`validSamples / (durationSec × expectedHz)`) and the
   `hrOnly` flag with the value; down-weight (`ScoreConfidence`) rather than drop.
3. On nights where the winning bin's coverage < 60 % or where the floor comes from the fallback
   paths, mark the daily `restingHr` as low-confidence; do not fold it into the EWMA baseline
   (`Baselines.update(value: nil)` = skip-and-hold already exists for this).

---

## 5. Validation plan

### 5.1 Public datasets

| Dataset | What it gives for RHR | Access | Size | Fits |
|---|---|---|---|---|
| **PhysioNet `sleep-accel`** (Walch 2019, D1) | Apple Watch PPG HR (bpm) + 3-axis accel + PSG labels, 31 subjects, one lab night each; HR is PPG-derived, no ECG | open, ODC-By 1.0 | 550 MB zip / 2.2 GB | Measures how the **window** (PSG lights-off/on vs NOOP's HR-only detection) moves each statistic (nadir, lower-quartile mean, session mean). Already wired in `Tools/SleepPSG`. |
| **PhysioNet DREAMT 2.1.0** (D2) | Empatica E4 wrist BVP 64 Hz, HR 1 Hz, ACC 32 Hz, TEMP, EDA **plus** PSG with ECG at 100 Hz, 100 participants; 30-s stage labels | restricted: PhysioNet credentialed account + Restricted Health Data DUA 1.5.0 | not stated on page | Wrist PPG vs ECG **on the same night** for every candidate statistic; nadir timing vs stage. Caveat: mean age 56, BMI 33.7, 23 severe OSA — not the owner's population; report per-subject. |
| **NSRR MESA Sleep** (D3) | 2,237 unattended home PSG (ECG channel in EDF), 7-day actigraphy; 2,056 EDF files of ~160–250 MB each | NSRR data request, review "up to two weeks" | ~400 GB for all EDFs; sample 50–100 | Population distribution of nadir timing relative to sleep onset, gap between nadir and NREM mean, sensitivity of each statistic to ±30-min window shifts. Ages 45–84 at baseline. |
| **NSRR SHHS** (D4) | 5,804 adults ≥ 40, two PSG visits (1995–98, 2001–03) | NSRR data request | large | Same analyses; two visits years apart give no night-to-night CV. |

None of these gives night-to-night variability of a wearable RHR in a healthy young adult; that comes
only from the owner's own data (§5.3) or from the WHOOP 3.0 athlete study (S12).

### 5.2 Metrics to report (R4/R7)

- **Definition sensitivity**: for each statistic, bpm change per 10-min shift of the window start and
  end (signed), computed on PSG-bounded nights (D1–D3).
- **Agreement with ECG** (D2, owner H10): Bland–Altman bias and 95 % LoA, MAPE, Lin's CCC, per-night and
  per-subject — matching the statistic on both sides (nadir vs nadir, mean vs mean), never nadir vs mean.
- **Stability**: within-subject night-to-night SD and CV over ≥ 14 nights, ICC(2,1) across weeks, and the
  SWC = 0.2 × between-night SD (S19/S20) next to the typical error so the noise/signal ratio is explicit.
- **Rank agreement**: Spearman ρ between nightly values of the two statistics and between NOOP and the
  reference — because the downstream use is a z-score, rank is what matters.
- **Coverage effect**: bias of each statistic as a function of the winning bin's coverage fraction and of
  `hrOnly`.
- **Baseline behaviour**: days-to-usable, false-flag rate at |z| ≥ 1 and ≥ 2 on confounder-free nights,
  and lead/lag on logged perturbation nights.

### 5.3 Owner protocol — Polar H10 co-wear (≥ 28 nights, temporal split per R5)

1. **Reference**: Polar H10 on the chest, R-R logged by a phone app to CSV (any logger that writes
   RR + timestamps; the H10 is validated as an RR reference, S17/S18). Clock-sync the phone and the Mac
   once per night (write the phone's UTC time into the sleep diary).
2. **Diary** (one line per night): lights-off, final wake, alcohol units, evening training end time,
   illness notes. Needed for the window-error and confounder analyses; never committed.
3. **Keep NOOP untouched**: run the shipped pipeline; export `dailyMetric.restingHr`, the `rhr bins`
   lines, `rhr_primary_session`, the session bounds and `hrOnly` flag per night via the existing
   strap-log / `.noopbak` paths (no new app code needed for the measurement).
4. **Compute from the H10 stream** (script in a git-ignored folder, outputs in `research-data/`): HR at
   1 Hz from RR, then the same statistics NOOP computes — gated 5-min tumbling nadir, 5-min sliding nadir,
   lower-quartile mean of 5-min bins, whole-window mean — over (a) NOOP's session bounds and (b) the diary
   bounds. (a) vs (b) isolates window error; NOOP vs H10 under (a) isolates sensor/aggregation error.
5. **Split**: nights 1–14 for looking (plots, choosing the coverage gate), nights 15–28+ untouched until
   the report; report both halves and the gap. Include at least 3 nights with a logged evening confounder
   in each half.
6. **Report** in `docs/research/results/02-resting-hr.md` with the regenerating command (R3) and the
   constant predictor ("yesterday's value") as the floor for rank agreement.

A fingertip oximeter is not useful here; a second strap or ring is optional and only tells you about
agreement between black boxes.

---

## 6. Implementation sketch

Scope: pure helpers under `Packages/StrandAnalytics` with Kotlin twins; no BLE, no schema change beyond
one additive `metricSeries` key per new statistic. Headline definition unchanged until §5 reports.

### 6.1 Algorithm (both platforms, byte-identical)

```
INPUT  samples: [(ts: Int, bpm: Int, filler: Bool)]  sorted by ts, within [start, end]
       expectedHz = 1.0            // R18 cadence; a parameter so 30-s live HR is handled
       binS = 300, minBpm = 25, maxBpm = 220
       minCoverage = 0.60          // replaces the fixed 5-sample count
       fillerMaxShare = 0.50       // a bin mostly made of ppgHr filler cannot win

STEP 1 minute medians
       for each minute m in [start, end): med[m] = median(bpm of samples in m, minBpm...maxBpm)
       cov[m]  = count(samples in m) / (60 * expectedHz), clamped to 1
       fill[m] = count(filler in m) / max(1, count(samples in m))
       (median per minute kills single-sample spikes before any window sees them)

STEP 2 sliding 5-minute windows over minutes (step 1 min)
       for w in 0 ..< nMinutes - 4:
           mins = m[w ..< w+5] with med defined
           if mins.count < 5: continue
           coverage = mean(cov[mins]); fillerShare = mean(fill[mins])
           mean5 = mean(med[mins])
           qualifies = coverage >= minCoverage && fillerShare <= fillerMaxShare && mean5 >= minBpm
           windows.append((startMin: w, mean5, qualifies))

STEP 3 statistics (all emitted; only `nadir` is the headline today)
       nadir        = round(min(mean5 over qualifying windows))           // headline, same family as today
       nadirStartTs = ts of that window                                   // for the "when" diagnostic
       lowerQuartile= round(mean(lowest 25% of qualifying mean5))         // robust nadir candidate
       sessionMean  = round(mean(med[m] over minutes with cov[m] > 0))    // the #1169 statistic, minute-weighted
       coverage     = qualifying windows / total windows
       fallback: if no window qualifies → lowest ungated window → all-sample mean (preserve never-nil)

OUTPUT (nadir, lowerQuartile, sessionMean, nadirStartTs, coverage, usedFallback)
```

Differences from today, each deliberate: (1) sliding instead of tumbling windows (grid-independent
nadir); (2) minute medians before averaging (artefact robustness without a motion signal); (3) a coverage
*fraction* gate instead of a 5-sample count; (4) a filler-share gate so `ppgHrSample` can fill a gap but
not set the floor; (5) three named statistics stored side by side so the §5 comparison runs on real
nights without re-scoring history.

### 6.2 Where it lands

- `SleepStager.sessionRestingHR` keeps its signature and returns `nadir` (so every caller, the daily
  row, HealthKit and the baseline are untouched); a new `SleepStager.sessionRestingHRProfile` returns the
  full tuple; `AnalyticsEngine.analyzeDay` writes `rhr_nadir_start`, `rhr_lower_quartile`,
  `rhr_session_mean`, `rhr_coverage` to `metricSeries` (additive; no migration if `metricSeries` is
  key-typed, otherwise one additive migration with a test).
- `rhrBinGateLogLine` (#1943) is rewritten to the new gate and must still report when the gate moved the
  floor (the "don't let a path go quiet" rule).
- Kotlin: same two functions in `SleepStager.kt`; `AnalyticsEngine.kt` twin.
- Baseline: no change now. Separately (own PR): seed-mismatch guard in `ChargeBaselines` — if the seed
  came from an import and the first 7 computed nights sit > 2·spread below it, re-seed from the computed
  nights (R5-style: report the offset, do not apply it silently).
- `ReadinessEngine.swift` L13–14: replace the Lamberts 2004 attribution with Buchheit 2014 (S1), which
  is the source that actually makes the claim. Doc-only.

### 6.3 Parity oracle

Extract the pure helper into a standalone Swift file; `swiftc -O rhr.swift main.swift -o t && ./t` over:
a constant stream; a stream with a 1-s spike inside the nadir; a 40 % random-dropout stream (seeded
LCG, same seed both sides); a 30-s cadence stream (`expectedHz 1/30`); a stream whose lowest window
straddles a tumbling-grid boundary; a filler-majority dip; and an empty session. Paste the stdout
verbatim as the Kotlin test's expected literal (`AGENTS.md` parity rule). Note that `median` of an even
count and `round` of `.5` must be specified identically (banker's vs half-up) — pick half-up away from
zero on both sides and test it, since `Int(m.rounded())` in Swift and `roundToInt()` in Kotlin differ at
exactly .5.

### 6.4 Effort and risk

| Item | Effort | Risk |
|---|---|---|
| §6.1 helper + three stored statistics + oracle test, both platforms | **M** | Low for users (headline value changes only on nights the gate or grid previously mis-set; `rhrBinGateLogLine` reports each). Medium for parity (new rounding/median seams). |
| HR-only guard band + band-state veto (§4) | **S** on top | Low; 5.0-only inputs; must not touch BLE. |
| Baseline seed-mismatch guard | **S** | Medium: touches Charge for imported-history wearers; needs its own before/after on real history. |
| Promoting `lowerQuartile` or `sessionMean` to the headline | **S** code, **L** evidence | High until §5.3 holdout exists; every consumer in §1.2 moves (#2522 measured Effort −4.3 pts/day and Fitness Age +5 y for a +10 bpm shift). |
| Citation repair in `ReadinessEngine` | **S** | None. |

---

## 7. Sources (verified this session)

Peer-reviewed (fetched via Europe PMC REST records or PMC full text unless stated):

- **S1** Buchheit M. *Monitoring training status with HR measures: do all roads lead to Rome?* Front
  Physiol 2014;5:73. DOI 10.3389/fphys.2014.00073. Full text fetched (frontiersin.org). Verified: Table 1
  resting HR CV ≈ 10 %, SWC ≈ −2 %, signal-to-noise 0.7 vs 0.8 for vagal HRV; morning 5–10 min supine/seated
  measures as field practice; night recordings "theoretically best standardized" but noisy to implement;
  correlations appear only when ≥ 3–4 days are averaged.
- **S2** Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. *Training adaptation and heart rate
  variability in elite endurance athletes: opening the door to effective monitoring.* Sports Med
  2013;43(9):773–81. DOI 10.1007/s40279-013-0071-8, PMID 23852425. Abstract: "appropriate averaging
  techniques", HRV saturation when RHR falls; the 7-day-average specifics are in the paywalled full text
  (not fetched).
- **S3** Lamberts RP, Lemmink KAPM, Durandt JJ, Lambert MI. *Variation in heart rate during submaximal
  exercise: implications for monitoring training.* J Strength Cond Res 2004;18(3):641–5. PMID 15320683.
  Verified: 44 subjects, 5 consecutive days, submaximal running; ICC 0.94–0.99; CV 1.1–1.4 % at ~90 %
  HRmax; **no resting HR result in the abstract**.
- **S4** Radin JM, Wineinger NE, Topol EJ, Steinhubl SR. *Harnessing wearable device data to improve
  state-level real-time surveillance of influenza-like illness in the USA.* Lancet Digit Health
  2020;2(2):e85–93. DOI 10.1016/S2589-7500(19)30222-5, PMID 33334565, PMCID PMC8048388. Abstract
  verified: 47,249 Fitbit users in 5 states, > 13.3 M RHR + sleep measures, weekly fraction with elevated
  RHR and longer sleep; Pearson +0.12 (SD 0.07), final r 0.84–0.97. Full text (threshold definition)
  not reachable — see §8.
- **S5** Quer G, Radin JM, Gadaleta M, et al. *Wearable sensor data and self-reported symptoms for
  COVID-19 detection.* Nat Med 2021;27(1):73–7. DOI 10.1038/s41591-020-1123-x, PMID 33122860. Abstract:
  30,529 enrolled, 54 positive / 279 negative among symptomatic; AUC 0.80 (0.73–0.86) sensor + symptoms
  vs 0.71 (0.63–0.79) symptoms alone.
- **S6** Mishra T, Wang M, Metwally AA, et al. *Pre-symptomatic detection of COVID-19 from smartwatch
  data.* Nat Biomed Eng 2020;4(12):1208–20. DOI 10.1038/s41551-020-00640-6, PMID 33208926, PMCID
  PMC9020268. Full text fetched (PMC): 28-day sliding baseline; RHR at 15-s resolution, 0 steps in the
  prior 12 min (RHR-AD); 30–200 bpm outlier cut; CuSum threshold half the 90 %/99 % baseline-residual
  quantile; alarm p < 0.01, red after 24 h; 26/32 altered, 22/25 before/at onset; median lead 4 d
  (symptoms) / 7 d (diagnosis); online CuSum 15/24 on or before onset.
- **S7** Natarajan A, Su HW, Heneghan C. *Assessment of physiological signs associated with COVID-19
  measured using wearable devices.* npj Digit Med 2020;3:156. DOI 10.1038/s41746-020-00363-7, PMID
  33299095, PMCID PMC7705652. Full text fetched: 2,745 PCR-confirmed; sleeping HR = "mean nocturnal heart
  rate during NREM sleep"; rolling mean/SD z-score (window not stated); AUC 0.77 ± 0.018 for physiology.
- **S8** Bent B, Goldstein BA, Kibbe WA, Dunn JP. *Investigating sources of inaccuracy in wearable
  optical heart rate sensors.* npj Digit Med 2020;3:18. DOI 10.1038/s41746-020-0226-6, PMID 32047863,
  PMCID PMC7010823. Abstract: activity error ≈ 30 % higher than at rest; no significant skin-tone
  difference; device and activity-type differences significant. (n and per-device MAE are in the full
  text, not fetched.)
- **S9** Speed C, Arneil T, Harle R, et al. *Measure by measure: Resting heart rate across the 24-hour
  cycle.* PLOS Digit Health 2023;2(4):e0000236. DOI 10.1371/journal.pdig.0000236, PMID 37115739, PMCID
  PMC10146540. Full text fetched: 433 adults, Fitbit Charge 4, 1-min HR; inactivity = MET < 1.5; HR
  stabilised after 4 min; night nadir 50.5 ± 7.6 vs day 54.5 ± 8.0 bpm, Δ 3.9 ± 3.8; 53 % of minima
  03:00–07:00; no within-person CV reported.
- **S10** Dial MB, Hollander ME, Vatne EA, Emerson AM, Edwards NA, Hagen JA. *Validation of nocturnal
  resting heart rate and heart rate variability in consumer wearables.* Physiol Rep 2025;13(16):e70527.
  DOI 10.14814/phy2.70527, PMID 40834291, PMCID PMC12367097. Full text fetched: 13 adults, 536 nights,
  Polar H10 reference averaged over the whole night; per-device bias/LoA/MAPE/CCC as tabulated in §2.3;
  Garmin excluded because its lowest-30-min window cannot be time-located; vendor definitions quoted
  from vendor documentation (Garmin lowest 30-min average in 24 h; Polar first 4 h; WHOOP "dynamic
  average during sleep … weighted towards your last slow wave sleep stage"; Oura 10-min segments).
- **S11** Bellenger CR, Miller DJ, Halson SL, Roach GD, Sargent C. *Wrist-based photoplethysmography
  assessment of heart rate and heart rate variability: validation of WHOOP.* Sensors 2021;21(10):3571.
  DOI 10.3390/s21103571, PMID 34065516, PMCID PMC8160717. Full text fetched: 6 adults, overnight,
  final 5 min of the final SWS episode; HR bias ≤ 0.39 ± 0.38 %, LoA ≤ 1.56 %; HR CV 10–11 %, SWC 5–5.5 %;
  "WHOOP quantify HR and HRV in the final SWS episode of each sleep opportunity."
- **S12** Bellenger CR, Miller D, Halson SL, Roach GD, Maclennan M, Sargent C. *Evaluating the typical
  day-to-day variability of WHOOP-derived heart rate variability in Olympic water polo athletes.* Sensors
  2022;22(18):6723. DOI 10.3390/s22186723, PMID 36146073. Abstract: 11 elite males, 16 weeks, WHOOP 3.0;
  mean weekly CV nocturnal HR 7.6 ± 1.3 %, lnRMSSD 5.4 ± 0.7 %.
- **S13** Miller DJ, Sargent C, Roach GD. *A validation of six wearable devices for estimating sleep,
  heart rate and heart rate variability in healthy adults.* Sensors 2022;22(16):6317. DOI
  10.3390/s22166317, PMID 36016077, PMCID PMC9412437. Full text fetched: 53 adults, one lab night, ECG;
  HR bias/LoA per device as in §2.3 (WHOOP 3.0 −0.3 ± 1.9 bpm from a researcher-computed sleep-period
  mean); internal LoA inconsistencies for Somfit and Garmin noted in the text.
- **S14** Grosicki GJ, Carter JR, Laursen PB, Plews DJ, Altini M, et al. *Heart rate variability
  coefficient of variation during sleep as a digital biomarker that reflects behavior and varies by age
  and sex.* Am J Physiol Heart Circ Physiol 2026;330(1):H187–99. DOI 10.1152/ajpheart.00738.2025, PMID
  41309064. Abstract: ~2 M nocturnal HRV readings, > 21,000 users; ≥ 5 of 7 nights needed for ICC ≥ 0.80
  weekly CV; higher CV with alcohol, low activity, short/irregular sleep.
- **S15** Kinnunen H, Rantanen A, Kenttä T, Koskimäki H. *Feasible assessment of recovery and
  cardiovascular health: accuracy of nocturnal HR and HRV assessed via ring PPG in comparison to medical
  grade ECG.* Physiol Meas 2020;41(4):04NT01. DOI 10.1088/1361-6579/ab840a, PMID 32217820. Abstract: 49
  adults; nightly average HR r² 0.996, bias −0.63 bpm; 5-min segments r² 0.869 ± 0.098.
- **S16** Nelson BW, Allen NB. *Accuracy of consumer wearable heart rate measurement during an
  ecologically valid 24-hour period.* JMIR mHealth uHealth 2019;7(3):e10828. DOI 10.2196/10828, PMID
  30855232. Abstract: n=1, ambulatory ECG; Apple Watch 3 mean diff −1.80 bpm (MAPE 5.86 %), Fitbit
  Charge 2 −3.47 bpm (5.96 %); no sleep-specific figures in the abstract.
- **S17** Gilgen-Ammann R, Schweizer T, Wyss T. *RR interval signal quality of a heart rate monitor and
  an ECG Holter at rest and during exercise.* Eur J Appl Physiol 2019;119(7):1525–32. DOI
  10.1007/s00421-019-04142-5, PMID 31004219. Abstract: 10 adults; Polar H10 99.6 % correct RR (99.4 % at
  high intensity) vs Holter 94.6 %; r 0.997.
- **S18** Schaffarczyk M, Rogers B, Reer R, Gronwald T. *Validity of the Polar H10 sensor for heart rate
  variability analysis during resting state and incremental exercise in recreational men and women.*
  Sensors 2022;22(17):6536. DOI 10.3390/s22176536, PMID 36081005. Abstract: 25 adults; resting ICC(3,1)
  0.95 pre / 0.85 post; RR bias 0.4–0.7 ms, LoA −2.8…4.3 ms at low intensity.
- **S19** Hopkins WG. *Measures of reliability in sports medicine and science.* Sports Med
  2000;30(1):1–15. DOI 10.2165/00007256-200030010-00001, PMID 10907753. Abstract: typical error as the
  within-subject SD, best expressed as a CV.
- **S20** Hopkins WG. *How to interpret changes in an athletic performance test.* Sportscience 2004;8:1–7
  (sportsci.org/jour/04/wghtests.htm, fetched). Verified: SWC default = 0.2 × between-subject SD
  (Cohen 0.2); for elite individuals 0.3 × competition-to-competition variation; noise expressed as typical
  error from a reliability study.
- **S21** Trinder J, Kleiman J, Carrington M, et al. *Autonomic activity during human sleep as a function
  of time and sleep stage.* J Sleep Res 2001;10(4):253–64. DOI 10.1046/j.1365-2869.2001.00263.x, PMID
  11903855. Abstract: 14 adults, 3 nights; HR shows a time-of-night effect attributed to circadian
  influence; BP/HF/LF constant within stage, so their change reflects stage mix; NREM parasympathetic,
  REM wake-like.
- **S22** Kontos A, Baumert M, Lushington K, et al. *The inconsistent nature of heart rate variability
  during sleep in normal children and adolescents.* Front Cardiovasc Med 2020;7:19. DOI
  10.3389/fcvm.2020.00019. Full text fetched: mean NN longest in SWS3 (~02:40), ~7 bpm below adjacent
  REM; HR slower in NREM, especially N3; children/adolescents, so magnitudes do not transfer to adults.
- **S23** Burgess HJ, Trinder J, Kim Y, Luke D. *Sleep and circadian influences on cardiac autonomic
  nervous system activity.* Am J Physiol 1997;273(4):H1761–8. DOI 10.1152/ajpheart.1997.273.4.H1761,
  PMID 9362241. Abstract: 12 subjects, two 26-h constant routines; parasympathetic rhythm circadian,
  sympathetic rhythm sleep-dependent; no HR numbers in the abstract.
- **S24** Myllymäki T, Kyröläinen H, Savolainen K, et al. *Effects of vigorous late-night exercise on
  sleep quality and cardiac autonomic activity.* J Sleep Res 2011;20(1 Pt 2):146–53. DOI
  10.1111/j.1365-2869.2010.00874.x, PMID 20673290. Abstract: 11 fit adults; exercise ended 2:13 ± 0:19 h
  before bed; night HR 54 ± 7 vs 51 ± 7 (p < 0.01), most in the first 3 h; no whole-night HRV change.
- **S25** Pietilä J, Helander E, Korhonen I, Myllymäki T, Kujala UM, Lindholm H. *Acute effect of
  alcohol intake on cardiovascular autonomic regulation during the first hours of sleep in a large
  real-world sample of Finnish employees.* JMIR Ment Health 2018;5(1):e23. DOI 10.2196/mental.9519, PMID
  29549064. Abstract: 4,098 employees, beat-to-beat R-R; dose-dependent sympathetic shift from low intake;
  HRV recovery index −9.3 / −24.0 / −39.2 points by dose; no HR-bpm figure in the abstract.
- **S26** Altini M, Plews D. *What is behind changes in resting heart rate and heart rate variability? A
  large-scale analysis of longitudinal measurements acquired in free-living.* Sensors 2021;21(23):7932.
  DOI 10.3390/s21237932, PMID 34883936, PMCID PMC8659706. Abstract: 28,175 individuals, ~9 M
  **morning** app measurements; HR associated with sex (d 0.63) and activity (r 0.30), not age; training
  response 1.3 % HR vs 4.6 % HRV.
- **S27** Li X, Dunn J, Salins D, et al. *Digital health: tracking physiomes and activity using wearable
  biosensors reveals useful health-related information.* PLoS Biol 2017;15(1):e2001402. DOI
  10.1371/journal.pbio.2001402, PMID 28081144. Abstract only; the RHR method Mishra (S6) defers to lives
  in its full text (not fetched).
- **S28** Nelson BW, Low CA, Jacobson N, Areán P, Torous J, Allen NB. *Guidelines for wrist-worn consumer
  wearable assessment of heart rate in biobehavioral research.* npj Digit Med 2020;3:90. DOI
  10.1038/s41746-020-0297-4, PMID 32613085. Abstract: reporting checklist (device, firmware, sampling,
  processing); no accuracy numbers.

Datasets (pages fetched):

- **D1** Walch O. *Motion and heart rate from a wrist-worn wearable and labeled sleep from
  polysomnography* v1.0.0, PhysioNet. DOI 10.13026/hmhs-py35. ODC-By 1.0, open; 31 subjects; 550 MB zip.
- **D2** Wang K, Yang J, Shetty A, Dunn J. *DREAMT* v2.1.0, PhysioNet. DOI 10.13026/7r9r-7r24.
  Restricted Health Data License/DUA 1.5.0; 100 participants; E4 BVP 64 Hz, HR 1 Hz, ACC 32 Hz; PSG
  incl. ECG at 100 Hz; 30-s stages.
- **D3** NSRR *Multi-Ethnic Study of Atherosclerosis (MESA) Sleep* — sleepdata.org/datasets/mesa
  (fetched with curl, certificate not verifiable from this host). 2,237 PSG + 7-day actigraphy; 2,056
  EDFs ~160–250 MB; data request reviewed "up to two weeks".
- **D4** NSRR *Sleep Heart Health Study* — sleepdata.org/datasets/shhs (same). 5,804 adults ≥ 40; visit 1
  1995–98, visit 2 (n=3,295) 2001–03.

Vendor documentation (not peer review; fetched):

- **V1** Oura, *What Is a Good Resting Heart Rate?* ouraring.com/blog (fetched 2026-11-10): defines
  lowest and average; alcohol / late exercise mentions were not on the fetched page.
- **V2** Oura Help, article 360025588793 (support.ouraring.com, fetched): "Your average RHR captured
  during the night" / "Your lowest RHR value captured during the night"; "captured every 10 minutes";
  "Variation beyond 3-5 BPM above or below your personal average" as the watch band; the "hammock"
  (minimum in the first half of the night) as the ideal.
- **V3** Fitbit Help, *How do I track heart rate with my Fitbit device?* support.google.com/fitbit/answer/14237938
  (fetched): RHR "when you're still and well-rested", "estimated each day"; sleeping HR "detected
  continuously throughout the night" and "often lower than your resting heart rate".
- **V4** Apple Health app text as reproduced by leancrew.com (2026-01, fetched; **secondary**): "average
  heart beats per minute measured when you've been inactive or relaxed for several minutes" and "does
  not include your heart rate while you're asleep". Apple's own support page support.apple.com/en-us/120277
  was fetched and lists the resting view but gives no definition.
- **V5** Altini M, *Resting heart rate and wearables* (marcoaltini.substack.com, fetched; **secondary
  commentary**): Oura lowest; Garmin lowest 30-min in 24 h; WHOOP night average weighted to deep sleep;
  Apple samples while not moving; Fitbit average of non-movement periods; author prefers a morning
  reading, then a night *average*, and argues the minimum is artefact-prone with variable timing.
- **WHOOP** definitions are taken from S10 and S11, which quote WHOOP's documentation; WHOOP's own
  pages returned 403/401 — see §8.

Repository evidence (read this session): issues/PRs #1169, #1943, #2284, #2358, #2522 (api.github.com),
`docs/VALIDATION_PROTOCOL.md`, `docs/research/00-inventory.md`, the Swift and Kotlin sources named in §1.

---

## 8. Unverified leads

- **WHOOP support article** *WHOOP Recovery* (support.whoop.com/hc/en-us/articles/360019453454) —
  search snippet reads "Resting Heart Rate (RHR) … captured during your last period of Slow Wave Sleep
  each night"; the page itself returned 401/403 and a CSS-error shell. WHOOP Locker articles also 403.
  Use S10/S11's quotations instead.
- **Radin 2020 full text** (PMC8048388): the "elevated RHR" threshold and the per-user baseline window.
  Europe PMC render returned HTTP 500 on three attempts; Lancet site 403.
- **Garmin's own documentation** of "lowest 30-minute average in a 24-hour period": only forum quotations
  and S10's citation were reachable; no garmin.com page was fetched.
- **Fitbit's RHR algorithm** (which awake periods, which averaging): V3 confirms inputs are day + sleep
  and the value is daily; the formula is unpublished.
- **Plews 2013 full text** (7-day rolling average, 0.5 × CV SWC band as used by `HRVReadiness`): behind a
  paywall; only the abstract was verified.
- **Bent 2020 full text**: per-device MAE at rest and the n (the abstract was verified).
- **Speed 2023 / Quer 2020 "lowest HR of the day irrespective of activity"** definition chain: S9 cites a
  Quer 2020 definition that was not fetched separately.
- **A head-to-head of nadir vs mean as a predictor** (illness lead time, next-day performance): no such
  paper surfaced in this session's searches; its absence is itself a finding and the reason §5.3 exists.
- **Altini's ECG comparison of Oura/WHOOP/Garmin over three months** (referenced in V5): not fetched.

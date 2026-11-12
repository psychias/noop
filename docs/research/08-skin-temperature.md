# 08 — Skin temperature

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`, after
`docs/research/00-inventory.md`. Every source in §7 was fetched this session (Europe PMC REST,
PMC, publisher or vendor page); anything not fetched is in §8. Wording follows the repository's
binding framing (`CyclePhaseEngine.swift` header, `docs/SCOPE.md`): wellness / awareness only,
approximate, not a diagnosis, not a fertility or contraception claim, never a confident single date.

Claims about NOOP's code are CONFIRMED by reading the source on this date unless marked INFERRED.
Claims about the literature carry the numbers the fetched abstract or full text reported.

---

## 1. What NOOP does today

### 1.1 Decode and storage

| Item | Swift | Kotlin |
|---|---|---|
| Raw → °C | `WhoopProtocol.skinTempCelsius(raw:family:anchorRaw:)` (`Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift` ~L245). `.whoop5` = `raw / 100.0` (R18 byte 73, u16 centidegrees, decode gate 5–45 °C). `.whoop4` = provisional per-device anchor (826 raw → 33.0 °C, slope 0.05 °C/raw, `Whoop4SkinTemp`). | `Whoop4SkinTemp` twin (per Streams.swift comment "kept in lockstep"). |
| Sample struct | `SkinTempSample(ts, raw, unit, aux1Raw?, aux2Raw?)` — `aux1Raw`/`aux2Raw` are R18 bytes 69/71, signed i16, `°C = value/10`, decode gate 0–60 °C. | — |
| Table | `skinTempSample(deviceId, ts, raw, aux1Raw, aux2Raw)` (v31 added the aux columns, additive nullable). `Database.swift` v31 note: the aux channels "track the primary closely (corr ~0.92 / ~0.97) with the same diurnal curve"; "INSTRUMENTATION ONLY. Nothing reads these columns: no analytic, no score, no gate, no UI." | Room twin (not re-read here; INFERRED from the inventory). |
| Resolution | 1 Hz when the strap banks v18; 0.01 °C quantisation on the 5.0 primary, 0.1 °C on the aux channels. Sensor accuracy is **unknown** — no calibration against a reference thermometer exists in the tree. | — |

### 1.2 Nightly value

`AnalyticsEngine.wornNightlySkinTempC(sessions, hr, skinTemp, family, anchorRaw, minSamples,
wornToleranceSec)` is a thin wrapper over `skinTempFunnel(...)` (`AnalyticsEngine.swift`
~L1352 / ~L1627) and returns `.mean`. Gates, in order, each sample attributed to the first that
drops it:

1. **Worn** — a valid HR sample (30–220 bpm) exists at the **same second** (`wornToleranceSec = 0`
   for every WHOOP caller; `defaultOuraWornToleranceSec = 5` exists for the ring, #1467).
2. **In window** — inside any detected in-bed `SleepSession` span `[start, end]`.
3. **In range** — `skinTempMinC = 28.0 … skinTempMaxC = 42.0` (°C; WHOOP 4.0 also a raw ADC band).
4. `kept >= minSkinTempSamples` (**300**, "~5 min at 1 Hz") → `mean = sum / kept`, else nil.

So the nightly value is the **arithmetic mean of every worn, in-bed, in-range second**, with no
trimming of the sleep-onset ramp or the pre-wake decline, no smoothing, no percentile, no
time-of-night weighting and no use of the aux channels. The funnel diagnostic (#752) counts the
drops so an absent night is self-explaining.

### 1.3 Deviation and baseline

- `skinTempDevC = round2(Baselines.deviation(nightlyMean, state: baselines.skinTemp).delta)`
  (`AnalyticsEngine.swift` ~L907–913), i.e. **nightly mean − personal EWMA centre**, 0.01 °C
  precision. Two-pass: pass 1 harvests the mean, `IntelligenceEngine` seeds the baseline, pass 2
  re-derives the deviation (same shape as avgHrv → recovery).
- `Baselines.metricCfg["skin_temp"] = MetricCfg(minVal 20, maxVal 42, floorSpread 0.3, halfLifeB 14,
  halfLifeS 21)`; Winsor `k = 3`; `minNightsSeed 4`; `minNightsTrust 14`; `staleDays 14`;
  `sigma = 1.253 × EWMA|dev|` floored at 0.3 °C → `z = delta / sigma`.
- Stored: `dailyMetric.skinTempDevC` (v7) and `dailyMetric.skinTempC` (absolute, v40).
  The `skinTempDevC` column is **bimodal**: CSV/Health imports write absolute °C, the live pipeline a
  signed deviation; `VitalBands.isAbsoluteSkinTemp(v) = v >= 20` and `SkinTempDisplay` tell them
  apart; `VitalBands.skinTempDeviationCfg` (±8 °C, floor 0.3) is the deviation-domain config.

### 1.4 Consumers (four, with three different conventions)

| Consumer | How skin temp enters | Convention |
|---|---|---|
| `RecoveryScorer.recovery(... skinTempDev:)` | term `−|dev| / skinTempScaleC (1.0 °C)`, weight `wSkinTemp = 0.05`; nil drops the term and renormalises. | **Symmetric penalty** in °C, no baseline spread. |
| `RecoveryScorer.skinTempRelative` (`ChargeDrivers.swift`) | tier `warmer / typical / cooler` at `±skinTempTypicalBandC = 0.3 °C`. | Fixed band in °C. |
| `IllnessSignalEngine` | `skinTemp: SignalReading(zIllnessward:)`, fires at `signalZThreshold = 2.0`, needs `minCorroboratingSignals = 2`, `confounderDampen = 0.45` (alcohol / stress / sauna / late-intense workout / travel / circadian jump). iOS `AppModel.swift` ~L2226 builds `tempZ = Baselines.deviation(dev, skinState).z` when the baseline is usable, **else `dev / 0.3`**. Android `V5HealthSignals.kt` builds it as a **30-night trailing mean/SD z** (`BASELINE_WINDOW 30`, `MIN_BASELINE_NIGHTS 14`). | **One-sided z** (↑ only); z definition differs by platform. |
| `CyclePhaseEngine` | fused index `0.6·zTemp + 0.2·zRHR + 0.2·(−zHRV)`; "elevated" when ≥ `elevationK 0.5` MADs above the series mean; cycle length clamp 21–40, default 28; `minNightsToClassify 42`; `periOvulatoryHalfWidth 2`; cites "PMC11294004". | z of a deviation that is itself computed against a cycle-following EWMA (see §3). |
| `CircadianEngine` | `observedTempMinHour` parameter exists, "NO production caller supplies one today"; the temperature minimum is derived from the activity cosinor (`acrophase − 12 h`). | Unused for temperature. |

### 1.5 Export

- iOS `StrandiOS/Health/HealthKitBridge.swift` ~L140–152: `writeDenied = [.appleSleepingWristTemperature]`
  (#1366 — asking to *share* that type raised an uncatchable `NSInvalidArgumentException` on launch);
  `.bodyTemperature` is **read** only. Skin temperature is therefore **not written** to Apple Health.
- Android `HealthConnectWriter.kt`: no `SkinTemperatureRecord` (grep returns nothing).
- `Strand/Collect/Collector.swift` L161 exports `skin_temp_raw,ts,raw,aux1,aux2` to the raw CSV.

### 1.6 Tests and cited sources

`SkinTempAnalyticsTests`, `SkinTempDisplayTests`, `CyclePhaseEngineTests`, `CircadianEngineTests`,
`IllnessSignalEngineTests`, `IllnessDistanceTests`, `VitalBands*`; Kotlin twins. Sources cited in
code: "PMC11294004" (`CyclePhaseEngine`) — verified below as Gombert-Labedens et al. 2024, *J Biol
Rhythms* (Oura Gen2 cosinor cycle characterisation, **not** a wrist-temperature paper); "the
Stanford/Snyder resting-HR-elevation work" (`IllnessSignalEngine`) — Mishra et al. 2020, which uses
**no temperature** at all.

---

## 2. Recommended method(s) from the literature

### 2.1 Which nightly statistic validated studies actually used

No validated study used an untrimmed whole-night mean. Each one trimmed the sleep-onset ramp and/or
took a **stable maximum / high percentile** of a smoothed series:

| Study (device, site, rate) | Nightly statistic | Reference & result |
|---|---|---|
| Shilaih 2018 (Ava, dorsal wrist, 1/10 s; 136 women, 437 cycles) | Drop first **90 min** and last **30 min** of the night; LOESS; **99th percentile** ("stable maxima"), chosen over p10/p50/p90. | Home LH. Sustained shift (≥ 0.2 °C above ≥ 5 of the previous 6 nights, for 3 nights — the "three-over-six" rule) found in 357/437 cycles (82 %); 86 % of shifts on/after ovulation day; mean shift 0.33 °C. Alcohol ≥ 5 units, large meal, sex, BMI gave small WST differences; ambient not reported. |
| Zhu 2021 (Ava, wrist; 57 women, 193 cycles) | Same preprocessing as Shilaih. | Home LH, day after surge = ovulation. WST sensitivity **0.62** (0.55–0.70) vs oral BBT 0.23; specificity **0.26** (0.10–0.48) vs 0.70; PPV 0.86 vs 0.85. Post-ovulatory rise ≈ **0.50 °C** WST vs 0.20 °C BBT; follicular→luteal 0.29 vs 0.26 °C. Ambient not mentioned; alcohol, sleep, exercise, meals **not evaluated** (listed as limitations). |
| Goodale 2019 (Ava, wrist; 237 women, 708 cycles) | Same trimming; LOESS; **50th percentile**. | Phase means: menses 34.11, follicular 33.87, fertile 33.88, late luteal **34.32 °C** (≈ +0.45 °C follicular→late luteal); HR 56.6 → 60.5 bpm; RR 16.6 → 17.0. Fertile-window model: sensitivity 0.81 (0.77–0.85), specificity 0.93 (0.92–0.94), 90 % of cycles. Vendor-authored. |
| Maijala 2019 (Oura, finger, 1/min; 22 women, ~115 d) | 22:00–08:00; **17-min moving average**; "stable" if inputs fluctuate < 1 °C; **highest stable value** = night's value; missing if none. Cycle component by 2nd-order Butterworth low-pass, cutoff 1.5/28 cycles·day⁻¹; rules anchored on the filtered minima (e.g. `RISE_0.15` = +0.15 °C over MIN). | Urine LH + oral waking temp. Luteal − follicular **0.30 °C (SD 0.12)** skin vs 0.23 °C oral; skin–oral r = 0.563 (daily). Menstruation sensitivity 50.0 / 71.9 / 81.4 / 86.5 % at ±1/2/3/4 d; ovulation 83.3 % in −3…+2 d, ~95 % within ±4 d. Oura-affiliated authors. |
| Gombert-Labedens 2024 = **PMC11294004** (Oura Gen2, finger; 120 women incl. menopausal transition) | Oura-detected sleep only; 17-min moving average; segments with > 1 °C change in 17 min removed; **highest stable 17-min average**; scaled/centred; 3-day moving average; **cosinor** fit, period 22–36 d (22–45 d if > 35 y). | Luteal > follicular (p < 0.001); cosinor r² mean 0.56 ± 0.25; r² > 0.25 called "oscillatory" in 99/116; agreement with LH 82 % (111 participants). No °C effect size in text. |
| Alzueta 2022 (Oura, finger; 26 women) | Mean over a stable consolidated sleep period (Oura absolute values). | LH kits. Vs menses: ovulation −0.09 (CI touches 0), mid-luteal **+0.20**, late luteal **+0.24 °C**; HR +2.4 / +2.5 bpm. |
| Grant & Smarr 2022 (Oura, finger; 30 pregnancies) | **Median of the hottest 60 min** in 20:30–12:00; outliers removed; per-person scaled by night-minus-day range; features vs a **rolling 17-day** past window (min/median/max), centred on the personal median and scaled by MAD. | Feasibility only; alerts a median 9 d before a positive test. Uses nightly **max**, never mean. |
| Thigpen 2025 (Oura; 964 people, 1,155 cycles) | Oura's proprietary physiology method. | OPK reference. 96.4 % detected; MAE 1.26 d (vs 3.44 d calendar); worse in abnormally long cycles (1.7 d). Vendor-authored. |
| Mason 2022 = TemPredict (Oura; 63,153 enrolled; 73 train / 10 validation) | 1/min → **30-min windows** (mean, SD, p25, p75); trend = 3-day moving average of the **p75 during sleep**; **21-day personal baseline** (fallback: available nights within 49 d), z-scored. | COVID-19 PCR/antigen. AUC 0.819 (0.809–0.830); sensitivity 82 %, specificity 63 % (training); 90 % / 80 % (n = 10 validation); flagged a mean **2.75 d before** test-seeking; temperature lifted AUC 0.770 → 0.819; AUC 6.7 % lower in women. Ambient, alcohol and cycle **not addressed**. |
| Kasl 2024 (Oura; 724 fever days / 342,430 non-fever days) | Nightly temperature, HR, sleep, nights before and after each day; tree classifier. | Self-reported ≥ 38 °C. AUROC **0.85**, average precision 0.25; at sensitivity 0.50 the false-positive rate is **0.8 %**. |
| Smarr 2020 (Oura; first 50 TemPredict cases) | Personal baseline from weeks of data. | Illness-related peripheral temperature rises observable and correlated with self-reported fever; proof of concept, n = 50. |

Consumer conventions (vendor documentation, fetched): Apple samples the wrist **every 5 s** during
sleep with **two sensors (one under the display) "to reduce bias from the outside environment"**,
needs **~5 nights with ≥ 4 h of Sleep Focus** for a baseline, shows **relative changes from baseline**,
names diet, exercise, alcohol and sleep environment as nightly influences, and states the feature
"is not a thermometer". Oura shows the **average during sleep** as a ± deviation from a baseline
"calculated during the first couple of weeks" and adjusted over time, a 3-day weighted trend, and lets
temperature only **lower** readiness. Health Connect's `SkinTemperatureRecord` (androidx
`connect-client` 1.1.0) carries a list of `Delta`s plus an optional `baseline` (0–100 °C) and
`MEASUREMENT_LOCATION_WRIST = 3`, gated by `FEATURE_SKIN_TEMPERATURE`.

### 2.2 Physiology that constrains the window choice

- Distal skin temperature **rises ~1 °C around sleep onset** (proximal ~0.5 °C) as distal vessels
  dilate (Garcia-Molina 2024, 18 participants, lab + home); that heat loss is the best predictor of
  sleep-onset latency (Kräuchi 2000; Kräuchi 1999 "Warm feet promote the rapid onset of sleep").
  A whole-night mean therefore depends on **how long the ramp took and how long the night was**, not
  only on the plateau level the studies above measure.
- Wrist temperature runs **inverse to oral temperature and leads it by ~60 min**, rising at bedtime
  and dropping sharply after waking (Sarabia 2008, 99 students, iButton on the radial artery of the
  non-dominant wrist, 10-min sampling). The iButton literature places the logger "over the radial
  artery" under a cotton band to isolate it from ambient, and names placement and masking factors as
  the key methodological issues (Ortiz-Tudela 2010; Hasselberg 2013 review; Martinez-Nicolas 2013:
  sleep raises wrist temperature whenever it occurs).
- The luteal elevation is **+0.2 to +0.5 °C** (Maijala 0.30; Shilaih 0.33; Goodale ≈ 0.45 late
  luteal vs follicular; Alzueta 0.24; Zhu post-ovulatory 0.50). This is the same order as
  `Baselines` `floorSpread 0.3`, which matters for the illness gate (§3.7).

### 2.3 Recommended method for NOOP (each item is a hypothesis to validate, §5)

1. **Nightly statistic = trimmed, smoothed stable maximum**, kept alongside the mean:
   window `[sessionStart + 90 min, sessionEnd − 30 min]`; worn / in-range gates unchanged; 17-min
   (1,020 s) moving average on the 1 Hz grid without bridging gaps > 5 min; a window is "stable"
   when its inputs span < 1 °C; `skinTempMaxC` = highest stable value; also store `p50`, the mean,
   and **coverage** (kept seconds ÷ window seconds). This is the Maijala / Gombert-Labedens /
   Grant statistic, and the Shilaih p99 and Goodale p50 are the same family.
2. **Sampling floor by coverage, not a 300-sample count**: require ≥ 2 h of kept samples **and**
   coverage ≥ 50 % of the trimmed window, else nil — and expose coverage per R4 ("completeness is
   a property of the input").
3. **Two baselines for two questions**, resolved in ONE place per platform:
   - *Illness z*: a **lagged robust baseline** — median and MAD of nights −21…−7 (Miller 2020's
     WHOOP respiratory-rate model used exactly this lag; Mason 2022 used a 21-day baseline). The lag
     keeps the prodromal nights from pulling the baseline up under the event it is meant to catch.
     Floor the MAD-sigma at 0.1 °C (not 0.3; see §3.7).
   - *Cycle component*: do not z-score against an EWMA that follows the cycle; low-pass the
     calendar-padded nightly series (2nd-order Butterworth, cutoff 1.5/28 cycles·day⁻¹, Maijala) or
     fit a cosinor over 22–40 d periods (Gombert-Labedens) and hand the engine the **filtered
     elevation above the filtered minimum**.
4. **Ambient**: NOOP cannot do Apple's two-sensor compensation blind, but the 5.0 banks two aux
   thermal channels every second. Land a **read-only instrumentation** pass (nightly primary, aux1,
   aux2, and the two gradients) and correlate the gradients with a bedroom logger before any consumer.
5. **Export**: Android → `SkinTemperatureRecord(deltas: [nightly deviation], baseline: EWMA centre,
   measurementLocation: WRIST)`. iOS → nothing into HealthKit (type is read-only by Apple's own
   documentation; `.bodyTemperature` would mislabel a wrist reading as core temperature); offer the
   deviation on the Shortcuts file path instead.

---

## 3. Gap analysis

| # | NOOP today | Recommended | Impact | Why |
|---|---|---|---|---|
| 3.1 | Whole-night **mean** of worn in-bed seconds. | Trimmed stable-max (+ mean, p50, coverage). | **High** for cycle and illness sensitivity | Every validated study measured the plateau; the mean folds in the ~1 °C onset ramp and any pre-wake decline, so a short night or a slow onset reads "cooler" with no physiology behind it. The expected gain is a lower night-to-night SD on healthy nights (§5 metric M1), which directly raises z-scores for a given real shift. INFERRED, not measured. |
| 3.2 | No trimming of first 90 / last 30 min. | Trim relative to session bounds. | Medium | Shilaih/Zhu/Goodale trimming; on the 5.0 the session bounds come from HR-only detection, so use the stage-free in-bed span and keep the trim conservative. |
| 3.3 | `minSkinTempSamples = 300` (5 min). | ≥ 2 h kept and ≥ 50 % coverage. | **High** | 5 min of samples cannot carry a 17-min stable-max statistic, and today a night with 5 worn minutes becomes a baseline input with the same weight as a full night. |
| 3.4 | "Worn" = valid HR at the **same second**. | `wornToleranceSec > 0` for 5.0 nights with HR gaps, or a worn signal independent of HR. | Medium on 5.0 | 5.0 HR gaps on v26-heavy stretches (`00-inventory.md` §1) make every co-timed skin sample "not worn" and drop it, even though the strap was on. The funnel's `droppedNotWorn` count will show this per night. |
| 3.5 | One EWMA (half-life 14 / 21 nights) feeds illness, recovery and cycle. | Lagged median/MAD for illness; low-pass/cosinor for cycle. | Medium (illness), **High** (cycle) | A 14-night half-life tracks a 12–14-day luteal plateau, so `skinTempDevC` under-reads the elevation by roughly half of it mid-luteal (INFERRED from the half-life; measurable in §5). The cycle engine's MAD gate then works on an attenuated series. For illness, an unlagged baseline absorbs the prodrome it should flag. |
| 3.6 | Aux channels unread; no ambient handling. | Instrumentation pass → validated gradient. | Medium, unquantified | Apple's design uses a second sensor for this; the v31 note's corr 0.92/0.97 with the primary means the aux channels are *not* a clean ambient reference, so the useful quantity is the **gradient**, which needs a bedroom reference to interpret. |
| 3.7 | Conventions differ: Recovery symmetric −\|dev\|/1 °C; Illness one-sided z ≥ 2 vs EWMA sigma floored 0.3 °C; iOS fallback `dev / 0.3` when the baseline is not usable; Android z = 30-night mean/SD; Cycle fused z. | One resolver per platform, same statistic on both, oracle-tested. | **High** (parity + "two readouts of one fact") | iOS and Android feed the byte-identical engines **different z inputs** for the same night. With sigma floored at 0.3 °C (×1.253 = 0.376), a +0.75 °C night reaches z = 2 on a quiet baseline while a luteal +0.5 °C sits at z ≈ 1.3 — so a stable wearer's luteal rise is one warm bedroom away from an illness corroboration. The symmetric Recovery penalty also docks Charge for a *cooler* night, which no cited study supports as a recovery signal. |
| 3.8 | No Apple Health export; no Health Connect export. | Health Connect `SkinTemperatureRecord`; iOS Shortcuts file; document the HealthKit wall. | Medium (user-facing) | Apple: "These samples are read-only … you can't request authorization to share them." Health Connect has the exact type with deltas + baseline + wrist location. |
| 3.9 | Sensor accuracy unknown; 5.0 raw is centidegrees. | Characterise night-to-night SD and oral-thermometer correlation (§5). | Low–Medium | Maijala's finger–oral r = 0.563 is the realistic ceiling; the number NOOP needs is its own precision on stable nights, not absolute accuracy. |
| 3.10 | Confounder gate is journal-only. | Add bedroom temperature (manual or logger) and cycle phase as dampeners for the illness read; keep cycle opt-in. | Medium | Zhu/Mason did not evaluate ambient; Apple and Oura both name environment; the deviation method only helps when the room is stable across nights. |

---

## 4. WHOOP 5.0 input constraints

- **Byte 73 availability.** README: skin temperature "not available consistently across 5/MG
  firmware". The owner's firmware is frozen, so the field either decodes on this strap or never will;
  `skinTempFunnel.totalSamples == 0` over many nights is the test. If it does decode, the fixture in
  `Whoop5HistoricalTests` (worn 3057 = 30.6 °C, off-wrist 2247 = 22.5 °C) shows the /100 scale is
  physically right at both ends.
- **Aux channels (bytes 69/71)** are unlabelled i16 /10 °C with a 0–60 °C gate; which thermistor each
  is, and whether either faces away from the skin, is not established (`PROTOCOL_SENSORS.md`: "This
  does not establish which physical sensors supply the auxiliary channels"). They can be used only as
  an *unlabelled* second and third channel until a bedroom reference says what they track.
- **HR gaps** (v26-heavy stretches) silently convert skin samples to "not worn" (§3.4). Degradation:
  per-night coverage must be reported, and a tolerance window (as #1467 did for Oura) is the cheap
  fix; `sleepStateSample` (byte 81 WAKE/STILL/SLEEP/UP) is an HR-independent worn/in-bed hint worth
  testing as a second gate.
- **Session bounds** come from HR-only detection on sparse-gravity nights, so trimming "90 min after
  onset" inherits that onset error; keep the trim conservative and store the untrimmed mean beside it.
- **No ambient channel** is known; §2.3-4 is the only path.
- **Graceful degradation:** nil (not 0) when coverage fails; keep the existing funnel so the reason is
  visible; never let a thin night seed the baseline (today 5 min can).

---

## 5. Validation plan

### 5.1 Datasets

| Dataset | What it has | Access | Fit |
|---|---|---|---|
| **mcPHASES** (PhysioNet, v1.0.0, 2025-09-09, DOI 10.13026/zx6a-2c81) | 42 participants released (50 enrolled), two 3-month intervals, **Fitbit Sense skin temperature**, daily urinary LH/E3G/PdG (Mira), hormone-labelled phases, self-reported menses. | **Restricted**: registered user + PhysioNet Restricted Health Data DUA 1.5.0; the page also states the files are currently not available. Sampling resolution not stated. | Best available for the cycle component; wrist (Fitbit) not finger. Not usable for a 1 Hz stable-max replay unless the raw series is included. |
| TemPredict (Oura) | Illness + temperature at scale. | **Not public** (Mason 2022; Miller 2020 likewise "cannot be shared"). | None. |
| Public wrist-temperature + illness/cycle series | — | **None found** this session (PhysioNet / Zenodo / Dryad not exhaustively searched; §8). | — |

R8 applies: the illness-detection question **cannot be measured** on public data today; what can be
measured is precision (night-to-night SD) and the cycle component on mcPHASES if access is granted.

### 5.2 Metrics to report (R1 pre-registered, R3 with command, R5 temporal split, R7 n/units)

- **M1 precision:** SD of the nightly statistic across self-reported healthy, non-travel,
  alcohol-free nights, for mean vs trimmed stable-max — prediction: stable-max SD < mean SD.
- **M2 oral agreement:** repeated-measures correlation between nightly deviation and a waking oral
  thermometer deviation (Maijala: r = 0.563 finger–oral; the wrist number is the result).
- **M3 cycle (opt-in, a wearer with a cycle only):** cosinor r² (> 0.25 = oscillatory in
  Gombert-Labedens), and detected-elevation onset vs diary/OPK within ±2 d; Maijala's ±2…±4 d
  menstruation sensitivities are the comparators.
- **M4 illness base rate (R6):** count nights per 30 with illness-z ≥ 2 on healthy nights, before and
  after the baseline change; Kasl's 0.8 % FPR at 50 % sensitivity is the only published anchor.
- **M5 ambient:** correlation of (primary − aux) gradients and of the nightly deviation with a bedroom
  logger over ≥ 30 nights; a deviation that follows the room is a confounder measurement, not a
  physiology one.
- Report the gap between the early and late half of the owner's series for every fitted constant.

### 5.3 Owner-only validation (this clone)

Instruments: a waking oral thermometer (daily), a cheap bedroom temperature logger, an illness diary
with onset date, journal tags already in the app (alcohol / sauna / late workout / travel), and, if
applicable, a cycle diary or OPK strips. Replay via a new `Tools/SkinTempBench` over a **copy** of the
SQLite DB (per `VALIDATION_PROTOCOL.md`), printing per night: total / notWorn / outOfWindow /
outOfRange / kept, coverage, mean, p50, stable-max, aux1/aux2 means, gradients. Keep all of it in the
git-ignored `research-data/`.

---

## 6. Implementation sketch

All pure, DB-free, in `Packages/StrandAnalytics` with a Kotlin twin and a Swift-stdout oracle test
(`AGENTS.md` parity rule). New stored values go into `metricSeries(key, day, value)` as additive keys
(`skin_temp_max_c`, `skin_temp_p50_c`, `skin_temp_cov`, `skin_temp_aux1_c`, `skin_temp_aux2_c`), so
no `dailyMetric` migration is needed for the instrumentation phase.

### 6.1 Nightly statistic (Swift and Kotlin identical)

```
struct NightlySkinTemp { meanC, p50C, stableMaxC: Double?; keptSec, windowSec: Int; coverage: Double }

func nightlySkinTemp(sessions, hr, skinTemp, family, anchorRaw, wornToleranceSec, now):
  // 1. existing funnel gates (worn, in-session, 28–42 °C) → kept samples with ts, °C
  // 2. trimmed window over the UNION of sessions: [first.start + 5400, last.end − 1800]
  //    (skip the trim when the union is shorter than 4 h; then window = union)
  // 3. keep only samples inside the window; coverage = kept / windowSec
  // 4. gates: kept >= 7200 (2 h at 1 Hz) AND coverage >= 0.5, else all three values nil
  // 5. moving average, 1020 s, centred, on the 1 Hz grid; do not bridge gaps > 300 s
  //    (a window containing a gap > 300 s is skipped)
  // 6. a window is stable when (max − min of its inputs) < 1.0 °C
  // 7. stableMaxC = max over stable windows (nil if none); p50C = median(kept); meanC = mean(kept)
  // 8. all three rounded with round2 (same as skinTempDevC today)
```

Constants (`minKeptSec 7200`, `minCoverage 0.5`, `trimStartSec 5400`, `trimEndSec 1800`,
`maSec 1020`, `stableSpanC 1.0`, `maxGapSec 300`) pinned by test and named in one `enum`.

### 6.2 Two baselines, one resolver

```
// Illness: lagged robust baseline over calendar-padded nights
func illnessZ(series: [Double?] /* oldest→newest, nil = no night */) -> Double?:
  ref = series[n−21 ..< n−7].compactMap{ $0 }
  guard ref.count >= 10, let x = series.last ?? nil else { return nil }
  med = median(ref); mad = median(|ref − med|)
  sigma = max(1.4826 · mad, 0.1)
  return (x − med) / sigma               // one-sided use stays in IllnessSignalEngine

// Cycle: filtered elevation (opt-in only)
func cycleComponent(series: [Double?]) -> [Double?]:
  interpolate runs of ≤ 3 missing nights linearly; longer runs stay nil and split segments
  per segment of ≥ 42 nights: 2nd-order Butterworth low-pass, fc = 1.5/28 per day, zero-phase
  (forward–backward), coefficients precomputed and pinned as literals
  return filtered − rolling minimum(filtered, 40 d)     // elevation above the last trough, °C
```

`CyclePhaseEngine` keeps its interface: `tempZ` becomes `elevation / MAD(elevation)` computed by the
**same** function on both platforms (`V5HealthSignals.kt` and `AppModel.swift` both call it; the
`dev / 0.3` fallback is deleted). `RecoveryScorer`'s term stays as is until §5 M1/M4 say otherwise,
but the symmetric sign is flagged for the topic-06 synthesis.

### 6.3 Aux instrumentation (read-only)

Extend the funnel diagnostic with `aux1MeanC`, `aux2MeanC`, `grad1C = mean(primary − aux1)`,
`grad2C`; log them with the existing #752 line; write the three `metricSeries` keys. No consumer.

### 6.4 Export

- Android: `SkinTemperatureRecord(startTime: sessionStart, endTime: sessionEnd, deltas:
  [Delta(time: sessionEnd, delta: TemperatureDelta.celsius(skinTempDevC))], baseline:
  Temperature.celsius(baselineCentre), measurementLocation: MEASUREMENT_LOCATION_WRIST)`, behind
  `HealthConnectFeatures.getFeatureStatus(FEATURE_SKIN_TEMPERATURE) == FEATURE_STATUS_AVAILABLE`;
  dedup with the same client-record-id scheme the other records use.
- iOS: keep `writeDenied`; add the deviation as a fifth field on the Shortcuts export line only if
  topic 10 approves changing that file's format (it is a user-parsed contract).

### 6.5 Effort and risk

| Item | Effort | Risk |
|---|---|---|
| 6.1 nightly statistic + coverage, behind a default-off experimental flag, `metricSeries` only | **M** | Low: additive, nil-safe, oracle-tested; the mean stays the shipped value until M1 is measured. |
| 6.2 lagged illness baseline + single resolver on both platforms | **S–M** | Medium: changes which nights can raise a heads-up; must ship with M4 base-rate counts, in-sample and held-out. |
| 6.2 cycle low-pass | **M** | Medium: filter coefficients must be byte-identical across platforms (pin as literals from one Swift run); opt-in stays default-off. |
| 6.3 aux instrumentation | **S** | Low. |
| 6.4 Health Connect export | **S** | Low; feature-gated. |
| HealthKit wrist temperature | **none possible** | — (documented wall, not a gap to close). |
| `Tools/SkinTempBench` | **M** | Low; required before any of the above can be called an improvement. |

---

## 7. Sources (verified)

Each entry was fetched this session; the "verified" note states what was read.

1. Gombert-Labedens M, Alzueta E, Perez-Amparan E, et al. *Using wearable skin temperature data to
   advance tracking and characterization of the menstrual cycle in a real-world setting.* J Biol
   Rhythms 2024;39(4):331–350. DOI 10.1177/07487304241247893. PMC11294004.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC11294004/ — Verified from full text: Oura Gen2, 120 women,
   highest stable 17-min average per night, cosinor 22–36 d, r² thresholds 0.25/0.40, LH agreement
   82 %. This is the paper `CyclePhaseEngine` cites as "PMC11294004"; it is a finger-ring study.
2. Maijala A, Kinnunen H, Koskimäki H, Jämsä T, Kangas M. *Nocturnal finger skin temperature in
   menstrual cycle tracking: ambulatory pilot study using a wearable Oura ring.* BMC Women's Health
   2019;19:150. DOI 10.1186/s12905-019-0844-9. PMID 31783840. PMC6883568.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC6883568/ — Verified from full text: 1/min, 17-min moving
   average, highest stable value, Butterworth 1.5/28, 0.30 °C (SD 0.12) vs oral 0.23, r = 0.563,
   sensitivities by window.
3. Zhu TY, Rothenbühler M, Hamvas G, et al. *The accuracy of wrist skin temperature in detecting
   ovulation compared to basal body temperature: prospective comparative diagnostic accuracy study.*
   J Med Internet Res 2021;23(6):e20710. DOI 10.2196/20710. PMID 34100763. PMC8238491.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC8238491/ — Verified: 57 women / 193 cycles, LH reference,
   trimming 90/30 min, p99, three-over-six rule, sens 0.62 vs 0.23, spec 0.26 vs 0.70, ≈ 0.50 °C
   post-ovulatory rise, confounders not evaluated.
4. Shilaih M, Goodale BM, Falco L, Kübler F, De Clerck V, Leeners B. *Modern fertility awareness
   methods: wrist wearables capture the changes in temperature associated with the menstrual cycle.*
   Biosci Rep 2018;38(6):BSR20171279. DOI 10.1042/BSR20171279. PMID 29175999. PMC6265623.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC6265623/ — Verified: 136 women / 437 cycles, dorsal wrist,
   1/10 s, 90/30-min trim, LOESS, p99, 82 % shift detection, 86 % on/after ovulation, 0.33 °C.
5. Goodale BM, Shilaih M, Falco L, Dammeier F, Hamvas G, Leeners B. *Wearable sensors reveal
   menses-driven changes in physiology and enable prediction of the fertile window: observational
   study.* J Med Internet Res 2019;21(4):e13404. DOI 10.2196/13404. PMID 30998226. PMC6495289.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC6495289/ — Verified: p50 nightly WST, phase means
   34.11/33.87/33.88/34.32 °C, HR and RR shifts, sens 0.81 / spec 0.93.
6. Alzueta E, de Zambotti M, Javitz H, et al. *Tracking sleep, temperature, heart rate, and daily
   symptoms across the menstrual cycle with the Oura ring in healthy women.* Int J Womens Health
   2022;14:491–503. DOI 10.2147/IJWH.S341917. PMC9005074.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC9005074/ — Verified: 26 women, LH kits, mid/late-luteal
   +0.198 / +0.242 °C, HR +2.4 / +2.5 bpm.
7. Grant AD, Smarr BL. *Feasibility of continuous distal body temperature for passive, early pregnancy
   detection.* PLOS Digit Health 2022;1(5):e0000034. DOI 10.1371/journal.pdig.0000034. PMC9931282.
   https://pmc.ncbi.nlm.nih.gov/articles/PMC9931282/ — Verified: nightly max = median of hottest
   60 min, 17-day rolling window, MAD scaling, n = 30, no °C effect size reported.
8. Thigpen N, Patel S, Zhang X. *Oura Ring as a tool for ovulation detection: validation analysis.*
   J Med Internet Res 2025;27:e60667. DOI 10.2196/60667. PMID 39889300. (Europe PMC record,
   https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=DOI:10.2196/60667&resultType=core&format=json)
   — Verified abstract: 1,155 cycles / 964 participants, OPK reference, 96.4 % detected, MAE 1.26 d.
9. Lyzwinski L, Elgendi M, Menon C. *Innovative approaches to menstruation and fertility tracking using
   wearable reproductive health technology: systematic review.* J Med Internet Res 2024;26:e45139.
   DOI 10.2196/45139. PMC10905339. https://pmc.ncbi.nlm.nih.gov/articles/PMC10905339/ — Verified:
   13 studies, per-study figures only, no pooled estimate, no specificity reported.
10. Smarr BL, Aschbacher K, Fisher SM, et al. *Feasibility of continuous fever monitoring using wearable
    devices.* Sci Rep 2020;10:21640. DOI 10.1038/s41598-020-78355-6. PMID 33318528. PMC7736301.
    (Europe PMC record) — Verified abstract: first 50 TemPredict cases, peripheral temperature rises
    correlated with self-reported fever; proof of concept.
11. Mason AE, Hecht FM, Davis SK, et al. *Detection of COVID-19 using multimodal data from a wearable
    device: results from the first TemPredict study.* Sci Rep 2022;12:3463.
    DOI 10.1038/s41598-022-07314-0. PMC8891385. https://pmc.ncbi.nlm.nih.gov/articles/PMC8891385/ —
    Verified from full text: 30-min windows, p75-during-sleep trend, 21-day baseline, AUC 0.819,
    82/63 % and 90/80 %, 2.75 d lead, temperature +0.049 AUC, 6.7 % lower AUC in women; ambient /
    alcohol / cycle not addressed.
12. Kasl P, Keeler Bruce L, Hartogensis W, et al. *Utilizing wearable device data for syndromic
    surveillance: a fever detection approach.* Sensors 2024;24(6):1818. DOI 10.3390/s24061818.
    PMID 38544080. PMC10975930. (Europe PMC record) — Verified abstract: 724 fever days /
    342,430 non-fever days, AUROC 0.85, AP 0.25, FPR 0.8 % at sensitivity 0.50.
13. Mishra T, Wang M, Metwally AA, et al. *Pre-symptomatic detection of COVID-19 from smartwatch
    data.* Nat Biomed Eng 2020;4:1208–1220. DOI 10.1038/s41551-020-00640-6. PMID 33208926.
    (Europe PMC record) — Verified abstract: 32 cases, HR / steps / sleep, 63 % flagged
    pre-symptomatically by RHR elevation; **no temperature**. This is the "Stanford/Snyder" work
    `IllnessSignalEngine` cites.
14. Miller DJ, Capodilupo JV, Lastella M, et al. *Analyzing changes in respiratory rate to predict the
    risk of COVID-19 infection.* PLoS One 2020;15(12):e0243693. DOI 10.1371/journal.pone.0243693.
    PMC7728254. https://pmc.ncbi.nlm.nih.gov/articles/PMC7728254/ — Verified: WHOOP strap, 81 positive
    / 190 negative, respiratory rate only (no skin temperature), **lagged baseline median/SD over
    nights −21…−7**, validation sens 36.5 % / spec 95.3 %. (The brief's "Natarajan 2020 WHOOP" lead
    conflates this with #15.)
15. Natarajan A, Su H-W, Heneghan C, Blunt L, O'Connor C, Niehaus L. *Measurement of respiratory rate
    using wearable devices and applications to COVID-19 detection.* npj Digit Med 2021;4:136.
    DOI 10.1038/s41746-021-00493-6. PMC8443549. https://pmc.ncbi.nlm.nih.gov/articles/PMC8443549/ —
    Verified: Fitbit, not WHOOP; RSA-derived respiratory rate; no skin temperature.
16. Kräuchi K, Cajochen C, Werth E, Wirz-Justice A. *Warm feet promote the rapid onset of sleep.*
    Nature 1999;401:36–37. DOI 10.1038/43366. PMID 10485703. (Europe PMC record; no abstract in the
    record) — Verified bibliographic record only; the finding is taken from #17.
17. Kräuchi K, Cajochen C, Werth E, Wirz-Justice A. *Functional link between distal vasodilation and
    sleep-onset latency?* Am J Physiol Regul Integr Comp Physiol 2000;278(3):R741–R748.
    DOI 10.1152/ajpregu.2000.278.3.r741. PMID 10712296. (Europe PMC record) — Verified abstract: the
    distal–proximal skin temperature gradient predicted sleep-onset latency better than core
    temperature, melatonin onset, heart rate or sleepiness.
18. Sarabia JA, Rol MA, Mendiola P, Madrid JA. *Circadian rhythm of wrist temperature in normal-living
    subjects: a candidate of new index of the circadian system.* Physiol Behav 2008;95(4):570–580.
    DOI 10.1016/j.physbeh.2008.08.005. PMID 18761026. (Europe PMC record) — Verified abstract:
    99 students, wrist temperature inverse to oral and leading by ~60 min, rises at bedtime.
19. Ortiz-Tudela E, Martinez-Nicolas A, Campos M, Rol MA, Madrid JA. *A new integrated variable based
    on thermometry, actimetry and body position (TAP) to evaluate circadian system status in humans.*
    PLoS Comput Biol 2010;6(11):e1000996. DOI 10.1371/journal.pcbi.1000996.
    https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1000996 — Verified:
    n = 49, iButton 10-min on the radial artery under a cotton band, TAP r = −0.993 vs diaries,
    sensitivity 0.740 / specificity 0.870.
20. Martinez-Nicolas A, Ortiz-Tudela E, Rol MA, Madrid JA. *Uncovering different masking factors on
    wrist skin temperature rhythm in free-living subjects.* PLoS One 2013;8(4):e61142.
    DOI 10.1371/journal.pone.0061142. PMC3618177. https://pmc.ncbi.nlm.nih.gov/articles/PMC3618177/ —
    Verified: 103 students, iButton ±0.125 °C, sleep raises wrist temperature whenever it occurs,
    sensor isolated from ambient by a cotton band.
21. Hasselberg MJ, McMahon J, Parker K. *The validity, reliability, and utility of the iButton for
    measurement of body temperature circadian rhythms in sleep/wake research.* Sleep Med
    2013;14(1):5–11. DOI 10.1016/j.sleep.2010.12.011. PMID 21470909. (Europe PMC record) — Verified
    abstract: iButton valid and reliable; distal–proximal gradient an accurate correlate of sleep
    propensity; placement, masking and analysis method are the key issues.
22. Garcia-Molina G, Winger T, Makaram N, et al. *Unobtrusive skin temperature estimation on a smart
    bed.* Sensors 2024;24(15):4882. DOI 10.3390/s24154882. PMID 39123929. (Europe PMC record) —
    Verified abstract: distal temperature rises ~1 °C and proximal ~0.5 °C around sleep onset; n = 18.
23. Bruce LK, Kasl P, Soltani S, et al. *Variability of temperature measurements recorded by a wearable
    device by biological sex.* Biol Sex Differ 2023;14:76. DOI 10.1186/s13293-023-00558-z.
    PMID 37915069. PMC10619297. (Europe PMC record) — Verified abstract: 6 months of Oura distal
    temperature, cyclic vs acyclic classification, most variance within rather than between sexes.
24. Apple Developer Documentation. *HKQuantityTypeIdentifier.appleSleepingWristTemperature.*
    https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature
    (fetched via the documentation JSON endpoint) — Verified: "A quantity sample type that records
    the wrist temperature during sleep." iOS 16+/watchOS 9+. "These samples are read-only. You can
    request permission to read the samples using this identifier, but you can't request authorization
    to share them. This means you can't save new sleeping wrist temperature samples to the HealthKit
    store." Confirms #1366 and `writeDenied`.
25. Apple Support. *Track your nightly wrist temperature changes with Apple Watch.*
    https://support.apple.com/102674 — Verified: samples every 5 s, two sensors reduce environmental
    bias, ~5 nights with ≥ 4 h Sleep Focus for a baseline, shown as relative changes, diet / exercise /
    alcohol / sleep environment named, "not a thermometer", Series 8+/Ultra/SE 3.
26. Android Developers. *SkinTemperatureRecord* (androidx.health.connect.client.records).
    https://developer.android.com/reference/androidx/health/connect/client/records/SkinTemperatureRecord
    — Verified: added in 1.1.0; `deltas: List<Delta>` "relative to" an optional `baseline`
    (0–100 °C); `MEASUREMENT_LOCATION_WRIST = 3`; gated by
    `HealthConnectFeatures.FEATURE_SKIN_TEMPERATURE`; `TEMPERATURE_DELTA_AVG/MIN/MAX` aggregates.
27. Oura Support. *Body Temperature* (article 360025587493).
    https://support.ouraring.com/hc/en-us/articles/360025587493 — Verified: average during sleep,
    baseline over "the first couple of weeks" then adjusted, ± fluctuations from baseline, 3-day
    weighted trend, temperature only lowers readiness, cool environment / follicular phase named for
    low readings.
28. Oura blog. *Temperature validated accurate.* https://ouraring.com/blog/temperature-validated-accurate/
    — Vendor claim, verified as stated: r² > 0.92 vs an iButton on the same finger (n = 16, one
    week), 0.13 °C resolvable change, finger temperature "uncorrelated to the environmental
    temperature" (r² = 0.001). Not independent evidence.
29. PhysioNet. *mcPHASES* v1.0.0. https://www.physionet.org/content/mcphases/ — Verified: DOI
    10.13026/zx6a-2c81, Restricted Health Data License 1.5.0, Fitbit Sense skin temperature, Mira
    LH/E3G/PdG, 42 participants released, files currently listed as not available.

## 8. Unverified leads

- **WHOOP "How WHOOP tracks skin temperature"** (whoop.com/thelocker) — returned HTTP 403 on both the
  global and AU mirrors. Search snippets claim a 90-night personal baseline and an "above baseline"
  flag; not fetched, so not relied on.
- **Fitbit skin temperature variation** — only a community blog surfaced (≥ 3 nights to establish,
  up to 30 days to adjust); no official help article fetched.
- **Sun et al., wrist vs mean skin temperature across indoor temperature × bedding insulation** —
  surfaced only as a search snippet; the DOI guessed for it resolved to #22, a different paper. The
  bedding/ambient effect size on wrist temperature is therefore **not verified** here.
- **Keeler Bruce 2023 full text** (nightly-max method details and ~28-day period claim) — abstract
  only.
- **Kräuchi 1999 abstract** — record has no abstract; finding attributed to the 2000 paper instead.
- **"Zhu 2021 JMIR mHealth"** — the venue in the brief is wrong; the paper is JMIR (#3).
- **"Goodale 2021"** — is 2019 (#5). **"Natarajan 2020 WHOOP"** — is Natarajan 2021 Fitbit (#15); the
  WHOOP paper is Miller 2020 (#14). **"Grant 2022"** — is Grant & Smarr 2022 PLOS Digit Health (#7);
  Grant's 2020 Oura HRV ultradian work was not fetched.
- **"Lee 2024 reviews"** — not identified; the 2024 systematic review found is Lyzwinski (#9).
- **Wrist vs finger head-to-head** — no study directly comparing nightly wrist and finger deviations
  was found (two searches, one Europe PMC query); only vendor claims (#28) and the iButton literature's
  radial-artery wrist placement (#19, #20). State as unknown.
- **Hasselberg "Chronobiology International 2013"** — the paper is Sleep Medicine 2013 (#21).
- A commercial-blog claim of a "2025–2026 systematic review" with pooled sensitivity 0.79 / specificity
  0.80 for ovulation detection could not be traced to any primary source; ignored.

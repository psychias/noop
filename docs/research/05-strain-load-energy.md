# 05 – Strain, training load and energy expenditure

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Phase 1 research
deliverable for `RESEARCH_BRIEF.md` §5.1 topic 05. Every source in §7 was fetched this session (PubMed
E-utilities, Europe PMC REST, PhysioNet, Zenodo, UCI, or a PDF downloaded and text-extracted locally);
findings are taken from the fetched abstract/full text, not from memory. Where an abstract did not carry
a number the code relies on, that is said explicitly. Claims about NOOP's code are CONFIRMED by reading
the source on this date unless marked INFERRED.

Wording note: nothing in this document is medical advice; "injury risk", "illness" and similar phrases
appear only when quoting what a source measured, and §3 recommends removing such phrasing from NOOP's
user-facing copy.

---

## 1. What NOOP does today

### 1.1 Effort (strain) — `StrainScorer`

| | Swift | Kotlin |
|---|---|---|
| File | `Packages/StrandAnalytics/Sources/StrandAnalytics/StrainScorer.swift` | `android/app/src/main/java/com/noop/analytics/StrainScorer.kt` |
| Entry | `StrainScorer.strain(_:maxHR:restingHR:method:sex:denominator:diag:day:)` | `StrainScorer.strain(...)` |
| Parity proof | — | `android/app/src/test/java/com/noop/analytics/BanisterParityOracleTest.kt` (Swift stdout pasted as the Kotlin expected literal, 8 intensities) |

Pipeline (CONFIRMED):

1. **Heart-rate reserve** `HRR = HRmax − RHR` (cites Karvonen 1957). Per sample `%HRR = (bpm − RHR)/HRR·100`
   clamped to `[0, 100]` (`pctHRR`).
2. **TRIMP accumulation**, one of two recipes, per-sample durations from the gap to the next sample clamped at
   `maxSampleGapMin = 2.0` (`sampleDurationsMinutes`, #950):
   - **Edwards-STYLE** (default): weight `1…5` at `50/60/70/80/90 %HRR` cut-offs (`edwardsZones`), × minutes.
     The header documents (#2835) that Edwards 1993 defines the zones on **%HRmax** and that reading them on
     %HRR is deliberate; below 50 %HRR the weight is 0.
   - **Banister**: per sample `minutes × x × a × e^(b·x)`, `x = %HRR/100`, with the pair
     `BanisterCoefficients` = `(0.64, 1.92)` men / `(0.86, 1.67)` women (`banisterCoefficients(sexF:)`,
     #2835). A sedentary floor `banisterSedentaryHRR = 0.10` is subtracted per sample
     (`banisterBaselineRatePerMinute`, #1624) and from the denominator.
3. **Log map** `Effort = 100 · ln(TRIMP + 1) / ln(D)`, 2 dp (`trimpToStrain`). `D = strainDenominator = 7201`
   for Edwards (= 24 h × weight 5 + 1), and `banisterDailyCeiling − banisterBaseline(1440 min) + 1` for
   Banister (`logMapDenominator(method:sex:)`, #1545). `maxStrain = 100` (was 21; `whoopMaxStrain = 21`
   kept for import rescale `effortValue(fromWhoopStrain:)`).
4. **Gates**: `minReadings = 600` dense samples OR `minSparseReadings = 20` spanning `minSpanSeconds = 600`
   (#482, the 5/MG ~30 s live cadence); `HRmax ≤ RHR` refuses. Refusals and scores are logged by
   `scoreFunnelLine` (with per-zone minutes `z0…z5` from `zoneMinutes`).
5. **HRmax** (`estimateHRmax`): with ≥ `hrmaxMinSamples = 600` samples, the `99.5`th percentile of the HR history
   ("observed") unless Tanaka `208 − 0.7·age` is higher; else Tanaka; else `(0, "unknown")`. `defaultMaxHR = 220 − age`
   is the last-resort fallback inside `strain` when no `maxHR` is passed. The #2438 instrumentation
   (`dayCalibrationLine`, `sustainedPeak`, `sustainedPeakSpan`) logs raw peak vs a 5-sample/60 s sustained peak
   but changes no score.
6. **Denominator calibration** `fitStrainDenominator(pairs)`: through-origin least squares in log space,
   `ln D = maxStrain · Σx² / Σ(x·strain)`, `x = ln(TRIMP+1)`; exists, but no fitted value ships (`D = 7201` is a
   ceiling-derived constant).
7. `effectiveEffort(live:stored:)` takes the max of live and stored so the ring never drops (#1001).

A "steps / active-energy floor" is described in `docs/ANALYTICS.md` ("Steps / active-energy floor") but no
function implementing it was found under `Packages/StrandAnalytics` during this inventory (INFERRED: app-layer
or documentation ahead of code; not relied on below).

Header-cited sources: Karvonen 1957; Edwards 1993; Banister 1991; Morton, Fitz-Clarke & Banister 1990; Tanaka 2001.

### 1.2 Training load, ACWR and monotony

- `TrainingLoadEngine.swift` / `.kt`: EWMA fitness–fatigue states, `alpha = 1 − exp(−1/tau)`, `tau` 42 d (CTL) and
  7 d (ATL), `TSB = CTL − ATL`, seeded from a 7-day prime; **input is daily Effort (0–100 log scale), not TRIMP**,
  and the header says so. Descriptive only; does not feed Readiness.
- `ReadinessEngine.swift` lines ~203–228 and `acwrSignal` (~291–316): **ACWR = mean(last 7 Effort) / mean(last 28
  Effort)**, requires `minChronic = 14` values; bands `< 0.8` "ramping down", `0.8–1.3` "sweet spot", `1.3–1.5`
  "building fast", `≥ 1.5` "spiking … higher injury risk" (flag `.bad`), citing Gabbett 2016. **Monotony** =
  mean/SD of the last 7 Effort values (≥ 4 values), flagged `≥ 2.0` with the copy "raises strain/illness risk",
  citing Foster 1998. Both use the daily `strain` series (the 0–100 Effort number), with calendar gaps
  compacted (`strainSeries = sorted.compactMap { $0.strain }`).
- Kotlin twins: `ReadinessEngine.kt`, `TrainingLoadEngine.kt`.

### 1.3 Calories — `Calories` in `WorkoutDetector.swift` (~585–856) and `WorkoutDetector.kt`

- **Active**: Keytel 2005. Base (fitness-blind) coefficients: men `−55.0969 + 0.6309·HR + 0.1988·W + 0.2017·A`
  kJ/min, women `−20.4022 + 0.4472·HR − 0.1263·W + 0.0740·A`; "nonbinary" = midpoint. Fitness-adjusted variant
  (`fitHR/fitVO2/fitWeight/fitAge/fitAlpha`) used whenever a resting HR exists, with VO₂max from
  **Uth 2004** `15.3 · HRmax / HRrest` (`vo2maxFor`). HR capped at HRmax. `/ 251.04` → kcal/s.
- **Resting**: revised Harris–Benedict (Roza & Shizgal 1984 coefficients: men `88.362 + 13.397·W + 479.9·h(m)
  − 5.677·A`, women `447.593 + 9.247·W + 309.8·h − 4.33·A`) / 86 400 → kcal/s.
- **Gates**: bout path switches to the active rate above `RHR + 0.30·HRR` (`activeHRRFraction`); day path above
  `RHR + 0.50·HRR` (`dayActiveHRRFraction`) and credits only `max(0, gross − resting)`. Day resting energy is
  integrated over **observed** seconds only (gaps capped at `dayMaxObservedGapS = 60`), active carry capped at
  the inferred cadence. Defaults when the profile is empty: 70 kg, 170 cm, age 30, HRmax 220, RHR 60.
- Tests: `DayCaloriesTests.swift`, `DayCaloriesTest.kt`, `WorkoutDetectorTests`.

### 1.4 Supporting

`HRZones.swift` (display zones on %HRmax, Tanaka), `FitnessAgeEngine.swift` (Nes 2011 HUNT, Uth fallback via
`vo2maxFor`), `HeartRateRecovery`, `VitalityEngine` — not primary targets here.

---

## 2. Recommended method(s) from the literature

### 2.1 Internal-load models (what is verified, and what each needs)

| Model | Verified definition (source) | Inputs | Evidence relevant to a daily, recreational wearer |
|---|---|---|---|
| **Banister TRIMP** | `D × x × a·e^{b·x}`, `x = (HRex−HRrest)/(HRmax−HRrest)`, **a = 0.64, b = 1.92 (men); a = 0.86, b = 1.67 (women)** — quoted verbatim by Bok, Jukić & Foster 2022 and by Shaw et al. 2020, both citing Banister 1991 "Modeling elite athletic performance". Hourcade et al. 2018 quote only the men's pair, citing Banister & Hamilton 1985. The **Morton, Fitz-Clarke & Banister 1990 abstract does not state any coefficient** (it describes the fitness/fatigue impulse-response model). | HRmax, HRrest, mean or per-sample HR, duration | Shaw 2020 (n = 193 sessions, professional ballet): rmcorr with session-RPE load r = 0.79; the authors note they could not measure HRmax and used the higher of Tanaka and the observed peak. Morton 1990: fitness/fatigue decay with 42/7-day style constants (the model behind `TrainingLoadEngine`). |
| **Edwards summated zones** | Minutes in **50–60 / 60–70 / 70–80 / 80–90 / 90–100 %HRmax** × 1/2/3/4/5, summed — quoted identically by Hourcade 2018, Bok 2022 and Shaw 2020, all citing Edwards 1993 *The Heart Rate Monitor Book* (a book; primary not fetchable). | HRmax only | Shaw 2020: rmcorr with sRPE r = 0.81 (all sessions), individual r 0.57–0.96; Halson 2014 calls the zones "arbitrary". No study fetched validates it against performance change for recreational athletes. |
| **Lucia TRIMP** | Three zones bounded by the **ventilatory threshold and respiratory compensation point** from a ramp test, load = volume × intensity (Lucia et al. 2003 abstract); zone weights **1/2/3** (Nuuttila et al. 2024, quoting Lucia 2003). | Lab thresholds (VT1/VT2 or LT1/LT2) | Not available from a strap; Nuuttila 2024 used LT-based zones in 24 recreational runners. |
| **iTRIMP (Manzi 2009)** | Individual HR–lactate profile from an incremental test, 8 recreational runners, 8 weeks: weekly TRIMPi correlated with the change in speed at 2 mmol/L (r = 0.87) and 4 mmol/L (r = 0.74), and with 5 000 m (r = −0.77) and 10 000 m (r = −0.82) performance; **no relationship when group-average values were used**. | Lactate profile | Strongest performance validity among the HR methods, but needs a lab test. |
| **Stagno 2007 TRIMP_MOD** | Modified TRIMP for intermittent team sport (8 hockey players); mean weekly TRIMP_MOD correlated with changes in VO₂max and speed at 4 mmol/L (P < 0.05). Abstract gives no equation. | Lactate-derived zones | Team-sport specific; not transferable without the equation. |
| **Session-RPE / Foster** | Load = RPE × minutes; **monotony = mean/SD of daily load; strain = weekly load × monotony** (Foster 1998 abstract). Illness clustered when athletes exceeded *individual* thresholds, mostly tied to strain (25 athletes). **No numeric monotony threshold appears in the abstract**; the "2.0" in NOOP is a convention, not a published cut-off. | Subjective RPE | Only method among these with an illness finding, and it was individual-threshold based. |

**Supporting physiology.** %HRR tracks **%VO₂ reserve**, not %VO₂max: Swain & Leutholtz 1997 (n = 63) found
%HRR vs %VO₂R slope 1.00, intercept −0.1, while %HRR vs %VO₂max had intercept −11.6 and slope 1.12. So %HRR is
the better intensity axis for a *metabolic* load, and a %HRR-based Banister recipe is on firm ground; it also
means the Edwards zone labels (which are %HRmax) and NOOP's %HRR cut-offs are **not** interchangeable: the same
cut-off number means a different intensity on each axis.

**Which is best supported for daily load in recreational wearers.** None of the HR-only methods has a
fetched validation of *daily* 24-hour load in recreational users; the evidence is per-session, in trained or
professional athletes, against sRPE or performance. Within that evidence: Banister (continuous in intensity,
needs HRmax + HRrest, which NOOP has) and Edwards (needs HRmax only, coarse) both correlate ≈ 0.8 with sRPE
at session level; iTRIMP is the only one tied to performance change in recreational runners and needs a lab.
Recommendation: keep **Banister-on-%HRR as the primary recipe** (it is the one whose inputs NOOP measures and
whose intensity axis is validated), keep Edwards as an interpretable secondary, and treat both as
**approximate internal-load indices**, never as validated predictors of anything.

### 2.2 HRmax estimation

| Equation | Source (verified) | Error |
|---|---|---|
| `208 − 0.7·age` | Tanaka, Monahan & Seals 2001 (meta-analysis of 351 studies / 18 712 subjects, r = −0.90; lab cross-validation n = 514 gave `209 − 0.7·age`); age alone predicts HRmax, independent of sex and activity | **SEE not in abstract.** Robergs & Landwehr 2002 re-fit 30 published equations and obtain `208.754 − 0.734·age`, Sxy = 7.2 bpm, "very close to Tanaka". |
| `207 − 0.7·age` | Gellish et al. 2007 (longitudinal, 132 people, 908 tests, 1978–2003, mixed model) | Not in abstract. |
| `211 − 0.64·age` | Nes et al. 2013 (HUNT, n = 3 320 healthy adults; age alone, no interaction with sex, activity, VO₂max or BMI; older formulas underestimate above 30 y) | **SEE = 10.8 bpm**; authors: "substantial" for individual use. |
| `220 − age` | Robergs & Landwehr 2002 (JEPonline 5(2)): no original data; re-analysis of Fox et al. 1971's own points gives `215.4 − 0.9147·age`, r = 0.51, Sxy = 21 bpm | Population equations range Sxy 7–11 bpm; Inbar 1994 `205.8 − 0.685·age` (n = 1 424) Sxy = 6.4 bpm is the lowest listed. |

All age formulas carry roughly ±7–11 bpm (1 SD) individual error. For a 40-year-old, Tanaka gives 180 and Nes
185; the 5 bpm difference is inside either formula's SEE, so **switching formulas buys nothing measurable**.
What matters is (a) never using `220 − age` as a silent fallback and (b) replacing the formula with a
*measured* HRmax when a trustworthy one exists.

**Observed HRmax from a wearable.** Wrist PPG HR error is intensity- and activity-dependent: Shcherbina et al.
2017 (60 adults, 7 wrist devices) report median HR error < 5 % for six devices during cycling, highest error
during walking, and higher error with higher BMI and darker skin; Etiwy et al. 2019 (80 cardiac-rehab patients)
report concordance with ECG of 0.52–0.80 for wrist devices vs 0.99 for a Polar H7 chest strap, with the worst
agreement on the treadmill. NOOP's own #2438 instrumentation found that on ring data the raw daily maximum sat
above the age formula on 58 of 60 days while a 5-sample sustained peak did on none. Conclusion: a single-sample
percentile is **not** a reliable HRmax; a *sustained* peak, confirmed on more than one day, is a defensible
lower bound for HRmax and should be allowed to **raise** (never lower) the formula value — the same rule Shaw
2020 used ("the higher of Tanaka and the recorded peak").

### 2.3 Mapping load onto a bounded logarithmic scale

**WHOOP's model is proprietary.** WHOOP's own pages (search-result excerpts; the pages returned HTTP 403 to the
fetcher — see §8) describe Strain as a 0–21 score of cardiovascular load based on time in heart-rate zones,
personalised to max HR, on a logarithmic curve ("10 → 11 takes less than 20 → 21"), with muscular load added
from logged strength sets. No formula is published. Anything NOOP does is therefore a *design*, and it should be
documented as such: the useful property to borrow is **diminishing returns**, not any specific number.

**Evaluation of NOOP's `100·ln(TRIMP+1)/ln(7201)`** (CONFIRMED by arithmetic on the shipped constants;
Edwards-style TRIMP, 1 Hz):

| Day | TRIMP | Effort |
|---|---|---|
| 10 min in zone 1 (50–60 %HRR) | 10 | 27.0 |
| 60 min in zone 1 | 60 | 46.3 |
| 30 min in zone 3 | 90 | 50.8 |
| 60 min in zone 4 | 240 | 61.8 |
| 90 min zone 3 + 30 min zone 5 | 420 | 68.0 |
| 4 h in zone 4 (hard marathon) | 960 | 77.3 |
| Effort 86 (WHOOP "18/21" equivalent) | 2 077 | needs ≈ 7 h at zone 5 or 8.7 h at zone 4 |
| 24 h at zone 5 | 7 200 | 100.0 |

Two problems follow from anchoring D to a physically impossible day:

1. **The low end is too steep.** The first ten minutes of light activity are worth 27 points; the next 50
   minutes of the same activity are worth 19. A 1-hour easy walk and a 30-minute tempo run are 4 points apart.
2. **The top ~20 % of the axis is unreachable** for any realistic single day; "all-out" days of normal athletes
   land at 65–78. The old 0–21 scale had the identical shape (only `maxStrain` changed), so this is inherited,
   not introduced by the rescale.

The Banister axis has the same shape with a different floor: the oracle test shows a 24 h day at 15 %HRR scoring
49.27 even after the #1624 sedentary floor, while Edwards scores it 0. The two recipes are still not on one axis,
and the cause is the log map's steepness near zero, not the recipes.

**Defensible mapping (proposal).** Keep the logarithm (it is the documented, diminishing-returns design), but
anchor D to a **documented, realistic reference day** rather than a 24-hour ceiling, and clamp:

```
Effort = min(100, 100 · ln(1 + TRIMP / T₀) / ln(1 + T_ref / T₀))
```

with `T₀` a small "noise floor" load (e.g. 10 TRIMP, so that ten light minutes read ≈ 5, not 27) and `T_ref`
the load that should read 100 — e.g. Edwards-style 1 000 (≈ 4 h at zone 4, ≈ 3.3 h at zone 5), or a
**per-wearer** value: the 95th percentile of the trailing 90 days (`fitStrainDenominator` already exists for
the fitted form). The exact constants are a *calibration*, and §5 describes how to fit them against the owner's
WHOOP export without reverse-engineering WHOOP: the fit only chooses where NOOP's documented curve puts its
anchors. Until a fit exists, the honest label for Effort is "cardiovascular load index", with the scale's two
anchors stated in the docs.

### 2.4 ACWR, EWMA, monotony — what the literature now says

- **Origin.** Hulin et al. 2014 (28 cricket fast bowlers, 6 seasons): internal training-stress balance > 200 %
  RR 4.5 (CI 3.43–5.90), external RR 3.3. Hulin et al. 2016 (53 rugby league players, 2 seasons): ACWR ≥ 2.11
  carried 16.7 % injury likelihood that week; high chronic load with ACWR 0.85–1.35 was associated with lower
  risk; **acute or chronic load alone did not consistently predict injury**. Gabbett 2016 (BJSM editorial) and
  Blanch & Gabbett 2016 (R² = 0.53 polynomial) promoted the 0.8–1.3 "sweet spot" and > 1.5 danger zone. Maupin
  et al. 2020 (systematic review, 27 studies, mean Downs & Black 59.7 %, "fair") find only "a trend towards
  0.80–1.30 demonstrating the lowest risk", with pooled OR 0.59 (95 % CI 0.14–2.45) for that band, all in elite,
  professional or university athletes; no recreational population.
- **EWMA vs rolling average.** Williams et al. 2017 (letter; metadata verified, text not fetchable) proposed
  `EWMA_today = load_today·λ + (1−λ)·EWMA_yesterday`, `λ = 2/(N+1)`, N = 7 or 28 — the formula as reproduced by
  Cousins et al. 2019. Murray et al. 2017 (59 AFL players, 2 years): EWMA ACWR > 2.0 RR 6.52–21.28 (total
  distance), greater explained variance than rolling averages. Cousins 2019 (elite rugby union, 474 time-loss
  events): EWMA models fit better (AIC 2980 vs 2993) but **absolute weekly sRPE load was the best predictor**
  (OR 1.11 per 100 AU) and ACWR sRPE was not significant (p = 0.255).
- **Criticisms.** Lolli et al. 2019 (BJSM editorial): mathematical coupling — the acute week is inside the
  chronic denominator, producing spurious correlation (title/metadata verified; Maupin 2020 restates the point
  as "the acute load being present in both the numerator and denominator"). Windt & Gabbett 2019 reply (metadata
  verified). Impellizzeri et al. 2020 (IJSPP): the ratio "fails to normalise the numerator by the denominator"
  even when uncoupled; interpretation ambiguous; "no evidence supporting the use of ACWR in training-load-management
  systems". Impellizzeri et al. 2021 (Sports Med): replacing chronic load with **fixed or random numbers** gave the
  same effect sizes; neither ACWR nor acute load beat an intercept-only model; the authors recommend dismissing
  ACWR "as a framework and model".
- **Monotony / strain.** Foster 1998: individual-threshold spikes explained 77 % (monotony) and 89 % (strain) of
  illnesses in swimmers (per Jones et al. 2017's table). Jones, Griffiths & Mellalieu 2017 (systematic review,
  68 longitudinal studies): monotony/strain associations are mixed — r = 0.67–0.68 in 12 female basketball
  players, OR 2.59 for traumatic injury in 53 soccer players, and non-significant in rugby league and AFL
  samples. No fetched source gives "monotony > 2.0" as a validated threshold.

Net: the **ratio** is the weak part. A one-number, **uncoupled** description of recent load is defensible
(e.g. this week's load, its EWMA, and the chronic EWMA shown side by side, or `TSB` as `TrainingLoadEngine`
already does); labelling any band of it as a risk of injury is not supported, and the strongest recent
evidence favours the *absolute* acute load.

### 2.5 Heart-rate energy expenditure and BMR

| Method | Verified result | Inputs |
|---|---|---|
| **Keytel et al. 2005** | 115 regular exercisers, submaximal stages, mixed model: with VO₂max r = 0.913 (R² 0.833); without VO₂max r = 0.857 (R² 0.734). Base men/women equation coefficients confirmed as reproduced by Chiu et al. 2022; **the VO₂max-variant coefficients in NOOP were not found in any fetched text** (abstract gives none). No RMSE in abstract. | HR, weight, age, sex; optional VO₂max |
| **Hiilloskorpi et al. 2003** | 89 adults, low→high intensity: SEE 1.41 kcal/min with raw HR, **1.01 kcal/min with %HRR**, 1.08 with HRnet; body weight, sex and intensity in all models. | HR, HRrest, HRmax, weight, sex |
| **Charlot et al. 2014** | Running, 50 subjects at 25/50/70 %HRR: new basic equation R² 0.809 vs 0.737 for existing ones; **adding VO₂max → R² 0.879**; speed-based equations best vs indirect calorimetry. | HR, VO₂max, (speed) |
| **Brage et al. 2007** | 51 adults, treadmill calorimetry reference: HR models explain > 95 % of between-person variance with lab calibration, 81 % with treadmill-without-calorimetry, 68 % step test, **30 % with non-exercise (sleeping HR + sex) calibration**. | Individual calibration |
| **Uth et al. 2004** | VO₂max ≈ 15.3·HRmax/HRrest; calibration n = 10 (factor 15.3 ± 0.7); validation 36 **well-trained men 21–51 y**: SEE 2.7 ml/kg/min (4.5 %) with measured HRmax, **4.7 ml/kg/min (7.8 %) with age-predicted HRmax**; "applicability … to other groups will have to await direct validation". | HRmax, HRrest |
| **Firstbeat white paper** (vendor documentation) | 32 adults, cycle ergometer + real-life tasks, Vmax/Cosmed K4 reference (mean 740 kcal): neural-net HR + respiration-rate + VO₂ on/off kinetics MAPE **10.9 %**; individually calibrated flex-HR 13.5 %; general flex-HR 14.4 %; Hiilloskorpi regression 27.6 %; Rennie regression 22.0 %. Their Table 2 rates plain HR-level methods at 20–35 % error. | HR, R-R (respiration), HRmax, VO₂max, age, sex, weight |
| **Wearable EE accuracy** | Shcherbina 2017: **no wrist device < 20 % EE error** (walking worst). Fuller 2020 (158 publications, 9 brands): no brand accurate for EE; HR accuracy best for Apple Watch/Garmin. O'Driscoll 2020 (60 studies, 104 effect sizes): large heterogeneity (I² > 75 %); adding HR or heat sensing to accelerometry reduced error. | — |
| **BMR: Harris–Benedict revised** | Roza & Shizgal 1984: 337 subjects total, precision **±14 %** in well-nourished adults. Mifflin 1990 report HB **overestimates measured REE by 5 %**. | weight, height, age, sex |
| **BMR: Mifflin–St Jeor 1990** | 498 adults 19–78 y (264 normal-weight, 234 obese): `10·W + 6.25·h(cm) − 5·A + 5` (men) / `− 161` (women), R² 0.71. Frankenfield et al. 2005 (systematic review, Academy of Nutrition and Dietetics): Mifflin predicted RMR **within 10 % in more individuals than any other equation**, narrowest error range → recommended. | weight, height, age, sex |

Should sex, age, weight and fitness be inputs? Yes to all four: every validated equation carries sex, weight
and age; the two fitness-aware variants (Keytel with VO₂max, Charlot with VO₂max) lift R² by ~0.07–0.10;
and Hiilloskorpi shows that expressing intensity as **%HRR** (which embeds RHR and HRmax, i.e. fitness) cuts
SEE by ~28 % versus raw HR. The catch is that NOOP's "fitness" input is Uth's ratio, which was validated only in
well-trained men and degrades to SEE ≈ 4.7 ml/kg/min when HRmax is age-predicted — the common case here.

---

## 3. Gap analysis

| # | Gap | Impact | Why |
|---|---|---|---|
| G1 | **Zone definition mismatch.** The default recipe reads Edwards' 50–90 cut-offs on %HRR while every fetched source defines them on %HRmax; and %HRR ≠ %HRmax (Swain 1997: %HRR ≈ %VO₂R; a 70 %HRmax sample is ≈ 59 %HRR for HRmax 190 / RHR 50). The header documents this honestly (#2835) but the zones remain unvalidated hybrids: below 50 %HRR (≈ 65 %HRmax) *all* load is zero, so brisk walking and most of a recreational Zone-2 ride score nothing. | **High** | It decides which days register at all. Banister-on-%HRR has no such hole, and %HRR is the validated axis; the Edwards weights were "arbitrary" even on their own axis (Halson 2014). |
| G2 | **Log-map anchor.** `D = 7201` maps 100 to a 24 h zone-5 day, so realistic days occupy 25–78 and the first 10 light minutes are worth 27 points (§2.3). Not a literature value; `fitStrainDenominator` exists but no fit ships. | **High** | Affects every Effort number, the ACWR/monotony inputs, and the imported-WHOOP comparison the owner will make. |
| G3 | **ACWR and monotony are computed on log-compressed Effort, not on load.** `ReadinessEngine` and `TrainingLoadEngine` consume the 0–100 Effort number. A week with double the TRIMP of the previous month shows an "ACWR" far below 2 (ln compression), and monotony's SD is squeezed, inflating mean/SD. Calendar gaps are also compacted (`compactMap`), so "7 values" can span more than 7 days. | **High** | The engine prints "sweet spot" / "spiking – higher injury risk" from a number that is not a ratio of loads. |
| G4 | **ACWR form and wording.** Rolling 7/28 means (coupled; Lolli 2019), bands and "higher injury risk" copy taken from Gabbett/Blanch 2016, which Impellizzeri 2020/2021 show add noise and no predictive value beyond acute load; evidence base is elite team sport only. | **High** (wording) / Medium (number) | NOOP's own rules (no claims a diagnostic cannot attribute; `docs/SCOPE.md`) forbid the current copy. |
| G5 | **Monotony threshold 2.0 and "illness risk" copy.** Foster 1998's finding was individual-threshold based; "2.0" is not in the abstract; associations are mixed (Jones 2017). | Medium | Keep the descriptive statistic ("how varied was the week"), drop the threshold flag and the illness phrasing. |
| G6 | **HRmax: 99.5th percentile of single samples.** Vulnerable to PPG artefacts (Shcherbina 2017: walking error highest; #2438 ring evidence: raw peak above formula on 58/60 days, sustained peak on none). Tanaka vs Nes is immaterial (both SEE ≈ 7–11 bpm). `220 − age` is still the silent fallback in `strain` when no HRmax is threaded. | Medium | HRmax error of 10 bpm shifts every %HRR by ~7–8 points and moves Edwards zones by most of a zone. |
| G7 | **Keytel applied outside its domain.** Validated on submaximal *exercise* stages; NOOP applies it per second across the whole day above a 50 %HRR gate (bout: 30 %). The VO₂max-variant coefficients could not be verified in any fetched text. Uth's VO₂max is validated only for well-trained men and loses accuracy with age-predicted HRmax (SEE 7.8 %). Hiilloskorpi (SEE 1.01 kcal/min with %HRR) is the equation whose *inputs* NOOP has in validated form. | Medium | Expected absolute error on daily active kcal is in the 15–30 % range from any HR method (Firstbeat Table 1/2; Shcherbina: no wrist device < 20 %); the equation choice moves the bias, not the order of magnitude. |
| G8 | **BMR equation.** Revised Harris–Benedict (±14 %, overestimates ≈ 5 % per Mifflin 1990) vs Mifflin–St Jeor (recommended by Frankenfield 2005). | Low–Medium | ~5 % systematic on resting kcal; one-line change plus a stored-value note (resting kcal is not persisted separately; `activeKcalEst` stores the total). |
| G9 | **Citation accuracy.** The header attributes the Banister pairs to Morton/Fitz-Clarke/Banister 1990; the fetched 1990 abstract states no coefficients, and every secondary source attributes the pair to Banister 1991 (book chapter). | Low | Documentation only; same class as commit `2d5e5a34`. |
| G10 | **Steps / active-energy floor** is documented in `ANALYTICS.md` but no implementation was found under `Packages/StrandAnalytics`. | Low | Either stale doc or app-layer code; needs locating before any load-model change so it is not double-counted. |

---

## 4. WHOOP 5.0 input constraints

| Input | Status on a 5.0 bonded only to NOOP (from `00-inventory.md` §1) | Effect on this topic | Degradation rule |
|---|---|---|---|
| Heart rate | Dense (nominally 1 Hz) when the R18 history offloads; live standard HR ~every 30 s while connected; gaps on v26-heavy stretches | TRIMP integrates fine over 30 s samples (`sampleDurationsMinutes` clamps gaps at 2 min); the sparse gate (#482) already exists | Keep per-sample durations; report **credited minutes / 1 440** as a coverage figure next to Effort (R4: completeness is a property of the input). Never fill gaps with activity. |
| PPG-derived filler HR (`ppgHrSample`, conf ≥ 0.3) | Default-on filler, flagged "Building" | Fine for load integration; **must not feed `estimateHRmax`** (artefact-prone by construction) and should not count toward a sustained peak | Thread the source flag; compute HRmax candidates from `hrSample` rows only. |
| Resting HR | From the detected sleep session (topic 02) | Both Banister and Keytel/Hiilloskorpi need it; a sleeping RHR is lower than a seated HRrest, so %HRR is slightly inflated by a constant | Use the daily RHR the rest of the app uses (one resolver), and document that %HRR is anchored to sleeping RHR. |
| HRmax | Not measured; age formula or observed peak | See G6 | Formula as the floor; sustained, multi-day observed peak may raise it; manual override wins. |
| R-R intervals | Sparse / filler beats at rest | Firstbeat-style respiration-aware EE is **not feasible**; Lucia/iTRIMP need lab thresholds anyway | Do not attempt R-R-based EE. |
| Motion / gravity | Sparse, 1 Hz at best; step counter present | No cadence/speed; no power | No external-load models (Charlot speed equation, power-based TSS) — HR-only, stated as such. |
| Power / speed | None | — | — |
| Profile | Age, sex, weight, height entered by the wearer | All EE equations need them; defaults (70 kg/170 cm/30 y/HRmax 220) silently apply when missing | When any profile field is missing, label kcal "Calibrating" rather than computing with defaults, mirroring `ScoreConfidence`. |

Design the normal case as: dense-but-gappy HR, sleeping RHR, no measured HRmax, no respiration, no motion.

---

## 5. Validation plan

### 5.1 Public datasets (all fetched and verified this session)

| Dataset | What it gives this topic | Access / license / size |
|---|---|---|
| **Treadmill Maximal Exercise Tests, University of Malaga** (PhysioNet `treadmill-exercise-cardioresp` 1.0.1; Mongin et al. 2021) | 992 maximal tests from 857 people (10–63 y, 15 % female) with **breath-by-breath HR, VO₂, VCO₂, VE, speed, age/sex/weight/height**. Supports: (a) HR→EE equation error (Keytel base vs Hiilloskorpi-style %HRR vs Mifflin-anchored) against indirect calorimetry; (b) **HRmax formula SEE** on 857 people (Tanaka / Nes / Gellish vs measured HRmax); (c) %HRR vs %VO₂R check (Swain). No resting HR, so Uth's ratio cannot be tested here. | PhysioNet Contributor Review Health Data License 1.5.0 + DUA (free, sign-up); 22 MB. DOI 10.13026/7ezk-j442. |
| **WEEE** (Zenodo 10.5281/zenodo.6420886; Gashi et al. 2022, *Sci Data*) | 17 adults (23–41 y, 12 m / 5 f), 30-min protocol (sit, stand, cycle ×2 speeds, run ×2 speeds) with **VO2 Master calorimeter**, Wahoo Tickr chest HR, **Empatica E4 wrist PPG**, Apple Watch S6, Fitbit Sense, Zephyr BioHarness. Supports an end-to-end wrist-PPG → HR → kcal test and a chest-vs-wrist sensitivity of TRIMP. | CC BY 4.0; 652 MB. |
| **PPG-DaLiA** (UCI 10.24432/C53890; Reiss et al. 2019) | 15 subjects, Empatica E4 wrist (BVP 64 Hz, ACC 32 Hz) + RespiBAN chest ECG 700 Hz, activity labels in near-daily-life conditions. No calorimetry. Supports HR-estimation error under motion and activity-labelled bouts for `WorkoutDetector`. | CC BY 4.0; 2.7 GB. |
| **Pulse Transit Time PPG** (PhysioNet 10.13026/jpan-6n92) | 22 subjects, finger PPG (red/IR/green) + 3-lead ECG + IMU during sit/walk/run. Finger site, so low relevance; listed for completeness. | ODbL 1.0; 2.9 GB. |

**No public free-living dataset with wrist HR and indirect calorimetry was found** (search this session;
R8: stated as a result). Daily total-energy accuracy is therefore **not measurable** from public data;
only per-bout accuracy is.

No public dataset carries WHOOP Strain beside raw HR; WHOOP's scale cannot be validated from public data.

### 5.2 Metrics to report (R4, R7)

- HRmax formulas: SEE and mean signed bias (bpm) vs measured HRmax, by decade of age and by sex; n per stratum.
- EE equations: per-test MAE and MAPE (kcal) vs calorimetry over the *submaximal* portion, Bland–Altman bias and
  LoA, stratified by %HRR band (≤ 50, 50–70, > 70) because the gates in `Calories` live there.
- TRIMP sensitivity: Δ Effort per +5 and +10 bpm HRmax error and per +5 bpm RHR error on a fixed HR day (replay
  old vs new, R4 row 1); credited-minutes coverage printed beside each Effort.
- Load-scale fit: for any candidate `(T₀, T_ref)`, MAE of the mapped Effort vs reference strain (0–100) on the
  held-out half, plus the fitted parameters on each temporal half (R5: a parameter that moves a lot between halves
  is not a constant).
- ACWR/monotony: replay on identical histories computed from TRIMP vs from Effort; report the fraction of days
  whose band label changes. This is a behaviour-change measurement, not an accuracy claim.

### 5.3 Validation with the owner's own data

1. **WHOOP CSV export (pre-NOOP history).** The `workouts` export carries per-workout zone durations, average and
   max HR, duration and Activity Strain; the `physiological cycles` export carries Day Strain. Reconstruct an
   Edwards-style load per workout from WHOOP's zone minutes (their zones are %HRmax-based, so this also quantifies
   G1), then fit `(T₀, T_ref)` with the existing `fitStrainDenominator` form on the **first half by date** and
   report MAE on the second half (R1/R5 — pre-register the target MAE and the half split before running). The
   fit only locates NOOP's documented curve; it does not recover WHOOP's algorithm.
2. **Polar H10 chest strap** worn with the 5.0 on workouts: per-second HR agreement (bias, LoA, by %HRR band),
   then Effort computed from each stream — this measures how much of Effort's error is sensor error vs model.
   Also yields a chest-strap sustained peak to check the observed-HRmax rule on real hard sessions.
3. **Treadmill or power meter** (if available): external work vs TRIMP across sessions of known pace/power;
   Spearman rank and the shape of the relation (log vs linear) is the test of the mapping's monotonicity.
4. **Calories cannot be validated personally** — no calorimeter. Comparing with Apple Watch would be two estimates,
   not a measurement (R8). Report kcal with a stated ±20–30 % band instead.
5. Data stays under `research-data/` (git-ignored); the harness lives under `Tools/` as a Swift package in the
   `SleepPSG` pattern, printing its regenerating command (R3).

---

## 6. Implementation sketch

Order reflects expected impact and dependency: I1 (wording) and I4 (load units) carry no accuracy risk and can
ship first; I2 and I3 change scores and need the §5 numbers before they leave an Experimental flag.

### I1 — Remove risk language; keep the statistics (effort S, risk none, parity: copy only)

`ReadinessEngine` (`acwrSignal`, monotony `Signal`): replace "higher injury risk" / "raises strain/illness risk"
with descriptive text ("acute load well above your 4-week level"; "little day-to-day variation this week"), drop
the `.bad` flag for ACWR ≥ 1.5 (make it `.watch`), remove the 0.8–1.3 "sweet spot" label. Cite Impellizzeri 2020/2021
in the header. Kotlin: same strings in `ReadinessEngine.kt` and the localisation catalogues (i18n gate).

### I2 — Load units for ACWR / monotony / CTL-ATL (effort M, risk low, parity: oracle on a synthetic 60-day series)

Persist the day's **TRIMP** (linear load) beside `strain` (new `metricSeries` key `trimp`, additive migration on
both platforms; column order pinned by test) and switch the three consumers to it. Replace the coupled rolling
ratio with uncoupled EWMAs and expose absolute acute load:

```
// Shared pseudocode (Swift and Kotlin must be byte-identical; oracle = Swift stdout as Kotlin literal)
lambda(N) = 2.0 / (N + 1.0)                     // Williams 2017 form, as reproduced by Cousins 2019
acute   = ewma(trimpByCalendarDay, N = 7)       // missing calendar day → nil, never 0 (TrainingLoadEngine rule)
chronic = ewma(trimpByCalendarDay[..< today-7], N = 28)   // UNCOUPLED: chronic window ends before the acute window
acuteSum7 = sum(last 7 calendar days)           // the quantity with the best fetched evidence (Cousins 2019)
monotony  = mean7 / sampleSD7                   // Foster 1998 definition, descriptive, no threshold flag
weeklyStrainFoster = acuteSum7 * monotony       // name it "Foster strain" to avoid colliding with the `strain` key
```

Display: "this week vs your usual" as two numbers and a ratio *without* bands; keep `TSB` from
`TrainingLoadEngine` but feed it TRIMP (its header already says Effort is the wrong unit).

### I3 — Effort scale re-anchor (effort M, risk medium: every Effort moves; Experimental flag until §5.3 step 1 is done)

```
func effort(trimp: Double, t0: Double, tRef: Double) -> Double {
    guard trimp > 0, t0 > 0, tRef > t0 else { return 0 }
    let v = 100 * log(1 + trimp / t0) / log(1 + tRef / t0)
    return min(100, (v * 100).rounded() / 100)
}
// defaults (documented, not fitted): t0 = 10, tRef = 1000 (Edwards-style); Banister: tRef = its own 1000-equivalent
// (the Banister TRIMP of the same reference day), so the two recipes share anchors instead of ceilings.
```

Fit path: extend `fitStrainDenominator` to a two-parameter fit (grid over `t0 ∈ {5,10,20,40}`, closed-form `tRef`
per `t0`), run on the owner's export per §5.3, publish the fitted values on both temporal halves. Stored history:
keep writing `strain`; add the scale version to the row (`strainScale = 2`) so old rows are not re-read as new.
Imported WHOOP days keep the `100/21` proportional rule. Kotlin twin + oracle over a spread of TRIMP values.

### I4 — Recipe default and zone honesty (effort S–M, risk medium, parity: existing `BanisterParityOracleTest` extended)

Make Banister-on-%HRR the default (G1), keep Edwards-style as the secondary. If Edwards is kept at all, either
(a) re-cut on %HRmax as published (then it needs no RHR) or (b) rename the method `.hrrZones` and stop citing
Edwards for its cut-offs. Either is a scoring change gated on I3's harness; (b) is the cheaper honest fix.

### I5 — HRmax resolver (effort S, risk low, parity: pure function oracle)

```
func resolveHRmax(age: Double?, manual: Double?, sustainedPeaks: [(day: String, bpm: Double, source: HRSource)]) -> (Double, String) {
    if let m = manual { return (m, "manual") }
    let formula = age.map { 211 - 0.64 * $0 }            // Nes 2013 (SEE 10.8) — or keep Tanaka; difference < SEE
    // candidates: hrSample rows only (never ppgHrSample), 5 consecutive samples within 60 s (sustainedPeak),
    // reached on ≥ 2 distinct days in the trailing 90 (the #2438 step-0 rule)
    let observed = sustainedPeaks.filter { $0.source == .strap }.reachedOnTwoDays(within: 90)
    switch (formula, observed) {
    case (let f?, let o?): return o > f ? (o, "observed") : (f, "formula")
    case (let f?, nil):    return (f, "formula")
    case (nil, let o?):    return (o, "observed")
    default:               return (0, "unknown")           // caller refuses to score, never 220 − age
    }
}
```

Remove the `220 − age` fallback from `strain` (refuse instead, with the funnel line naming the gap).

### I6 — Calories (effort M, risk low–medium, parity: `DayCaloriesTest` oracle over a spread of HR/profile cases)

- BMR → Mifflin–St Jeor (`10·W + 6.25·h − 5·A + 5 / −161`; nonbinary = midpoint, as today).
- Active rate → a **%HRR-based** equation (Hiilloskorpi 2003 form) once its coefficients can be verified from the
  paper; until then keep Keytel base (its coefficients are verified) and **drop the Uth VO₂max branch** unless the
  wearer has entered a measured VO₂max (G7): the branch is validated only for well-trained men with measured HRmax.
- Keep the day/bout gates; persist `restingKcal` and `activeKcal` separately (additive migration) so Apple Health
  gets *active* energy only (topic 10).
- Label: "Estimated from heart rate; typical error 15–30 %" (Firstbeat tables, Shcherbina 2017).

### I7 — Coverage beside Effort (effort S, risk none)

Print credited minutes (Σ clamped durations) and expected minutes on the funnel line and in the UI tooltip; mark
Effort "Building" when coverage < 50 %, matching `ScoreConfidence`.

### I8 — Harness (effort M, prerequisite for I3/I4/I6 leaving the flag)

`Tools/LoadBench`: Swift package that (a) replays `StrainScorer` over a DB copy and prints Effort old/new per day
with coverage; (b) reads the Malaga PhysioNet CSVs and prints HRmax-formula SEE and HR→kcal MAPE per equation;
(c) reads the WHOOP CSV export and performs the §5.3 fit with the temporal split, printing both halves.

---

## 7. Sources (verified)

Format: citation — identifier — what was verified from the fetched text.

1. Morton RH, Fitz-Clarke JR, Banister EW. *Modeling human performance in running.* J Appl Physiol 1990;69(3):1171-7.
   PMID 2246166 — fitness/fatigue impulse-response model; **abstract states no TRIMP coefficients**.
2. Bok D, Jukić N, Foster C. *Validation of session ratings of perceived exertion for quantifying training load in
   karate kata sessions.* Biol Sport 2022;39(4):849-55. DOI 10.5114/biolsport.2022.109458, PMC9536392 — Edwards zones
   (50–60…90–100 %HRmax × 1–5, citing Edwards 1993) and Banister TRIMP with 0.64/1.92 men, 0.86/1.67 women (citing
   Banister 1991); sRPE = RPE × minutes (Foster 2001).
3. Shaw JW et al. *The validity of the session rating of perceived exertion method … professional classical ballet
   dancers.* Front Physiol 2020;11:480. DOI 10.3389/fphys.2020.00480, PMC7240108 — same Edwards/Banister definitions
   and pairs; HRmax = max(Tanaka, observed peak); rmcorr sRPE vs Edwards 0.81, Banister 0.79.
4. Hourcade J-C et al. *Effects of intensity distribution changes on performance and on training loads
   quantification.* Biol Sport 2018;35(1):67-74. DOI 10.5114/biolsport.2018.70753, PMC6135970 — Edwards zones;
   Banister men's formula citing Banister & Hamilton 1985.
5. Halson SL. *Monitoring training load to understand fatigue in athletes.* Sports Med 2014;44(S2):139-47.
   DOI 10.1007/s40279-014-0253-z, PMC4213373 — Edwards zones "arbitrary"; Lucia uses three threshold-based zones;
   iTRIMP reduces arbitrary-zone issues.
6. Lucia A et al. *Tour de France versus Vuelta a España: which is harder?* Med Sci Sports Exerc 2003;35(5):872-8.
   DOI 10.1249/01.MSS.0000064999.82036.B4, PMID 12750600 — three intensity phases from VT and RCP; load = volume × intensity.
7. Nuuttila O-P et al. *Monitoring fatigue state with heart rate-based and subjective methods during intensified
   training in recreational runners.* Eur J Sport Sci 2024;24(7):857-69. DOI 10.1002/ejsc.12115, PMC11235883 — Lucia
   zone weights 1/2/3; 24 recreational runners; nocturnal HR and HR–power index tracked fatigue, load measures did not.
8. Manzi V et al. *Relation between individualized training impulses and performance in distance runners.*
   Med Sci Sports Exerc 2009;41(11):2090-6. DOI 10.1249/MSS.0b013e3181a6a959, PMID 19812506 — iTRIMP correlations
   r = 0.87/0.74 (lactate speeds), −0.77/−0.82 (race times), n = 8; nothing with group-average values.
9. Stagno KM, Thatcher R, van Someren KA. *A modified TRIMP to quantify the in-season training load of team sport
   players.* J Sports Sci 2007;25(6):629-34. DOI 10.1080/02640410600811817, PMID 17454529 — TRIMP_MOD, 8 hockey players;
   no equation in abstract.
10. Karvonen MJ, Kentala E, Mustala O. *The effects of training on heart rate; a longitudinal study.* Ann Med Exp Biol
    Fenn 1957;35(3):307-15. PMID 13470504 — record exists; **no abstract available**, formula not verifiable from it.
11. Swain DP, Leutholtz BC. *Heart rate reserve is equivalent to %VO2 reserve, not to %VO2max.* Med Sci Sports Exerc
    1997;29(3):410-4. DOI 10.1097/00005768-199703000-00018, PMID 9139182 — slopes/intercepts, n = 63.
12. Tanaka H, Monahan KD, Seals DR. *Age-predicted maximal heart rate revisited.* J Am Coll Cardiol 2001;37(1):153-6.
    PMID 11153730 — 208 − 0.7·age (meta, 18 712 subjects, r = −0.90), 209 − 0.7·age (lab, n = 514); no SEE in abstract.
13. Gellish RL et al. *Longitudinal modeling of the relationship between age and maximal heart rate.* Med Sci Sports
    Exerc 2007;39(5):822-9. PMID 17468581 — 207 − 0.7·age; 132 people, 908 tests.
14. Nes BM et al. *Age-predicted maximal heart rate in healthy subjects: The HUNT Fitness Study.* Scand J Med Sci Sports
    2013;23(6):697-704. PMID 22376273 — 211 − 0.64·age, SEE 10.8 bpm, n = 3 320.
15. Robergs RA, Landwehr R. *The surprising history of the "HRmax = 220-age" equation.* JEPonline 2002;5(2):1-10.
    URL https://www.asep.org/asep/asep/Robergs2.pdf (PDF fetched, text extracted) — 220 − age has no original data;
    Fox 1971 re-fit Sxy 21; 30-equation re-fit 208.754 − 0.734·age, Sxy 7.2; Inbar 205.8 − 0.685·age, Sxy 6.4.
16. Shcherbina A et al. *Accuracy in wrist-worn, sensor-based measurements of heart rate and energy expenditure in a
    diverse cohort.* J Pers Med 2017;7(2):3. DOI 10.3390/jpm7020003, PMID 28538708 — 60 adults, 7 devices; HR error < 5 %
    (cycling) for six devices; **no device < 20 % EE error**; worse with walking, BMI, darker skin.
17. Etiwy M et al. *Accuracy of wearable heart rate monitors in cardiac rehabilitation.* Cardiovasc Diagn Ther
    2019;9(3):262-71. DOI 10.21037/cdt.2019.04.08, PMID 31275816 — rc vs ECG: Polar H7 0.99, wrist devices 0.52–0.80.
18. Fuller D et al. *Reliability and validity of commercially available wearable devices … systematic review.*
    JMIR Mhealth Uhealth 2020;8(9):e18694. DOI 10.2196/18694, PMID 32897239 — 158 publications; no brand accurate for EE.
19. O'Driscoll R et al. *How well do activity monitors estimate energy expenditure? …* Br J Sports Med 2020;54(6):332-40.
    DOI 10.1136/bjsports-2018-099643, PMID 30194221 — 60 studies/104 effect sizes; I² > 75 %; HR/heat sensing reduces error.
20. Keytel LR et al. *Prediction of energy expenditure from heart rate monitoring during submaximal exercise.*
    J Sports Sci 2005;23(3):289-97. DOI 10.1080/02640410470001730089, PMID 15966347 — n = 115; R² 0.833 with VO₂max,
    0.734 without; no coefficients in abstract.
21. Chiu Y-W et al. *Day-to-day variation of the heart rate, heart rate variability, and energy expenditure during
    FIFA 11+ …* J Hum Kinet 2022;81:73-84. DOI 10.2478/hukin-2022-0007, PMC8884869 — reproduces Keytel base equations
    (men −55.0969 + 0.6309·HR + 0.1988·W + 0.2017·A; women −20.4022 + 0.4472·HR − 0.1263·W + 0.074·A).
22. Hiilloskorpi HK et al. *Use of heart rate to predict energy expenditure from low to high activity levels.*
    Int J Sports Med 2003;24(5):332-6. DOI 10.1055/s-2003-40701, PMID 12868043 — n = 89; SEE 1.41 (HR), 1.01 (%HRR),
    1.08 (HRnet) kcal/min.
23. Charlot K et al. *Improvement of energy expenditure prediction from heart rate during running.* Physiol Meas
    2014;35(2):253-66. DOI 10.1088/0967-3334/35/2/253, PMID 24434852 — R² 0.809 → 0.879 with VO₂max; speed best.
24. Brage S et al. *Hierarchy of individual calibration levels for heart rate and accelerometry to measure physical
    activity.* J Appl Physiol 2007;103(2):682-92. DOI 10.1152/japplphysiol.00092.2006, PMID 17463305 — variance explained
    by calibration level (95 % → 30 %).
25. Uth N et al. *Estimation of VO2max from the ratio between HRmax and HRrest – the Heart Rate Ratio Method.*
    Eur J Appl Physiol 2004;91(1):111-5. DOI 10.1007/s00421-003-0988-y, PMID 14624296 — factor 15.3; SEE 4.5 % / 7.8 %
    (age-predicted HRmax); 46 well-trained men.
26. Firstbeat Technologies. *An Energy Expenditure Estimation Method Based on Heart Rate Measurement* (white paper, PDF
    fetched from firstbeat.com and text-extracted). **Vendor documentation.** n = 32; MAPE 10.9 % (HR + respiration +
    on/off kinetics), 13.5 % / 14.4 % flex-HR, 22.0 % / 27.6 % regressions; HR-level methods 20–35 % (their Table 2).
27. Roza AM, Shizgal HM. *The Harris Benedict equation reevaluated.* Am J Clin Nutr 1984;40(1):168-82.
    DOI 10.1093/ajcn/40.1.168, PMID 6741850 — precision ±14 % in well-nourished adults; coefficients not in abstract.
28. Mifflin MD et al. *A new predictive equation for resting energy expenditure in healthy individuals.* Am J Clin Nutr
    1990;51(2):241-7. DOI 10.1093/ajcn/51.2.241, PMID 2305711 — equations, n = 498, R² 0.71; HB overestimates by 5 %.
29. Frankenfield D, Roth-Yousey L, Compher C. *Comparison of predictive equations for resting metabolic rate …*
    J Am Diet Assoc 2005;105(5):775-89. DOI 10.1016/j.jada.2005.02.005, PMID 15883556 — Mifflin within 10 % in more
    individuals; recommended.
30. Foster C. *Monitoring training in athletes with reference to overtraining syndrome.* Med Sci Sports Exerc
    1998;30(7):1164-8. DOI 10.1097/00005768-199807000-00023, PMID 9662690 — monotony = mean/SD, strain = load × monotony;
    individual thresholds; **no numeric monotony threshold in abstract**.
31. Jones CM, Griffiths PC, Mellalieu SD. *Training load and fatigue marker associations with injury and illness: a
    systematic review of longitudinal studies.* Sports Med 2017;47(5):943-74. DOI 10.1007/s40279-016-0619-5, PMC5394138 —
    68 studies; mixed monotony/strain findings (values quoted in §2.4).
32. Gabbett TJ. *The training-injury prevention paradox.* Br J Sports Med 2016;50(5):273-80. DOI 10.1136/bjsports-2015-095788,
    PMID 26758673 — ACWR named the critical variable; no numbers in abstract.
33. Hulin BT et al. *Spikes in acute workload are associated with increased injury risk in elite cricket fast bowlers.*
    Br J Sports Med 2014;48(8):708-12. DOI 10.1136/bjsports-2013-092524, PMID 23962877 — RR 2.2/2.1; > 200 % RR 4.5/3.3.
34. Hulin BT et al. *The acute:chronic workload ratio predicts injury: high chronic workload may decrease injury risk in
    elite rugby league players.* Br J Sports Med 2016;50(4):231-6. DOI 10.1136/bjsports-2015-094817, PMID 26511006 — n = 53;
    ACWR ≥ 2.11 → 16.7 %; 0.85–1.35 with high chronic load lower risk.
35. Blanch P, Gabbett TJ. *Has the athlete trained enough to return to play safely? …* Br J Sports Med 2016;50(8):471-5.
    DOI 10.1136/bjsports-2015-095445, PMID 26701923 — R² = 0.53 polynomial (erratum 2019, DOI …095445corr1).
36. Murray NB et al. *Calculating acute:chronic workload ratios using exponentially weighted moving averages …*
    Br J Sports Med 2017;51(9):749-54. DOI 10.1136/bjsports-2016-097152, PMID 28003238 — 59 AFL players; EWMA > 2.0 RR 6.52–21.28.
37. Williams S, West S, Cross MJ, Stokes KA. *Better way to determine the acute:chronic workload ratio?* Br J Sports Med
    2017;51(3):209-10. DOI 10.1136/bjsports-2016-096589, PMID 27650255 — **metadata only** (letter; no abstract; publisher
    page not fetchable). EWMA formula taken from Cousins 2019's reproduction.
38. Cousins BEW et al. *Match and training load exposure and time-loss incidence in elite rugby union players.*
    Front Physiol 2019;10:1413. DOI 10.3389/fphys.2019.01413, PMC6877544 — EWMA formula with λ = 2/(N+1), N = 7/28
    (attributed to Williams 2017); absolute sRPE best predictor (OR 1.11/100 AU); ACWR sRPE n.s.
39. Lolli L et al. *Mathematical coupling causes spurious correlation within the conventional acute-to-chronic workload
    ratio calculations.* Br J Sports Med 2019;53(15):921-2. DOI 10.1136/bjsports-2017-098110, PMID 29101104 — editorial;
    **title/metadata verified**, argument restated by Maupin 2020.
40. Windt J, Gabbett TJ. *Is it all for naught? What does mathematical coupling mean for acute:chronic workload ratios?*
    Br J Sports Med 2019;53(16):988-90. DOI 10.1136/bjsports-2017-098925, PMID 29807930 — metadata verified.
41. Impellizzeri FM et al. *Acute:chronic workload ratio: conceptual issues and fundamental pitfalls.* Int J Sports Physiol
    Perform 2020;15(6):907-13. DOI 10.1123/ijspp.2019-0864, PMID 32502973 — "no evidence supporting the use of ACWR".
42. Impellizzeri FM et al. *What role do chronic workloads play in the acute to chronic workload ratio? Time to dismiss
    ACWR and its underlying theory.* Sports Med 2021;51(3):581-92. DOI 10.1007/s40279-020-01378-6, PMID 33332011 — random
    chronic loads reproduce the effect; no gain over intercept-only model.
43. Maupin D, Schram B, Canetti E, Orr R. *The relationship between acute:chronic workload ratios and injury risk in
    sports: a systematic review.* Open Access J Sports Med 2020;11:51-75. DOI 10.2147/OAJSM.S231405, PMC7047972 — 27 studies;
    0.80–1.30 "trend", OR 0.59 (0.14–2.45); EWMA "potentially" more sensitive; coupling concern; "use it cautiously".
44. Borresen J, Lambert MI. *The quantification of training load, the training response and the effect on performance.*
    Sports Med 2009;39(9):779-95. DOI 10.2165/11317780-000000000-00000, PMID 19691366 — no single marker reliable;
    models "poor accuracy" (abstract).
45. Garber CE et al. *ACSM position stand: quantity and quality of exercise …* Med Sci Sports Exerc 2011;43(7):1334-59.
    DOI 10.1249/MSS.0b013e318213fefb, PMID 21694556 — dose recommendations; **%HRR intensity bands not in abstract**.
46. Mongin D, García Romero J, Alvero Cruz JR. *Treadmill Maximal Exercise Tests from the Exercise Physiology and Human
    Performance Lab of the University of Malaga* (v1.0.1). PhysioNet, DOI 10.13026/7ezk-j442; paper DOI
    10.1080/15438627.2021.1954513 — contents, license and size as in §5.1.
47. Gashi S, Min C, Montanari A, Santini S, Kawsar F. *A multidevice and multimodal dataset for human energy expenditure
    estimation using wearable devices.* Sci Data 2022;9:537. DOI 10.1038/s41597-022-01643-5, PMC9436988; data
    DOI 10.5281/zenodo.6420886 (Zenodo page fetched: CC BY 4.0, 651.6 MB) — devices, protocol, participants as in §5.1.
48. Reiss A, Indlekofer I, Schmidt P. *PPG-DaLiA.* UCI ML Repository 2019, DOI 10.24432/C53890 — 15 subjects, E4 + RespiBAN,
    CC BY 4.0, 2.7 GB.
49. *Pulse Transit Time PPG Dataset* v1.1.0, PhysioNet, DOI 10.13026/jpan-6n92 — 22 subjects, finger PPG + ECG + IMU, ODbL.
50. WHOOP developer documentation: https://developer.whoop.com/docs/developing/user-data/cycle/ and
    …/user-data/workout/ and https://developer.whoop.com/api/ — **vendor documentation**; confirm `strain`,
    `kilojoule`, `average_heart_rate`, `max_heart_rate`, zone durations `zone_zero_milli…zone_five_milli` exist as fields;
    no scale or formula text.

---

## 8. Unverified leads

- **WHOOP "How does WHOOP Strain work 101" / Strain support pages** (`whoop.com/…/thelocker/how-does-whoop-strain-work-101`,
  `support.whoop.com/s/article/Strain-101`): HTTP 403 / 404 to the fetcher on 2026-11-10. Only search-result excerpts
  were seen (0–21, logarithmic, HR-zone based, personalised to max HR, muscular load from logged sets). The commonly
  quoted band edges (light 0–9, moderate 10–13, strenuous 14–17, all-out 18–21) were **not** fetched and are not
  relied on above.
- **Banister EW (1991). "Modeling elite athletic performance", in *Physiological Testing of Elite Athletes*, Human
  Kinetics** — book chapter, not fetchable; the 0.64/1.92 and 0.86/1.67 pairs are attributed to it by sources 2 and 3.
- **Banister & Hamilton (1985)** — cited by Hourcade 2018 for the men's formula; not fetched.
- **Edwards S (1993). *The Heart Rate Monitor Book*** — book; zone definition verified only via sources 2–4.
- **Fox SM, Naughton JP, Haskell WL (1971)** Ann Clin Res 3:404-32 — origin of 220 − age; described by Robergs 2002, not fetched.
- **Inbar O et al. (1994)** 205.8 − 0.685·age, Sxy 6.4 — via Robergs 2002's table only.
- **Keytel 2005 VO₂max-variant coefficients** (−95.7735, 0.634, 0.404, 0.394, 0.271 / −59.3954, 0.45, 0.380, 0.103,
  0.274) as shipped in `Calories.Coeffs.fit*` — not found in any fetched text; needs the paper's full text.
- **Hiilloskorpi 2003 equation coefficients** — abstract gives SEEs only; needed before I6 can adopt the %HRR form.
- **Tanaka 2001 SEE (~10 bpm)** — not in the abstract; the "≈ 10 bpm" figure in the brief is consistent with Nes 2013's
  10.8 and Robergs' 7–11 range but is not verified for Tanaka itself.
- **Lucia et al. 2000** (the earlier Lucia TRIMP reference cited by Halson 2014) — not fetched.
- **Foster "monotony > 2.0" threshold** — no fetched source states it; treat as convention.
- **ACSM %HRR intensity categories** (light 30–39, moderate 40–59, vigorous 60–89 %HRR) — not in the Garber 2011 abstract;
  the Norton et al. 2010 position statement (DOI 10.1016/j.jsams.2009.09.008) was fetched but its abstract carries no
  bands either.
- **Steps / active-energy Effort floor** — documented in `docs/ANALYTICS.md`; implementation not located under
  `Packages/StrandAnalytics` in this pass.

# 06 – Recovery / readiness composite

Written 2026-11-10 on branch `research/metrics-literature` against tree `2a1de760`. Phase 1 research
deliverable per `RESEARCH_BRIEF.md` §5.1 topic 06 and §5.2 template. Every source in §7 was fetched this
session (Europe PMC abstract records, publisher full text, or vendor manual pages); anything not fetched
sits in §8 and carries no recommendation. All numbers quoted from papers are **inherited** from those
fetched texts (R7); nothing here was re-measured on NOOP data. Wording is non-medical throughout
(`docs/SCOPE.md`): a readiness score describes trends in a wearer's own numbers, nothing more.

---

## 1. What NOOP does today

### 1.1 The composites (Swift + Kotlin)

| Engine | Swift | Kotlin | What it produces |
|---|---|---|---|
| `RecoveryScorer` ("Charge", the shipped headline) | `Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift` | `android/app/src/main/java/com/noop/analytics/RecoveryScorer.kt` | 0–100 z-score + logistic composite, HRV-led. |
| `ReadinessEngine` (Today "Readiness" card) | `ReadinessEngine.swift` | `ReadinessEngine.kt` | primed / balanced / strained / rundown tier from HRV, RHR, resp z plus ACWR and Foster monotony. |
| `HRVReadiness` (opt-in, `noopHrvReadiness` flag, default OFF) | `HRVReadiness.swift` | `HRVReadiness.kt` | Plews/Altini SWC tier: 7-night ln RMSSD mean vs 60-night (fallback 30) band ±0.5 SD; `minNights 14`; informational overreaching watch. |
| `IllnessSignalEngine` / `V5HealthSignals` (Android plumbing) | `IllnessSignalEngine.swift` | `IllnessSignalEngine.kt`, `V5HealthSignals.kt` | Heads-up from ≥ 2 of RHR↑ / HRV↓ / temp↑ / resp↑ at \|z\| ≥ 2, confounder dampening 0.45. |
| `ScoreConfidence` | `ScoreConfidence.swift` | Android helpers | calibrating / building / solid tier per score. |

### 1.2 `RecoveryScorer.recovery(...)` — method and parameters (CONFIRMED from source)

- Inputs: tonight's `hrv` (RMSSD ms, **required**, non-optional), `rhr` (bpm), optional `resp`,
  `sleepPerf` (= Rest composite ÷ 100, not raw efficiency — `AnalyticsEngine.swift` ~L929), optional
  `skinTempDev` (°C from personal baseline), plus two optional terms that **no shipped caller supplies**
  (`recoveryIndexSlope`, `priorDayEffort`+`effortBaseline` — `AnalyticsEngine` passes neither).
- Per-driver z: `(value − mean) / (1.253 · spread)` where `spread` is the EWMA mean-absolute-deviation
  from `Baselines` (`1.253 ≈ 1/√(2/π)`). HRV z is computed in **raw ms** (`Baselines.hrvCfg`, bounds
  5–250 ms, floor spread 5 ms); RHR and resp are "lower is better" (`(μ − x)/σ`).
- Sleep term has no personal baseline: `(sleepPerf − 0.85) / 0.12`.
- Skin-temp term: symmetric penalty `−|dev| / 1.0 °C`.
- Weights: `wHRV 0.55, wRHR 0.20, wSleep 0.15, wResp 0.05, wSkinTemp 0.05` (+ `wRecoveryIndex 0.05`,
  `wActivityBalance 0.05` when supplied). Missing terms drop and the remaining weights renormalise.
- Squash: `100 / (1 + exp(−1.6 · (z − (−0.20))))`, so z = 0 → ≈ 58 % (`populationMean 58.0`, attributed in
  the source comment to a WHOOP-published member average). Bands: red < 34, yellow < 67, green ≥ 67.
- Cold start: nil unless the HRV baseline is `usable` (≥ `Baselines.minNightsSeed = 4` valid nights).
  `trusted` at 14. An unusable RHR/resp baseline is treated as absent (#1988).
- Parasympathetic-saturation guard (`satEnterZ 0.5, satFullZ 1.5, satMaxDampFraction 0.5`): fires when
  HRV z ≤ −0.5 **and** RHR term ≥ +0.5 (both "low"); computes an eased HRV z but **does not apply it**
  (instrument-first; zero real firings in ~2 weeks of validation per the source comment).
- Kotlin twin carries byte-identical constants (CONFIRMED by grep: `wHRV 0.55 … satMaxDampFraction 0.5`,
  `skinTempDevScale 1.0`). `agreement/RecoveryAgreementTest.kt` pins all constants against a numpy
  replication (`recovery_cases.json`, local fixture, skips in CI) — the oracle pattern any change must repeat.

### 1.3 The three coexisting baseline machineries (the inventory's cross-cutting item 2)

| Machinery | Used by | Window / memory | Domain for HRV | Cold start | Outlier handling |
|---|---|---|---|---|---|
| `Baselines` Winsorized EWMA (`update` / `foldHistory`) | `RecoveryScorer` (Charge), `IllnessSignalEngine` on iOS, skin-temp deviation | centre half-life 14 nights, spread half-life 21; `earlyHalfLifeB 3` for the first 8 nights; `staleDays 14`; `ChargeBaselines` restricts the folded history to a 21-day window (#2525, imports only seed) | **raw ms** (`hrvCfg`) | usable at 4, trusted at 14 | hard reject > 5 × spread (suspended while young), Winsor ±3 × spread |
| `ReadinessEngine.zSignal` | Readiness card | trailing **30** daily rows, min 7 valid, re-folded through the same EWMA spine with `rejectHardOutliers: false` | **ln ms** (`readinessHRVLnCfg`, floor 0.08 ln) | 7 | Winsor only |
| `V5HealthSignals.zAgainst` (Android only) | Cycle / circadian / illness engines on Android | trailing **30** rows, plain mean + sample SD, min 14 | raw ms | 14 | none |
| (`HRVReadiness`, opt-in) | tier readout | 7-night mean vs 60 (fallback 30) nights, SD floor 1e-9 | ln ms | 14 | bounds only |

So "how unusual is tonight's HRV" is answered by three different windows and two different domains
depending on which screen asks, which is the "two readouts of one fact" shape `AGENTS.md` forbids.

### 1.4 Sources already cited in code / docs

Plews 2013, Buchheit 2014, Bellenger 2016, Lamberts 2004, Gabbett 2016, Foster 1998 (all named in
`ReadinessEngine` / `RecoveryScorer` comments); WHOOP population mean 58 % (anchor only, no URL in
source). `docs/RR-OPTIMIZATION.md` findings 3 and 5 and "Candidate changes not yet shipped" are the only
real-data evidence on recovery weights in the tree (n = 8 nights, one wearer; a second wearer n = 20):
WHOOP recovery correlated with sleep performance r 0.80, HRV/RHR ratio r 0.78, HRV r 0.74, RHR r −0.63;
resp and skin temp ≈ 0; ln RMSSD slightly worsened r (0.819 → 0.810) on a narrow HRV range;
`logisticK 1.6` "too steep" (LOO MAE ≈ 20 → ≈ 9 with a gentler slope); a multi-parameter fit reached
0.849 in-sample but 0.575 LOO. All explicitly unshipped for sample-size reasons.

---

## 2. Recommended method(s) from the literature

### 2.1 Which inputs carry signal, and in which direction

**HRV (ln RMSSD) is the best-supported single driver, but only as an averaged trend, and it is
sensitive rather than specific.**

- Bellenger et al. 2016 (meta-analysis, 24 studies, endurance-trained): training that *improved*
  performance raised resting RMSSD (SMD 0.58, P < 0.001). Training that *decreased* performance
  (overreaching) changed resting RMSSD only slightly (SMD 0.26) and HFP not at all (0.04). Resting HRV
  therefore does **not** reliably fall with overreaching — a "low HRV = not recovered" model is
  incomplete on its own.
- Le Meur et al. 2013 (RCT, 21 triathletes, 3-week overload): functionally overreached athletes showed a
  −9.0 ± 2.1 % performance drop with *higher* weekly-averaged ln RMSSD (96–98 % probability of a positive
  effect) and *lower* resting HR; single weekly recordings showed no clear effect because of day-to-day
  variability. Direction of HRV alone misleads; HR moved the opposite way.
- Altini & Plews 2021 (28,175 users, ~9 M morning measurements): sickness → HR +6 % (d 0.97), rMSSD −10 %
  (d 0.47); high alcohol → HR +6 % (d 0.97), rMSSD −12 % (d 0.55); high- vs low-intensity training → HR
  +0.7 / −0.6 % (d 0.38), rMSSD −3 / +1.6 % (d 0.36); luteal vs follicular → HR +1.6 % (d 1.41), rMSSD
  −3.2 % (d 0.80). Their conclusion: HRV is "a more sensitive marker of stress with respect to heart rate"
  but less specific. Note that for the two largest stressors the **HR effect size is roughly twice the
  HRV effect size**, which argues against a 0.55 : 0.20 HRV : RHR split for the illness/alcohol class of
  "not recovered" nights.
- Schmitt et al. 2013 (57 elite skiers, 1,063 trials): fatigue state → supine HR +6.27 ± 0.61 bpm, HF
  (log10) −0.46, and larger intra-individual variance of HRV (supine HF variance 0.32 vs 0.08). Fatigue
  both lowers and *scatters* HRV, so a single night's value is noisier precisely when it matters.

**Resting HR is the more specific companion, and the saturation discriminator.**

- Buchheit 2014: to separate a sympathetic drop in rMSSD from parasympathetic saturation "examine the
  changes in those indices (e.g., rMSSD) with regard to concomitant changes in resting HR"; saturation
  is associated with R-R intervals > 1000 ms (HR < 60); "we recommend computing the Ln rMSSD/R-R ratio" —
  a sympathetically driven drop keeps the ratio steady or raises it, saturation lowers it substantially.
- `docs/RR-OPTIMIZATION.md` finding 5 (NOOP's own, n = 8): the HRV/RHR ratio tracked WHOOP recovery
  (r 0.78) better than HRV alone (0.74). Same mechanism, different wearer, different reference. The two
  agree in direction; neither is validated at a usable n.

**Sleep.** Fullagar et al. 2015 (review): sleep loss impairs sport-specific performance in the few athlete
studies and reliably slows/degrades cognition, with mixed effects on maximal efforts; it "may disrupt
autonomic nervous system balance". No fetched paper quantifies a sleep-duration weight inside a
readiness composite. Vendor practice weights sleep heavily: Oura lists four of nine readiness contributors
as sleep-related (Sleep, Sleep Balance over two weeks, Sleep Regularity over two weeks, Recovery Index);
Garmin Training Readiness takes "last night's sleep score" plus "sleep history over the past three
nights" as two of six inputs (fetched manual page). The only quantitative handle in the tree is
RR-OPT's r 0.80 of sleep performance with WHOOP's recovery (a reference *estimate*, not truth).

**Prior-day load.** Stanley, Peake & Buchheit 2013 (review): cardiac parasympathetic reactivation takes
"up to 24 h following low-intensity exercise", 24–48 h after threshold intensity, and ≥ 48 h after
high-intensity. Buchheit 2014: "consideration of training load from the day preceding the measure is
crucial". So yesterday's Effort is an *interpretation* input (it explains a low HRV) as much as a driver.
Garmin uses "recovery time" + "acute load"; Oura uses "Previous Day Activity" + "Activity Balance". NOOP
has the term (`wActivityBalance`) but nothing feeds it.

**Subjective wellness.** Saw, Main & Gastin 2016 (systematic review, 56 studies): subjective measures
"reflected acute and chronic training loads with superior sensitivity and consistency" than objective
ones, and the two "generally did not correlate". Hooper et al. 1995 (14 elite swimmers, 6 months):
self-reported well-being ratings predicted staleness; "self-reported ratings of well-being may provide an
efficient means of monitoring both overtraining and recovery". A one-line daily rating is both the
cheapest proxy and the strongest-evidenced readiness input NOOP does not collect in the score path.

**Respiratory rate.** Miller et al. 2020 (WHOOP, 271 people, 2,672 sample-days): a nocturnal
respiratory-rate change model identified 20 % of positives two days before symptom onset and 80 % by day
three. This is an *illness* signal with a lag, not a day-to-day readiness driver; RR-OPT found r ≈ 0 with
WHOOP recovery. Keep it in `IllnessSignalEngine`, weight ≈ 0 in Charge.

**Temperature.** No fetched readiness paper uses it as a driver. Oura's "Body Temperature" contributor is
symmetric ("substantially higher or lower than usual"), matching NOOP's symmetric penalty. Topic 08 owns
the one-sided illness/cycle use.

### 2.2 Averaging window, SWC and day-to-day noise

- **Single nights are too noisy; 3–4 valid nights per week is the floor.** Plews et al. 2014 (IJSPP):
  standardised ln rMSSD change vs performance correlation across 1…7 averaged days was −0.02, −0.07,
  −0.17, −0.25, −0.26, −0.28, −0.25 — plateau at 3–4 days; recommendation "a minimum of 3 (randomly
  selected) valid data points per week". Buchheit 2014: correlations with running performance appeared
  only with "the average of at least 3–4 days of HR and HRV data, as opposed to isolated measures taken on
  single days". Le Meur 2013: single weekly recordings showed no clear effect; weekly averages did.
- **Day-to-day typical error.** Buchheit 2014: rMSSD TE ≈ 12 % CV; "CV = 10–20 % for Ln rMSSD" day to
  day. Altini & Plews 2021 cite TE 10 % (HR) / 12 % (rMSSD) and use SWC = 2 % (HR) / 3 % (HRV). Bellenger
  et al. 2022 (11 Olympic water-polo players, WHOOP 3.0, 16 weeks): mean 7-day CV 5.4 ± 0.7 % for ln RMSSD
  and 7.6 ± 1.3 % for HR, at or below the 3–13 % / 10–11 % of other protocols. Dial et al. 2025 (13 adults,
  536 nights, ECG reference): WHOOP 4.0 nocturnal HRV CCC 0.94, MAPE 8.17 ± 10.49 %; RHR CCC 0.91, MAPE
  3.00 ± 2.15 %. So even the vendor's full-pipeline HRV carries ~8 % error per night against ECG, before
  NOOP's sparse-R-R penalty.
- **Smallest worthwhile change.** Hopkins 2004: 0.2 × between-athlete SD for team sports, 0.3 × an
  athlete's own competition-to-competition CV for solo sports; "the noise in most performance tests is
  greater than the smallest worthwhile difference". Buchheit 2014: the individual CV "as the reference for
  the SWC is intuitively a better choice"; authors have used SWC = 0.5 or 1 × CV, others fractions of the
  between-athlete SD. The exact "±0.5 × SD of ln RMSSD over the long window" that `HRVReadiness` uses is a
  widely used convention consistent with these, but the specific 0.5 × SD figure was **not** found in any
  fetched text (see §8). Treat 0.5 as a pinned, auditable constant rather than a literature value.
- **CV of ln RMSSD as a marker — sign depends on the mean.** Plews 2012 (two triathletes, 77 days):
  in the non-functionally overreached athlete both the 7-day ln rMSSD (slope −0.17/week) and its CV
  (−0.65 %/week) fell; the control stayed flat. Flatt & Esco 2016 (12 female soccer players): a *decrease*
  in ln rMSSD CV over weeks 1–3 predicted Yo-Yo improvement (r −0.74) — "a favorable response, indicative
  of positive adaptation". Flatt et al. 2017 (JSMPF): higher day-to-day variability was associated with
  greater fatigue and lower fitness (r ≈ −0.55 / −0.65). A falling CV is therefore ambiguous on its own;
  paired with a falling mean it is the Plews 2012 signature, paired with a stable/rising mean it is
  adaptation. NOOP's `overreachingWatch` (falling CV **and** 7-night mean below long mean) encodes exactly
  that pairing — correct, keep it informational.
- **Ultra-short recordings are fine for the HRV number, irrelevant here.** Nakamura et al. 2015/2017 and
  Pereira et al. 2016: 60-s ln RMSSD vs 5-min criterion ICC 0.93–0.95, trivial effect sizes, training
  changes correlated r 0.82. NOOP's nightly windows are 5-min, so this only matters for the spot path.

### 2.3 Does a readiness read predict anything? (the honest ceiling)

The strongest causal evidence is the HRV-guided-training RCT family, where a daily readiness rule
(7-day ln RMSSD inside an individual SWC band → hard session, else easy) changed outcomes:

- Kiviniemi 2007 (26 men, 4 weeks): HRV-guided Load_max +0.9 vs +0.5 km/h (P = 0.048); VO₂peak 56 → 60.
- Vesterinen 2016 (40 runners, 8 weeks): 3000 m +2.1 ± 2.0 % (P = 0.004) vs +1.1 ± 2.7 % (ns), ES 0.42,
  with *fewer* hard sessions (13.2 vs 17.7).
- Javaloyes 2019 (17 cyclists, 8 weeks): PPO +5.1 %, 40-min TT +7.3 % in the HRV group; between-group ns.
- Düking et al. 2021 (meta-analysis, 8 studies, 198 participants): submaximal parameters g 0.296
  (95 % CI 0.031–0.562, p 0.028); performance g 0.079 (ns); VO₂peak 0.171 (ns); fewer non-responders.

So the aggregate effect of acting on an HRV-based readiness read is **small-to-medium on submaximal
physiology and small/non-significant on performance**. A 0–100 score should be presented with that
ceiling in mind: it is a trend read with a few-percent edge, not a prediction.

### 2.4 What the vendors do (documentation, not evidence)

| Vendor (fetched page) | Inputs | Baseline | Bands |
|---|---|---|---|
| Oura Readiness (ouraring.com/blog/readiness-score) | Sleep, Sleep Balance (2 wk), Sleep Regularity (2 wk), Previous Day Activity, Activity Balance (2 wk), RHR, HRV Balance ("long-term average"), Body Temperature (symmetric), Recovery Index | 2 weeks for the balance terms; long-term for HRV; no window stated for RHR/temp | ≥ 85 Optimal, 70–84 Good, < 70 Pay attention |
| Garmin Training Readiness (manual page) | last night's sleep score, recovery time, HRV status, acute load, sleep history (3 nights), stress history (3 days) | HRV Status = **7-day average vs personal baseline range**, needs **three weeks** of sleep data; "balanced / unbalanced / low / poor" | 95–100 Prime, 75–94 High, 50–74 Moderate, 25–49 Low, 1–24 Poor |
| WHOOP Recovery | official pages returned HTTP 403 this session (§8). A WHOOP community thread (non-official) lists HRV, RHR and sleep performance as inputs; the 58 % member-average and the 34/67 band cutoffs could **not** be fetched from whoop.com. | — | — |

Common ground across vendors and papers: a **7-day HRV average against a multi-week personal band**,
**sleep as a first-class input**, **prior-day load as an input**, and **≥ 2–3 weeks before a confident
read**. None publishes weights.

### 2.5 Recommended composite (synthesis)

1. **HRV driver = ln RMSSD, two-timescale.** Tonight's ln RMSSD z against the long personal band
   (illness/alcohol sensitivity) **and** the 7-night ln mean against the same band (the Plews/Garmin
   trend). Pinned blend; the trend half should dominate once ≥ 3 of the last 7 nights are valid
   (Plews 2014), tonight-only otherwise.
2. **RHR driver in bpm, weight raised relative to HRV** (Altini: d 0.97 vs 0.47 for the two biggest
   "not recovered" causes; Schmitt +6 bpm in fatigue; Le Meur: HR moves opposite to HRV in overreaching).
3. **Saturation handled by construction, not by a guard**: add the Buchheit ln RMSSD / R-R ratio as a
   driver (or replace the raw-HRV z with the ratio z when R-R > 1000 ms). This is what the shipped
   guard is trying to approximate with a sign test, and RR-OPT finding 5 independently found the ratio
   tracks better. It cannot be enabled on evidence NOOP has today (§5), so it is a flagged candidate.
4. **Sleep weight up** (vendor practice + RR-OPT r 0.80), **prior-day Effort wired in** (Stanley 2013
   recovery time course), **resp and temp out of the score** (kept in the illness heads-up).
5. **Subjective wellness as an optional driver**: a single 1–5 "how do you feel" captured in the journal,
   entered as a term only when logged (Saw 2016, Hooper 1995).
6. **One baseline machinery** (§3.2), **cold start ≥ 7 valid nights** for a provisional number and 14 for
   a trusted one, with the HRV driver dropping (not the whole score) when tonight's HRV is missing.
7. **Presentation**: a gentler logistic, the 7-night trend as the headline direction, drivers listed with
   their z, and the confidence tier shown beside the number.

---

## 3. Gap analysis

| # | Gap (NOOP today vs §2) | Impact | Why |
|---|---|---|---|
| G1 | HRV driver is a **single-night raw-ms z** at weight 0.55. | **High** | Plews 2014 / Buchheit 2014: single-day values do not correlate with performance; 3–4-day averages do. Day-to-day CV 10–20 % (Buchheit), WHOOP-pipeline MAPE ≈ 8 % vs ECG (Dial 2025), and NOOP's own R-R is sparse on 5.0. Raw-ms z over-weights the right tail; `ReadinessEngine` already corrected this (RD1) so the two screens can disagree on the same night. RR-OPT finding 3 (ln didn't help at n = 8, narrow range) is not evidence against ln — it is evidence the test could not resolve it. |
| G2 | **Three baseline machineries**, two domains, three windows, three cold-start counts (4 / 7 / 14). | **Medium** (consistency) / High (trust) | "Two readouts of one fact must not be able to disagree" (`AGENTS.md`). The Charge ring, the Readiness card and the Android Health hub can each call the same night different things. |
| G3 | `wSleep 0.15`, no prior-day-load input in the shipped path. | **Medium** | Only evidence is RR-OPT (n = 8, vs a vendor reference) plus vendor practice; the direction is consistent everywhere, the magnitude is unknown. Stanley 2013 makes prior-day load a required interpretation input. |
| G4 | HRV : RHR weight 0.55 : 0.20 and no HRV/R-R ratio. | **Medium** | Altini 2021: HR effect ≈ 2× HRV effect for sickness/alcohol; Buchheit 2014 ratio recommendation; RR-OPT ratio r 0.78 > HRV 0.74. The unapplied saturation guard is the symptom. |
| G5 | `logisticK 1.6` (z ± 2 → ≈ 5 / 97 %). | **Medium** (presentation) | RR-OPT: LOO MAE ≈ 20 → ≈ 9 with a gentler slope on one wearer. A steep squash turns ±1 personal SD (a normal night, Buchheit's CV band) into a 31-point swing (37 → 68 %), crossing two colour bands on noise. |
| G6 | Cold start at **4** valid nights for a number (EWMA spread pinned at floor). | **Medium–High** | Garmin requires three weeks; `HRVReadiness` 14; Plews 2013 calls for longitudinal monitoring to learn the individual pattern; Plews 2014 implies ≥ 3 valid nights/week × 2 weeks before a trend exists. At n = 4 the spread is the floor, so z is hypersensitive (the anti-anchoring comment in `Baselines.swift` describes exactly this failure). |
| G7 | 58 % population anchor (`logisticZ0 −0.20`). | **Low** | Could not be verified from whoop.com this session (403); it only shifts the offset, and a personal baseline has no business being anchored to another product's member mean. Replace with z = 0 → 50 % (or keep as a *labelled* vendor convention). |
| G8 | Symmetric skin-temp penalty, weight 0.05. | **Low** | Matches Oura's symmetric contributor; no readiness paper weights temperature. Harmless at 0.05; the one-sided illness use belongs to `IllnessSignalEngine` / topic 08. |
| G9 | Respiratory rate at 0.05 in the score. | **Low** | Miller 2020 shows it is an illness-lag signal; RR-OPT r ≈ 0 with recovery. Move to illness-only; on 5.0 it is RSA-from-sparse-R-R anyway. |
| G10 | No subjective input, no "why" beyond `ChargeDrivers`. | **Medium** | Saw 2016 / Hooper 1995: the best-evidenced input is the one not collected. Also the cheapest validation proxy (§5). |
| G11 | `recovery()` requires tonight's HRV (non-optional) so a sparse-R-R night yields no score at all. | **High on 5.0** | §4: the common 5.0 night is HR-dense / R-R-sparse. The composite should degrade to RHR + sleep + load with a visible confidence drop, not vanish. |
| G12 | Saturation guard: detected, never applied; premise comment conflates two signatures. | Low (correctly off) | Le Meur 2013's overreaching signature is HRV **up** + HR down, Buchheit's saturation is HRV **down** + HR down; the guard only sees the latter. The ratio driver (G4) is the literature's answer and would retire the guard. Keep it off until §5 produces real firings. |

### 3.2 One baseline machinery for the whole app (recommendation)

**Keep the Winsorized-EWMA `Baselines` spine as the single machinery, fold HRV in the ln domain
everywhere, and retire the other two paths.**

- *Which spine.* `Baselines.update/foldHistory` already exists on both platforms with oracle tests,
  skip-and-hold for missing nights, staleness, epoch recalibration, early-life anti-anchoring and the
  21-day `ChargeBaselines` window rule. The trailing-window mean/SD paths (`ReadinessEngine` re-fold,
  `V5HealthSignals.zAgainst`, `rollingMeanSD`) add nothing the literature asks for and each carries its
  own min-nights and domain. One spine, one `MetricCfg` per metric, every consumer calls it.
- *Which domain.* **ln ms for HRV** (`readinessHRVLnCfg`, bounds ln 8–ln 250, floor 0.08 ln ≈ 8 % — the
  same order as Buchheit's 10–20 % day-to-day CV, so the floor cannot saturate z on a stable wearer);
  **linear** for RHR (bpm), resp (bpm), temp (°C), Effort (0–100). Evidence: Buchheit 2014 and every
  Plews paper report Ln rMSSD; Altini & Plews express changes as % of the personal mean, which is the ln
  domain; `ReadinessEngine` RD1 already states the skew argument.
- *Which window.* Centre half-life 14 nights / spread 21 nights is kept (effective memory ≈ 20–30 nights,
  inside the 2-week (Oura balance) to 60-night (`HRVReadiness`) range the vendors and the opt-in engine
  use) **plus** a 7-night short mean computed from the same ln series for the trend driver. The 7-night
  mean needs ≥ 3 valid nights in the last 7 (Plews 2014) or it is absent. Window length is **not** a
  literature constant (nothing fetched pins 14 vs 30 vs 60); it is a pre-registered parameter to sweep on
  the temporal split in §5, reported per half (R5).
- *Cold start.* `minNightsSeed` 4 → **7** valid nights for a provisional number, `minNightsTrust` 14
  unchanged, and `ScoreConfidence.charge` reads `.building` until 14. "Calibrating — N of 7" replaces
  "N of 4".
- *Hard-outlier rejection.* Off for re-folded trailing windows (the validated `rejectHardOutliers: false`
  mode); on for the incremental Charge fold. That distinction is already documented in `Baselines.swift`
  and should be the only remaining mode difference.
- *Parity.* `V5HealthSignals.kt` becomes a thin adapter over `Baselines.kt` (same `MetricCfg`), and the
  readiness/illness engines on both platforms take `BaselineState`s, not raw windows. One oracle fixture
  (Swift stdout of `foldHistory` over a shared night series in both domains) pins all consumers at once.

---

## 4. WHOOP 5.0 input constraints

Per `docs/research/00-inventory.md` §1 and `README.md` limits, for a 5.0 bonded exclusively to NOOP:

| Driver | 5.0 status | Consequence for the composite |
|---|---|---|
| HRV (RMSSD from R-R) | ⚠️ sparse: ≤ 4 R-R words/s, 500 ms filler beats (`tsSuspect`), coverage gates (`classifyCoverage`, `beatAccurateFraction`); "incomplete unless sufficient R-R" | The dominant driver is the least reliable input. Many nights will have no usable `avgHrv`; those that do carry more artifact than WHOOP's own pipeline (Dial 2025: 8 % MAPE even there). |
| RHR | ✅ HR dense when offloaded; PPG filler for gaps | Survives every night. The most reliable 5.0 driver, and the more specific one for illness/alcohol (Altini 2021). |
| Sleep duration / efficiency / Rest | ⚠️ HR-only detection on sparse gravity; staging "approximate" | Duration and efficiency survive; stage-based restorative share is low-confidence (`ScoreConfidence.rest` already downgrades sparse-gravity nights). Weight the Rest composite, not the stage split. |
| Respiratory rate | ❌ no waveform; RSA from the same sparse R-R | Dies with HRV. Must not be a score driver on 5.0. |
| Skin temperature | ⚠️ present on supported layouts, not consistent across firmware | Optional term, already nil-dropped. |
| Prior-day Effort | ✅ from dense HR + step counter | Survives every night; currently unused. |
| Subjective rating | ✅ if the wearer logs it | Survives every night; currently uncollected in the score path. |

**How the composite should degrade (recommendation):**

1. **HR-only night (no usable HRV):** score from RHR + Rest + prior-day Effort (+ temp, + subjective if
   logged); HRV weight renormalises away; confidence `.building`; the driver list says "HRV: not enough
   beat data tonight". The 7-night HRV trend still contributes **if** ≥ 3 of the last 7 nights were valid
   (Plews 2014) — so one sparse night does not zero the HRV family.
2. **HRV present but coverage-gated low quality** (`beatAccurateFraction` below threshold or coverage
   outside [0.90, 1.10]): treat as missing for the tonight-z, keep it out of the 7-night mean too.
3. **Fewer than 3 valid HRV nights in the last 7:** no trend term; tonight-z only if present; confidence
   `.building`.
4. **No valid HRV in `staleDays`:** HRV family absent, score continues from RHR + Rest + load, label
   "RHR-led". Never nil the score for HRV absence alone once the RHR baseline is trusted.
5. **PPG-filler HR (`ppgHrSample`)** may feed RHR only; never HRV (already the rule).

This inverts today's gate (HRV baseline required, everything else optional) into "RHR baseline required,
HRV preferred", which matches what the 5.0 actually delivers.

---

## 5. Validation plan

There is **no public readiness ground truth** (R8 applies: say so). What exists are proxies, each a
different question, each to be pre-registered separately (R1).

### 5.1 Reference proxies (ranked by availability to the owner)

| Proxy | What it answers | Source | Caveat |
|---|---|---|---|
| **WHOOP's own Recovery % in the owner's CSV export** (full account history) | "Does NOOP's composite, fed WHOOP's *own* HRV/RHR/sleep columns, reproduce WHOOP's ranking of days?" | WHOOP data export (the RR-OPT finding-5 method) | A reference **estimate**, not truth (two estimates agreeing are not a measurement, R8). Tests the *formula/weights*, not NOOP's decoding. Only overlapping nights test the decode path; the owner stopped using the app, so overlap may be zero. |
| **Daily subjective wellness** (Hooper-style 1–5: fatigue, sleep quality, muscle soreness, stress, mood, or a single "ready?" item) logged in the NOOP journal each morning *before* looking at the score | "Does the score track how the wearer feels?" | Saw 2016, Hooper 1995 | Must be logged blind to the score (R1), else circular. Needs ≥ 30 days for r ≈ 0.5, ≈ 85 days for r ≈ 0.3 at α 0.05 / power 0.8 (two-sided Pearson). |
| **Tagged known-bad days** (alcohol, illness, travel from the journal) | "Does the score fall on days with a known cause?" (Altini 2021 directions) | journal tags | Base rate first (R6): count tag days over the whole era. Report AUC with n per class; < 10 tagged days = "cannot be measured". |
| **Submaximal HR at a fixed easy pace / power** (Buchheit 2014's recommended field marker) or a weekly fixed test | "Does a low score precede worse next-day performance?" | wearer's training | Needs a repeatable session and ≥ 8–12 weeks; confounded by weather/terrain. |
| **Prior-day load** (Effort) | sanity: score should fall after high-intensity days and recover in 24–48 h (Stanley 2013) | NOOP | Direction-only check, not a calibration target. |

### 5.2 Public datasets

None fetched this session provides wrist HR/HRV + readiness truth. Candidates to verify in Phase 3 are
listed in §8 (PMData; HRV4Training data is not public). The sleep datasets in topic 03 carry no
next-day outcome. State plainly in `ROADMAP.md`: **readiness cannot be validated against a public gold
standard; it can be validated against the owner's proxies on a temporal split.**

### 5.3 Metrics and protocol (per `docs/VALIDATION_PROTOCOL.md`)

- **R1** pre-register: proxy, direction, threshold (e.g. "Spearman ρ with blind wellness ≥ 0.35 on the
  held-out half, and ≥ the current `RecoveryScorer` on the same nights"), exclusion list (nights with
  `hrOnly` flagged separately as a stratum, not excluded), expected n.
- **R5 temporal split**: weights, `logisticK`, window length and cold-start fitted on the **early** half,
  headline on the **late** half; report both and the gap; report each fitted constant per half (a weight
  that moves a lot between halves "is not a constant of physiology").
- **Metrics**: Spearman ρ and Pearson r (score vs proxy); LOO-CV MAE against WHOOP-CSV recovery (the
  RR-OPT instrument, so the numbers compare); AUC for tagged days with the class marginals printed;
  calibration table (score decile → mean proxy) because a 0–100 number is a *claim about magnitude*;
  day-to-day score SD on untagged nights (noise floor) next to the score's band width.
- **R3**: every number ships with its regenerating command (a `Tools/ReadinessBench` analogous to
  `SleepBench`, replaying candidate composites over a DB copy + CSV + journal export).
- **R4**: do not report "better on k of n nights"; report the paired difference and its CI.
- **n needed**: for the WHOOP-CSV formula test, RR-OPT showed n = 8 overfits a 3-parameter fit
  (0.849 in-sample vs 0.575 LOO); a full export of several hundred days is the unlock, and a 5-parameter
  weight fit should have ≥ 100 days per half. For the subjective proxy, ≥ 60 blind mornings before any
  weight is touched.
- Parasympathetic saturation / ratio term: count real firings of the existing guard over the full era
  (R6 base rate) before enabling anything.

---

## 6. Implementation sketch

Each step is pure, DB-free, lands in `Packages/StrandAnalytics` + `android/.../analytics`, with a Swift
stdout → Kotlin literal oracle (`AGENTS.md`). Nothing below touches BLE or protocol code. Steps A–C are
behaviour-preserving refactors or flagged candidates and can ship; D–E change the headline and may ship
only behind `PuffinExperiment` until §5 produces a held-out number.

### A. One baseline spine (effort M, risk low–medium)

```
// Shared, both platforms. All consumers take BaselineState; none compute mean/SD themselves.
struct PersonalBaselines { hrvLn, rhr, resp, skinTemp, effort : BaselineState? }

func foldPersonalBaselines(nights: [NightRow] /* oldest→newest, ≤ ChargeBaselines.windowDays+long */,
                           epoch: Double) -> PersonalBaselines {
    hrvLn   = Baselines.foldHistory(nights.map { $0.avgHrv.map { log(max($0, 1)) } },
                                    dayKeys, cfg: readinessHRVLnCfg, baselineEpoch: epoch)   // ln domain
    rhr     = Baselines.foldHistory(nights.map { $0.restingHr }, …, cfg: restingHRCfg, …)
    resp    = … respCfg;  skinTemp = … skinTempCfg;  effort = … strainCfg
}
// Delete: ReadinessEngine.zSignal's private re-fold; V5HealthSignals.zAgainst; rollingMeanSD callers.
// Constants: minNightsSeed 4 → 7 (one constant, both platforms, test pins it).
```

Parity oracle: a fixed 90-night synthetic series with gaps and one outlier run through Swift
`foldPersonalBaselines`, printed to 1e-9, pasted into `BaselinesParityOracleTest.kt`.

### B. HRV family: tonight-z + 7-night trend-z (effort S, risk low)

```
func hrvFamily(lnTonight: Double?, lnLast7: [Double?], b: BaselineState) -> (z: Double, w: Double)? {
    sigma = max(1.253 * b.spread, 1e-9)
    zTonight = lnTonight.map { ($0 - b.baseline) / sigma }
    valid7 = lnLast7.compactMap { $0 }
    zTrend = valid7.count >= 3 ? (mean(valid7) - b.baseline) / sigma : nil   // Plews 2014 floor
    switch (zTonight, zTrend) {
      case (t?, r?): return (wTonight * t + wTrend * r, wHRV)        // wTonight 0.4, wTrend 0.6 (pinned)
      case (t?, nil): return (t, wHRV * 0.6)                          // thin: reduced weight
      case (nil, r?): return (r, wHRV * 0.6)
      default:        return nil                                       // HRV family absent
    }
}
```

### C. Ratio driver, flagged (effort S, risk medium)

```
// Buchheit 2014 Ln rMSSD / R-R ratio, baselined like any metric (linear cfg, bounds to pin).
ratio = ln(rmssd_ms) / (60000 / rhr_bpm)          // ln ms per ms of mean R-R
zRatio = (ratio - bRatio.mean) / sigma(bRatio)
// Experimental flag `noopChargeRatioDriver`: replaces the saturation guard's counterfactual; logged in
// the Charge trace beside the guard's wouldRaiseCharge line so firings can be compared on real nights.
```

### D. Composite with degradation (effort M, risk medium; flagged until validated)

```
func charge(inputs, b: PersonalBaselines, flags) -> (score: Double, confidence: ScoreConfidence)? {
    guard let rhrB = b.rhr, rhrB.usable else { return nil }           // RHR is the required driver on 5.0
    terms = []
    if let h = hrvFamily(...)              { terms += (h.z, h.w) }                 // wHRV  0.40 (candidate)
    terms += (zLowerBetter(rhr, rhrB), wRHR)                                         // wRHR  0.25 (candidate)
    if let s = restScore                   { terms += ((s/100 - 0.85)/0.12, wSleep) } // wSleep 0.25 (candidate)
    if let e = priorDayEffort, let eB = b.effort, eB.usable
                                           { terms += (zLowerBetter(e, eB), wLoad) }  // wLoad 0.05
    if let t = skinTempDev                 { terms += (-abs(t)/1.0, wTemp) }          // wTemp 0.05
    if let f = subjectiveRating            { terms += ((f - 3)/1.0, wFeel) }           // wFeel 0.10, only if logged
    // resp: removed from Charge; stays in IllnessSignalEngine.
    z = Σ z·w / Σ w
    score = 100 / (1 + exp(-k * z))                                                  // k candidate 1.0, z0 = 0
    confidence = (hrv present && rhrB.trusted) ? .solid : .building
    return (clamp(score), confidence)
}
```

All weights, `k` and `z0` are pinned constants named in one place; the candidate values above are the
§2 synthesis, **not** fitted, and are the pre-registered starting point for §5. The oracle test pins
whatever ships.

### E. Presentation (effort S, risk low)

- Headline number + arrow from the 7-night trend sign; drivers listed as "HRV trend −0.8 σ, RHR +0.3 σ,
  Rest 71 %"; confidence tier next to the number; bands recomputed from the new `k` so ±1 σ stays inside
  one band (with k = 1.0, z = ±1 → 27 / 73 %, so red < 27, green ≥ 73 keeps a normal night in yellow).
- Copy stays "approximate", "your own baseline", never "fatigue", "overtraining" or any condition.

### Effort / risk summary

| Step | Effort | Risk | Ships |
|---|---|---|---|
| A one spine | M | low–medium (touches three consumers, two platforms; behaviour-preserving if Charge stays raw-ms until D) | yes, with oracle |
| B HRV family | S | low (pure function, nil-safe) | behind flag or with D |
| C ratio driver | S | medium (unvalidated premise) | flag only |
| D composite + degradation | M | medium (headline change) | flag until §5 held-out number |
| E presentation | S | low | with D |
| `Tools/ReadinessBench` harness | M | — | first (Phase 3 step 1) |

---

## 7. Sources (verified)

Each entry: citation, identifier, what was verified from the fetched text.

1. Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. *Training adaptation and heart rate variability
   in elite endurance athletes: opening the door to effective monitoring.* Sports Med 2013;43(9):773-781.
   DOI 10.1007/s40279-013-0071-8, PMID 23852425. Abstract (Europe PMC): HRV both rises and falls with
   negative adaptation; recommends averaging techniques and indices that handle "HRV saturation";
   longitudinal monitoring to learn the individual pattern. No numbers in the abstract.
2. Plews DJ, Laursen PB, Kilding AE, Buchheit M. *Heart rate variability in elite triathletes, is variation
   in variability the key to effective training? A case comparison.* Eur J Appl Physiol 2012;112(11):3729-41.
   DOI 10.1007/s00421-012-2354-4, PMID 22367011. n = 2, 77 days; NFOR athlete: 7-day ln rMSSD slope
   −0.17/week, CV slope −0.65 %/week; control flat.
3. Plews DJ, Laursen PB, Le Meur Y, Hausswirth C, Kilding AE, Buchheit M. *Monitoring training with heart
   rate-variability: how much compliance is needed for valid assessment?* Int J Sports Physiol Perform
   2014;9(5):783-790. DOI 10.1123/ijspp.2013-0455, PMID 24334285. Correlation with performance across 1–7
   averaged days −0.02 … −0.28, plateau at 3–4; "minimum of 3 (randomly selected) valid data points per week".
4. Plews DJ, Laursen PB, Kilding AE, Buchheit M. *Heart-rate variability and training-intensity distribution
   in elite rowers.* Int J Sports Physiol Perform 2014;9(6):1026-1032. DOI 10.1123/ijspp.2013-0497,
   PMID 24700160. 9 rowers, 26 weeks, weekly-averaged ln rMSSD; time > LT2 vs ln rMSSD r −0.22, < LT1 r 0.43.
5. Buchheit M. *Monitoring training status with HR measures: do all roads lead to Rome?* Front Physiol
   2014;5:73. DOI 10.3389/fphys.2014.00073, PMID 24578692. Full text (frontiersin.org): 3–4-day averages
   needed; rMSSD TE ≈ 12 %, ln rMSSD day-to-day CV 10–20 %; SWC as 0.5 or 1 × individual CV; saturation at
   R-R > 1000 ms, judge rMSSD against concomitant HR, "we recommend computing the Ln rMSSD/R-R ratio";
   prior-day load "crucial"; combine with wellness questionnaires.
6. Bellenger CR, Fuller JT, Thomson RL, Davison K, Robertson EY, Buckley JD. *Monitoring athletic training
   status through autonomic heart rate regulation: a systematic review and meta-analysis.* Sports Med
   2016;46(10):1461-1486. DOI 10.1007/s40279-016-0484-2, PMID 26888648. Resting RMSSD SMD 0.58 with improved
   performance, 0.26 with overreaching; HFP 0.55 vs 0.04.
7. Le Meur Y, Pichon A, Schaal K, et al. *Evidence of parasympathetic hyperactivity in functionally
   overreached athletes.* Med Sci Sports Exerc 2013;45(11):2061-2071. DOI 10.1249/MSS.0b013e3182980125,
   PMID 24136138. 21 triathletes; overreached −9.0 ± 2.1 % performance with higher weekly ln RMSSD and
   lower resting HR; single weekly recordings uninformative.
8. Stanley J, Peake JM, Buchheit M. *Cardiac parasympathetic reactivation following exercise: implications
   for training prescription.* Sports Med 2013;43(12):1259-1277. DOI 10.1007/s40279-013-0083-4,
   PMID 23912805. Reactivation ≤ 24 h (low intensity), 24–48 h (threshold), ≥ 48 h (high intensity).
9. Schmitt L, Regnard J, Desmarets M, et al. *Fatigue shifts and scatters heart rate variability in elite
   endurance athletes.* PLoS One 2013;8(8):e71588. DOI 10.1371/journal.pone.0071588, PMID 23951198.
   57 skiers, 1,063 trials; fatigue: supine HR +6.27 ± 0.61 bpm, HF log10 −0.46, intra-individual HF
   variance 0.32 vs 0.08.
10. Altini M, Plews D. *What is behind changes in resting heart rate and heart rate variability? A large-scale
    analysis of longitudinal measurements acquired in free-living.* Sensors 2021;21(23):7932.
    DOI 10.3390/s21237932, PMID 34883936. Full text (Europe PMC XML): 28,175 users; sickness HR +6 %
    (d 0.97) / rMSSD −10 % (d 0.47); alcohol +6 % / −12 %; training d 0.38 / 0.36; luteal +1.6 % / −3.2 %;
    cited TE 10 % HR / 12 % rMSSD, SWC 2 % / 3 %; morning 1–5 min measurement; HRV "more sensitive … less
    specific".
11. Vesterinen V, Nummela A, Heikura I, et al. *Individual endurance training prescription with heart rate
    variability.* Med Sci Sports Exerc 2016;48(7):1347-1354. DOI 10.1249/MSS.0000000000000910,
    PMID 26909534. RCT n = 40; hard session only if HRV within individual SWC; 3000 m +2.1 % vs +1.1 %,
    ES 0.42; fewer hard sessions 13.2 vs 17.7.
12. Kiviniemi AM, Hautala AJ, Kinnunen H, Tulppo MP. *Endurance training guided individually by daily heart
    rate variability measurements.* Eur J Appl Physiol 2007;101(6):743-751. DOI 10.1007/s00421-007-0552-2,
    PMID 17849143. n = 26; Load_max +0.9 vs +0.5 km/h (P 0.048); VO₂peak 56 → 60.
13. Javaloyes A, Sarabia JM, Lamberts RP, Moya-Ramon M. *Training prescription guided by heart-rate
    variability in cycling.* Int J Sports Physiol Perform 2019;14(1):23-32. DOI 10.1123/ijspp.2018-0122,
    PMID 29809080. 17 cyclists; HRV group PPO +5.1 %, 40-min TT +7.3 %; between-group ns.
14. Düking P, Zinner C, Trabelsi K, et al. *Monitoring and adapting endurance training on the basis of heart
    rate variability monitored by wearable technologies: a systematic review with meta-analysis.* J Sci Med
    Sport 2021;24(11):1180-1192. DOI 10.1016/j.jsams.2021.04.012, PMID 34489178. 8 studies, 198
    participants; submaximal g 0.296 (p 0.028), performance g 0.079 (ns), VO₂peak 0.171 (ns).
15. Saw AE, Main LC, Gastin PB. *Monitoring the athlete training response: subjective self-reported measures
    trump commonly used objective measures: a systematic review.* Br J Sports Med 2016;50(5):281-291.
    DOI 10.1136/bjsports-2015-094758, PMID 26423706. 56 studies; subjective measures superior in sensitivity
    and consistency; subjective and objective generally uncorrelated.
16. Hooper SL, Mackinnon LT, Howard A, Gordon RD, Bachmann AW. *Markers for monitoring overtraining and
    recovery.* Med Sci Sports Exerc 1995;27(1):106-112. DOI 10.1249/00005768-199501000-00019, PMID 7898325.
    14 elite swimmers, 6 months; well-being ratings predicted staleness. (Hooper & Mackinnon 1995 Sports Med
    20(5):321-327, DOI 10.2165/00007256-199520050-00003, PMID 8571005 was located but its abstract was not
    in the record — listed in §8.)
17. Hopkins WG. *How to interpret changes in an athletic performance test.* Sportscience 2004;8:1-7.
    https://www.sportsci.org/jour/04/wghtests.htm. SWC = 0.2 × between-athlete SD (team) or 0.3 × within-
    athlete competition CV (solo); noise usually exceeds SWC.
18. Hopkins WG, Marshall SW, Batterham AM, Hanin J. *Progressive statistics for studies in sports medicine
    and exercise science.* Med Sci Sports Exerc 2009;41(1):3-13. DOI 10.1249/MSS.0b013e31818cb278,
    PMID 19092709. Abstract only: log transformation, precision over NHST; SWC not in the abstract.
19. Flatt AA, Esco MR. *Evaluating individual training adaptation with smartphone-derived heart rate
    variability in a collegiate female soccer team.* J Strength Cond Res 2016;30(2):378-385.
    DOI 10.1519/JSC.0000000000001095, PMID 26200192. Δ ln rMSSD CV (wk 1–3) vs Δ Yo-Yo r −0.74; Δ mean r 0.50.
20. Flatt AA, Esco MR, Nakamura FY. *Interpreting daily heart rate variability changes in collegiate female
    soccer players.* J Sports Med Phys Fitness 2017;57(6):907-915. DOI 10.23736/S0022-4707.16.06322-2,
    PMID 26997322. Higher day-to-day variability associated with greater fatigue / lower fitness (r ≈ −0.55,
    −0.65); ln rMSSD fell in the high-load week.
21. Nakamura FY, Flatt AA, Pereira LA, et al. *Ultra-short-term heart rate variability is sensitive to training
    effects in team sports players.* J Sports Sci Med 2015;14(3):602-605. PMID 26336347. 1-min vs criterion
    r 0.45–0.75. Nakamura FY et al. *Adequacy of the ultra-short-term HRV to assess adaptive processes in
    youth female basketball players.* J Hum Kinet 2017;56:73-80. DOI 10.1515/hukin-2017-0024,
    PMID 28469745. ICC 0.93–0.95, Δ r 0.82. Pereira LA et al. *Assessing shortened field-based HRV data
    acquisition in team-sport athletes.* Int J Sports Physiol Perform 2016;11(2):154-158.
    DOI 10.1123/ijspp.2015-0038, PMID 26115088.
22. Bellenger CR, Miller D, Halson SL, Roach GD, Maclennan M, Sargent C. *Evaluating the typical day-to-day
    variability of WHOOP-derived heart rate variability in Olympic water polo athletes.* Sensors
    2022;22(18):6723. DOI 10.3390/s22186723, PMID 36146073. 11 athletes, WHOOP 3.0, 16 weeks; 7-day CV
    5.4 ± 0.7 % ln RMSSD, 7.6 ± 1.3 % HR.
23. Dial MB, Hollander ME, Vatne EA, Emerson AM, Edwards NA, Hagen JA. *Validation of nocturnal resting heart
    rate and heart rate variability in consumer wearables.* Physiol Rep 2025;13(16):e70527.
    DOI 10.14814/phy2.70527, PMID 40834291. 13 adults, 536 nights vs ECG; WHOOP 4.0 HRV CCC 0.94 MAPE
    8.17 ± 10.49 %, RHR CCC 0.91 MAPE 3.00 ± 2.15 %; Oura Gen 4 HRV CCC 0.99 MAPE 5.96 %.
24. Miller DJ, Capodilupo JV, Lastella M, et al. *Analyzing changes in respiratory rate to predict the risk of
    COVID-19 infection.* PLoS One 2020;15(12):e0243693. DOI 10.1371/journal.pone.0243693, PMID 33301493.
    271 people, 2,672 sample-days, WHOOP; 20 % identified 2 days pre-symptom, 80 % by day 3.
25. Fullagar HH, Skorski S, Duffield R, Hammes D, Coutts AJ, Meyer T. *Sleep and athletic performance: the
    effects of sleep loss on exercise performance, and physiological and cognitive responses to exercise.*
    Sports Med 2015;45(2):161-186. DOI 10.1007/s40279-014-0260-0, PMID 25315456. Sport-specific performance
    reduced in athlete studies; cognition slower/less accurate; autonomic disruption possible.
26. Oura. *Readiness Score* (blog), https://ouraring.com/blog/readiness-score/. Nine contributors, two-week
    windows for the balance terms, bands ≥ 85 / 70–84 / < 70; body temperature symmetric.
27. Garmin. *Training Readiness* (device manual),
    https://www8.garmin.com/manuals/webhelp/GUID-31D23DBB-57C2-4DF7-A0C9-8D1A00AB4BE7/EN-US/GUID-C21BE0C8-A08E-4DA1-B6C6-2E0E2DDDB372.html.
    Six inputs; bands 95–100 / 75–94 / 50–74 / 25–49 / 1–24.
28. Garmin. *Heart Rate Variability Status* (Index Sleep Monitor manual),
    https://www8.garmin.com/manuals/webhelp/GUID-4462687B-8DF5-4719-872E-E16754F9D4B0/EN-US/GUID-5247CEC7-AF06-44FB-B6AD-87C53D4F7941.html.
    "Your seven-day average HRV is within your baseline range" = balanced; three weeks of sleep data required.
29. WHOOP Community (non-official). *What is the Recovery score, and how is it calculated?*
    https://www.community.whoop.com/t/what-is-the-recovery-score-and-how-is-it-calculated/107 (2025).
    Lists HRV, RHR and sleep performance as inputs; no weights, bands or windows.

## 8. Unverified leads

- **WHOOP official method pages** (`whoop.com/thelocker/how-does-whoop-recovery-work-101`,
  `…/member-averages-recovery-strain-sleep-hrv`, `whoop.in/pages/how-it-works`, `support.whoop.com`): all
  returned HTTP 403/404 this session. The "58 % member-average recovery", the 34/67 band cutoffs and the
  "HRV during the last slow-wave sleep period" statement therefore remain **unverified here**; search-result
  snippets attribute them to WHOOP's own blog, which is marketing, not a validation source. `populationMean`
  should carry that caveat in its comment until someone fetches the page.
- **"SWC = ±0.5 × SD of ln RMSSD over the long window"** as a specific constant: not found verbatim in any
  fetched text (Buchheit 2014 gives 0.5–1 × CV; Hopkins gives 0.2 × between-athlete SD). Candidate origin:
  Plews DJ et al. *Evaluating training adaptation with heart-rate measures: a methodological comparison.*
  Int J Sports Physiol Perform 2013;8(6):688-691 (not fetched), and Altini's HRV4Training documentation
  (not fetched). Keep 0.5 as a pinned constant, cite it as a convention.
- **Hooper SL, Mackinnon LT. Monitoring overtraining in athletes: recommendations.** Sports Med
  1995;20(5):321-327, PMID 8571005: record located, abstract not returned; the questionnaire items
  (fatigue, stress, sleep, muscle soreness, 1–7) are from memory and should be checked before copying them
  into a journal UI.
- **Flatt AA, Esco MR. Heart rate variability stabilization in athletes: towards more convenient data
  acquisition.** Clin Physiol Funct Imaging 2016;36(5):331-336 — ultra-short stabilisation; not fetched.
- **Oura's 3-month HRV-balance window** (often quoted): the fetched blog page says "long-term average" /
  "past few weeks" without a number.
- **PMData** (Thambawita et al. 2020, Fitbit + PMSys wellness + training logs, 16 people × 5 months) as a
  public proxy dataset for readiness-vs-wellness: not fetched; licence/access unknown.
- **Firstbeat Training Readiness** documentation: 404 at the tried URL; Garmin manual pages used instead.
- **Plews 2013 IJSPP "comparison of methods" (7-day rolling vs weekly vs single-day)** — the paper NOOP's
  `HRVReadiness` header effectively leans on for "7-day rolling"; not fetched (Plews 2014 compliance and
  Buchheit 2014 cover the same conclusion).

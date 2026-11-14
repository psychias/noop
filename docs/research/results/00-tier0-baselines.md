# Tier 0 — validation infrastructure and the shipped baselines

Status: **done** (2026-11-12). Roadmap items 0.2 and 0.3; 0.1 (Xcode) and 0.4 (data-use agreements) are
the owner's. This file records what was built and what the shipped estimators measure **before** any
item above Tier 0 changes them. Every number below is reproduced by the command beside it; the full
reports are in `raw/`.

## What was built

- `Tools/research-data/fetch.sh` + `datasets.tsv`: twelve datasets, verified downloads into the
  git-ignored `research-data/`. Fetched for this baseline: PhysioNet **Fantasia** 1.0.0 (40 records)
  and **MIT-BIH Polysomnographic** 1.0.0 (18 records), both checked file by file against PhysioNet's
  `SHA256SUMS.txt`.
- `Tools/MetricsBench`: WFDB reader, WHOOP-5.0 R-R sparsity simulator, agreement statistics, `hrv`
  and `resp` benches over the **shipped** `StrandAnalytics` functions, `selfcheck` (41 checks, also the
  XCTest body). Five `SleepStager` functions were made `public` for it; no behaviour change.
- CI: `swift-packages.yml` tools job builds and tests the new package.

Local caveat: this Mac has no Xcode, so `swift test` cannot run here; `metricsbench selfcheck` runs the
same assertions and passes 41/41. CI runs the XCTest form.

## Inputs and instrument (R4, R7)

| | Fantasia | slpdb |
|---|---|---|
| Subjects | 40 (20 young 21–34 y, 20 elderly 68–85 y), supine, awake, 120 min | 16 men 32–56 y referred for sleep apnoea, 18 records, 2–7 h, R&K stages |
| Beats | human-reviewed ECG annotations, NN intervals only (both beats NORMAL) | same |
| Respiration | belt waveform at 250 Hz | summed / nasal channel at 250 Hz |
| Beats in total | 652,723 (both sets) | |

Reference R-R stream: NN intervals, `rrMs` rounded, `ts` = whole second of the closing beat (the R18
stamp). Sparsity regimes: `cap4` (≤ 4 words/s), then holes covering 10 / 30 / 50 % of seconds with two
500 ms filler words at each hole's first two seconds, flagged suspect and **removed before analytics**
as the v47 read policy does. Seed 1.

Respiration reference: per 5-min window, breath count by hysteresis crossings and the dominant
spectral frequency of the waveform; scored only when both agree within 2 breaths/min. **729 of 1,963
windows were excluded on that rule** (the belt signal is often irregular); 1,234 scored. This is a
waveform-derived reference, not an expert annotation.

## HRV baseline (`metricsbench hrv --data research-data --seed 1`)

**Night mean RMSSD, sparse vs dense, 58 records (ms):**

| regime | bias | 95 % LoA | MAE | MAPE | CCC |
|---|---|---|---|---|---|
| cap4 | 0.00 | 0.00 … 0.00 | 0.00 | 0.0 % | 1.000 |
| cap4 + holes 10 % + fillers | +0.12 | −0.37 … +0.61 | 0.21 | 0.6 % | 1.000 |
| cap4 + holes 30 % + fillers | +0.55 | −0.65 … +1.76 | 0.66 | 2.1 % | 0.999 |
| cap4 + holes 50 % + fillers | +0.94 | −0.52 … +2.39 | 1.01 | 3.2 % | 0.998 |

**5-min windows by window coverage (Σ RR / wall span), holes 30 %:**

| coverage | windows | bias | 95 % LoA | MAE | within ±5 ms |
|---|---|---|---|---|---|
| < 0.70 | 579 | +1.10 | −5.1 … +7.3 | 2.46 | 87 % |
| 0.70–0.85 | 846 | +0.54 | −3.6 … +4.7 | 1.60 | 96 % |
| 0.85–0.95 | 360 | +0.48 | −1.9 … +2.9 | 0.96 | 100 % |
| ≥ 0.95 | 214 | +0.10 | −1.3 … +1.5 | 0.32 | 100 % |

**Valid-pair floors (20 / 30 / 50) keep 98.8–99.9 % of windows in every regime** and move the night
error by at most 0.1 ms. On this data the floor proposed in docs/research/01 §6.2 discriminates
nothing: contiguous holes leave the surviving pairs valid.

**Random single-beat deletion (Kim 2007), relative night-mean RMSSD error, n = 58:**

| beats deleted | mean | sd | p10 … p90 |
|---|---|---|---|
| 5 % | +2.1 % | 1.2 | +0.7 … +3.5 % |
| 10 % | +4.3 % | 2.3 | +0.9 … +7.4 % |
| 20 % | +8.6 % | 4.4 | +1.6 … +13.0 % |
| 30 % | +13.2 % | 6.8 | +3.0 … +20.0 % |

### Reading

1. The shipped gap-aware RMSSD is robust to **contiguous** loss (holes): even half the night missing
   moves the mean by ~1 ms. The four-word cap costs nothing below 240 bpm.
2. It is **not** robust to **scattered** loss: a lost beat whose neighbours survive turns a one-beat
   difference into a two-beat difference, and RMSSD inflates by roughly 2 % per 5 % of beats lost. The
   shipped contiguity flag comes only from range/ectopic rejection, so a beat the strap never reported
   is invisible to it. The wall clock sees it: with whole-second stamps a pair whose gap exceeds its
   R-R by more than one second is a lost beat, not rounding.
3. Window error tracks **coverage**, not pair count. A window gate for item 1.1 should be on
   coverage (Σ RR vs span, the `HRVAnalyzer.rrCoverage` quantity, per window) and the successive
   difference should skip a pair whose wall-clock gap says a beat is missing; a pair floor alone will
   pass everything this simulation produces. The self-check records that per-pair beat accuracy with a
   0.5 s tolerance fails ≈ |1 − RR| of pairs on a perfect stream, so it must not be the gate either.
4. Not measured here: the real strap's loss pattern (holes vs scattered). Phase 4's Polar H10 co-wear
   is the only source of that; the Kim table bounds the damage per scattered fraction.

Pre-registration for 1.1 (R1): with a ts-aware skip, the 30 % deletion row is expected to fall from
+13 % to within ±3 %, with no change on the `cap4` row; the coverage < 0.70 bucket's LoA is expected to
narrow, and windows below a coverage floor of 0.70 are expected to be the ones carrying most of the
> 5 ms errors. These are predictions, written before the change.

## Respiration baseline (`metricsbench resp --data research-data --seed 1`)

**Per-window, estimate − reference (breaths/min):**

| regime | retained | bias | 95 % LoA | MAE | CP2 |
|---|---|---|---|---|---|
| dense / cap4 | 1,196 / 1,234 (97 %) | −1.21 | −6.6 … +4.2 | 1.91 | 71 % |
| holes 10 % + fillers | 534 / 1,234 (43 %) | −1.06 | −6.1 … +4.0 | 1.83 | 70 % |
| holes 30 % + fillers | 65 / 1,234 (5 %) | −1.37 | −6.9 … +4.2 | 1.97 | 68 % |

| stratum (dense) | n | bias | MAE | CP2 |
|---|---|---|---|---|
| Fantasia young | 248 | −2.14 | 2.57 | 59 % |
| Fantasia elderly | 240 | −2.22 | 2.65 | 57 % |
| slpdb (sleep) | 708 | −0.55 | 1.43 | 79 % |
| slpdb NREM 3–4 | 49 | −0.45 | 0.62 | 98 % |
| slpdb REM | 33 | −1.54 | 1.62 | 76 % |
| reference tercile slow | 403 | +0.67 | 1.04 | 86 % |
| reference tercile mid | 389 | −0.82 | 1.06 | 87 % |
| reference tercile fast | 404 | −3.47 | 3.60 | 40 % |

**Per-record night value** (shipped median over the record vs reference median, n = 58): bias −1.95,
LoA −7.7 … +3.8, MAE 2.54, within ±1: 36 %. Unchanged under 10 % holes; 54/58 retained under 30 %.

**False-emit on shuffled R-R** (timestamps kept, no breathing in the input): **58 of 58 records emit a
number**, median 14.33, range 12.0–16.6.

**Direction tracking (synthetic RSA, whole-second ts):**

| amplitude \ rate | 8 | 11 | 15 | 20 | 24 |
|---|---|---|---|---|---|
| 60 ms | refuse | 11.43 | 15.00 | 20.00 | 12.00 |
| 30 ms | 8.14 | 11.04 | 15.00 | 20.00 | 12.00 |
| 15 ms | 8.08 | 11.17 | 15.00 | 20.00 | 12.00 |
| 5 ms | 12.00 | 12.00 | 15.00 | 18.46 | 12.00 |
| 0 ms | 12.32 | 12.32 | 12.32 | 12.32 | 12.32 |

### Reading

1. The estimator is unbiased to within ~1 breath/min in slow sleep (NREM 3–4: MAE 0.6, CP2 98 %) and
   degrades everywhere breathing is fast or irregular: the fast tercile has r ≈ 0 and a −3.5 bias. The
   cause is structural, not noise: `rsaMinPeakDistanceS` = 2.5 s on a 4 Hz grid caps the method at 24
   breaths/min and snaps rates above ~20 (22 reads 20.0; 24 halves to 12.0).
2. **The 13.33 floor is confirmed as a false emit on every record**: with physiology removed the
   estimator still returns 12–16.6 breaths/min. The 0 ms and 5 ms rows show the same floor on synthetic
   input. Any night whose true RSA is weak gets a plausible number that means nothing.
3. Sparsity does not change the error of the windows that survive, but the splice skip (#977) discards
   windows aggressively: 10 % holes already remove 57 % of windows, 30 % remove 95 %. The night median
   survives because a handful of windows is enough for a median; its error is the dense error.
4. The waveform reference excluded 37 % of windows for self-disagreement. A tighter reference (BIDMC's
   annotated breaths, a belt with marks) is needed before CP2 differences of a few points are read as
   real; differences of 20+ points and a bias of 3 are not reference noise.

Pre-registration for 1.2 (R1): after the peakedness gate, the shuffled-input row is expected to emit on
≤ 5 % of records; the fast tercile is expected to be mostly *refused* rather than wrong (retention there
drops, CP2 of what is kept rises above 70 %); the NREM 3–4 numbers are expected to be unchanged; the
night-level MAE on retained records is expected to fall below 1.5. The peakedness floor is to be fitted
on the Fantasia young half and reported on the elderly half and on slpdb (R5).

## Regenerating

```bash
Tools/research-data/fetch.sh fantasia slpdb
cd Tools/MetricsBench && swift build -c release
.build/release/metricsbench selfcheck
.build/release/metricsbench hrv  --data ../../research-data --seed 1 --csv ../../research-data/bench/hrv-windows.csv
.build/release/metricsbench resp --data ../../research-data --seed 1 --csv ../../research-data/bench/resp-windows.csv
```

Run 2026-11-12 on branch `research/metrics-literature` at the commit that adds this file; the raw
reports are `raw/tier0-hrv-baseline.txt` and `raw/tier0-resp-baseline.txt`.

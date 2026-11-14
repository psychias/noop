# Item 1.1 — HRV window quality and nightly tiers

Branch `research/metrics-literature`. Measured 2026-11-14 with `Tools/MetricsBench` over the public
reference records fetched by `Tools/research-data/fetch.sh` (Fantasia 40, slpdb 18; 58 records,
652,723 ECG beats). Baseline: `00-tier0-baselines.md`. Roadmap row: `docs/research/ROADMAP.md` §Tier 1,
item 1.1; method: `docs/research/01-hrv.md` §4.3 and §6.2.

Every number below is CONFIRMED (measured this run) unless marked INFERRED. Regenerating command and the
full report: `raw/11-hrv-window-quality.txt`.

## What changed

Per 5-minute window (`SleepStager.sessionHrvWindows`, Swift and Kotlin):

| step | before | after |
|---|---|---|
| successive-difference skip | only across a beat the range/ectopic filters removed | also across a pair whose wall-clock gap exceeds its R-R by more than `HRVAnalyzer.pairGapToleranceS` (0.5 s): a beat the strap never reported (`cleanRRTimeAware`, `pairIsTimeConsistent`) |
| window floor | `minBeats` 20 clean beats | `windowRefusePairs` 30 **valid pairs** (Baek 2015: 30 s), or more than 35 % of beats rejected → `refuse`, no RMSSD |
| window tier | — | `limited` below `windowFullPairs` 50 (Esco & Flatt 2014: 60 s) or when in-range coverage (`rrCoverage` over the window) is below `coveragePlausibleFloor` 0.90; `full` otherwise |
| night | mean of windows with ≥ 20 clean beats | mean of non-refused windows; `refuse` (nil) below 3 usable windows or 150 valid pairs; `limited` below 6 full windows; `normal` otherwise (`hrvNightQuality`) |
| nap substitution | a main night refused by the #1118 over-count gate is not replaced by a nap | the same for a main night refused by tier, when it banked any R-R (`inputBeats > 0`); a night with no R-R rows keeps the #1884 fill-in |
| visibility | — | `hrv day=` always-on line gains `tier= win=full/limited/refused pairs=`; `hrv nightSummary` names the refusing gate (`overCount`, `tier`, or both); metric points `hrv_tier` (0/1/2), `hrv_full_windows`, `hrv_valid_pairs` under the computed device id |

What did **not** change: the RMSSD formula, cleaning, bucketing, the #1118 gate, the deep-window mode,
which nights seed baselines. The `limited` tier is stored and logged but drives nothing yet, as
`01-hrv.md` §6.2 requires: the distribution on real nights comes first.

Deviation from the roadmap row, decided after Tier 0 and before this run: the tier is not a pair-count
floor alone. Tier 0 showed that 20/30/50 valid pairs keep over 98.8 % of windows in every regime and
discriminate nothing, while window coverage tracks error. The pair floors stay as the literature-backed
`refuse`/`full` boundaries; coverage below 0.90 (the shipped `coveragePlausibleFloor`, reused rather than
a new number) is what makes a well-populated window `limited`. The roadmap's "additive nullable column +
migration" became three `metricSeries` keys: that is the repository's established additive store for
exactly this kind of per-night instrumentation (`hrv_rr_overcount`, `rhr_primary_session`), and it needs
no migration on either platform.

## Pre-registered before the run (R1)

Written in `00-tier0-baselines.md` and in the bench header before `metricsbench hrv` ran:

1. With the wall-clock skip, the 30 % random-deletion row falls from about +13 % to within ±3 %, with
   no change on the `cap4` (no-loss) row.
2. Gap-tolerance candidates 0.5 / 0.75 / 1.0 s. Selection rule: on the FIT split (Fantasia young), the
   smallest |mean error| at 30 % deletion among candidates whose `cap4` night error stays within ±1 %.
   Reported on the HOLD-OUT split (Fantasia elderly + slpdb) afterwards.
3. Night thresholds 3 usable windows / 150 pairs / 6 full windows are engineering choices with no
   literature constant; the bench reports night error by those counts rather than fitting them.
4. Honest-stream pair loss from the skip: a pair is skipped with probability frac(RR) when frac(RR) is
   below the tolerance, never otherwise (so ≈ 0 below 1.0 s mean R-R, rising toward 25 % at 1.25 s).

Split (R5): FIT = Fantasia young (20 records); HOLD-OUT = Fantasia elderly (20) + slpdb (18). The split
is by record group, not by time, because the records are single two- to eight-hour sessions.

## Results

Reference for every table: the pre-1.1 window rule (replica `HRVBench.legacyWindows`) over the dense ECG
tachogram — the same reference Tier 0 used, so before and after are paired on identical input. "legacy"
is that replica over the sparse stream; it reproduces the Tier 0 table (R3).

### Random single-beat deletion, night mean RMSSD, relative error (Kim 2007 protocol)

| split | deleted | legacy mean | shipped mean | shipped sd | p10 … p90 | pairs kept |
|---|---|---|---|---|---|---|
| fit (n=20) | 5 % | +2.1 % | −0.7 % | 1.4 % | −2.3 … +0.7 | 0.90 |
| fit | 10 % | +3.9 % | −0.3 % | 1.4 % | −2.0 … +1.0 | 0.85 |
| fit | 20 % | +8.0 % | +0.2 % | 1.8 % | −2.1 … +2.0 | 0.78 |
| fit | 30 % | +12.2 % | **+0.8 %** | 2.8 % | −1.7 … +4.9 | 0.70 |
| hold-out (n=38) | 5 % | +2.1 % | −0.6 % | 1.9 % | −1.3 … +0.6 | 0.91 |
| hold-out | 10 % | +4.6 % | −0.2 % | 2.3 % | −1.7 … +1.2 | 0.87 |
| hold-out | 20 % | +8.9 % | −0.2 % | 2.4 % | −3.6 … +2.0 | 0.79 |
| hold-out | 30 % | +13.7 % | **−0.0 %** | 2.8 % | −3.1 … +3.0 | 0.71 |

Prediction 1 holds on both splits: the inflation is gone, the residual is within ±1 % on the mean and
within ±3 % for 80 % of nights. Pre-registration asked for no change on `cap4`; there is a small one,
reported next.

### Gap tolerance (prediction 2)

| split | tolerance | del 5 % | del 10 % | del 20 % | del 30 % | cap4 night error | pairs kept (cap4) |
|---|---|---|---|---|---|---|---|
| fit | 0.50 s | −0.7 % | −0.3 % | +0.2 % | **+0.8 %** | −0.72 % | 0.937 |
| fit | 0.75 s | −0.5 % | −0.1 % | +0.4 % | +1.0 % | −0.58 % | 0.958 |
| fit | 1.00 s | +0.5 % | +1.2 % | +2.6 % | +4.1 % | −0.38 % | 0.989 |
| hold-out | 0.50 s | −0.6 % | −0.2 % | −0.2 % | −0.0 % | −0.80 % | 0.946 |
| hold-out | 0.75 s | −0.4 % | −0.1 % | +0.2 % | +0.3 % | −0.65 % | 0.962 |
| hold-out | 1.00 s | +0.4 % | +1.3 % | +2.3 % | +3.3 % | −0.46 % | 0.993 |

All three candidates pass the ±1 % `cap4` condition on FIT; 0.5 s has the smallest |error| at 30 %
deletion (0.8 vs 1.0 vs 4.1), so the selection rule picks **0.5 s**, which is the shipped
`beatAccuracyToleranceS` reused rather than a new constant. The hold-out agrees (0.0 vs 0.3 vs 3.3).
The difference between 0.5 and 0.75 is inside one standard deviation of the per-night error; 1.0 s is
not a contender because a lost beat at a sleeping R-R of 1.0–1.2 s produces a gap excess of
0.8–1.0 s, which that tolerance accepts.

### Cost on a complete stream (`cap4`, no loss)

| split | nights | shipped bias | 95 % LoA | MAE | MAPE | legacy |
|---|---|---|---|---|---|---|
| fit | 20 | −0.43 ms | −1.93 … +1.08 | 0.61 | 1.0 % | 0.00 |
| hold-out | 38 | −0.26 ms | −1.27 … +0.76 | 0.27 | 0.9 % | 0.00 |

The skip costs about 1 % of the night value on a stream that lost nothing, as a small negative bias.
Two sources, both measured: the tolerance sweep moves the bias from −0.72 % to −0.38 % as fewer honest
pairs are skipped, and the rest comes from the pair floor replacing the 20-beat floor at the night's
thin edge windows. INFERRED: the sign is negative because the honest pairs that get skipped are the ones
ending on a beat longer than a whole second, which under-samples the larger positive differences.

### Honest-stream pair loss (prediction 4)

| split | window mean R-R | windows | pairs kept, mean | p10 | min |
|---|---|---|---|---|---|
| fit | < 0.80 s | 34 | 0.996 | 0.987 | 0.968 |
| fit | 0.80–0.99 s | 201 | 0.980 | 0.947 | 0.913 |
| fit | 1.00–1.24 s | 199 | 0.923 | 0.866 | 0.770 |
| fit | ≥ 1.25 s | 51 | 0.782 | 0.673 | 0.660 |
| hold-out | < 0.80 s | 272 | 0.995 | 0.987 | 0.900 |
| hold-out | 0.80–0.99 s | 800 | 0.990 | 0.971 | 0.887 |
| hold-out | 1.00–1.24 s | 359 | 0.910 | 0.827 | 0.774 |
| hold-out | ≥ 1.25 s | 78 | 0.779 | 0.638 | 0.606 |

As predicted: nothing is lost below a 1 s mean R-R, about 8–9 % between 1.0 and 1.25 s, and about 22 %
above 1.25 s (a sleeping heart rate under 48 bpm). This is variance, not bias — the deletion table above
holds on these same records — but it is the price of whole-second timestamps, and a slow sleeper pays
more of it. The losses cluster in time: at a mean R-R of exactly 1.000 s the beat phase barely drifts
and a window can lose 12–20 % while its neighbours lose none (`metricsbench selfcheck` documents the
mechanism).

### Window tiers

Per-window agreement with the dense reference, shipped code, by tier (ms):

| regime | split | full: n / bias / MAE | limited: n / bias / MAE | refused: n / legacy MAE on them |
|---|---|---|---|---|
| cap4 | fit | 471 / −0.35 / 0.73 | 14 / −1.38 / 1.43 | 4 / 0.00 |
| cap4 | hold-out | 1484 / −0.17 / 0.31 | 25 / −3.04 / 3.25 | 1 / 0.00 |
| holes 10 % | fit | 348 / −0.28 / 0.88 | 137 / −0.62 / 1.60 | 4 / 0.00 |
| holes 10 % | hold-out | 1061 / −0.16 / 0.46 | 448 / −0.48 / 1.36 | 1 / 0.00 |
| holes 30 % | fit | 59 / −0.62 / 1.01 | 424 / −0.61 / 2.04 | 6 / 1.72 |
| holes 30 % | hold-out | 274 / −0.14 / 0.53 | 1233 / −0.22 / 1.52 | 3 / 5.76 |
| holes 50 % | fit | 48 / −0.55 / 1.55 | 437 / −0.48 / 2.44 | 4 / 0.00 |
| holes 50 % | hold-out | 122 / −0.06 / 0.63 | 1387 / −0.33 / 1.91 | 1 / 0.00 |

`limited` windows carry two to four times the MAE of `full` ones in every regime, so the tier separates
what it was meant to separate. Refusal is rare (one to six windows per split per regime) and, where
the legacy code scored those windows, it was 1.7–5.8 ms off on the holed regimes.

### Night tiers (prediction 3)

| regime | split | nights | normal | limited | refuse | full / limited / refused windows per night |
|---|---|---|---|---|---|---|
| cap4 | fit | 20 | 20 | 0 | 0 | 23.6 / 0.7 / 0.2 |
| cap4 | hold-out | 38 | 38 | 0 | 0 | 39.1 / 0.7 / 0.1 |
| holes 10 % | fit | 20 | 19 | 1 | 0 | 17.4 / 6.8 / 0.2 |
| holes 10 % | hold-out | 38 | 38 | 0 | 0 | 27.9 / 11.8 / 0.1 |
| holes 30 % | fit | 20 | 0 | 20 | 0 | 3.0 / 21.2 / 0.3 |
| holes 30 % | hold-out | 38 | 15 | 23 | 0 | 7.2 / 32.4 / 0.2 |
| holes 50 % | fit | 20 | 0 | 20 | 0 | 2.4 / 21.9 / 0.2 |
| holes 50 % | hold-out | 38 | 4 | 34 | 0 | 3.2 / 36.5 / 0.1 |

Night |error| by the counts the night tier reads (holes regimes, shipped, n nights / MAE ms):
full windows < 3: 31 / 0.91; 3–5: 67 / 0.61; 6–11: 9 / 0.69; ≥ 12: 67 / 0.34. Valid pairs were ≥ 2000
on every night, so the 3-window and 150-pair refusal was never reached on this data: **those two
thresholds are unmeasured here (R8)**. The 6-full-window boundary is weakly supported: error rises from
0.34 to 0.6–0.9 ms with fewer full windows, which is real but far inside the ±5 ms band.

Two readings of the night-tier table matter for what comes next:

- Under 30 % holes every FIT night is `limited` although its value is within about 1 ms of the dense
  reference. A mid-window hole lowers in-span coverage exactly as scattered loss does, so `limited`
  means "less than full-quality evidence", not "wrong". If `limited` were switched on as a baseline
  exclusion today it would drop accurate nights on a holed strap. The roadmap's order — log the
  distribution, then decide — stands, and the owner's own nights are the only place that distribution
  can be read.
- Refusal never fired at night level here because these are continuous 2–8 h recordings. A real strap
  night with little R-R is what the 3 / 150 thresholds exist for, and only real nights can show
  whether they are placed sensibly.

## Verification

- Swift: 2,148 StrandAnalytics tests pass through a local XCTest stand-in (no Xcode on this Mac, so
  `swift test` cannot run; the stand-in compiles the package's own test files against a shim and
  runs them from a generated main; the two tests that read a committed Android fixture by walking
  up from the test file path pass once the repository is symlinked beside the runner). Ten existing
  tests were rewritten because their fixtures were physically inconsistent (a 1.2 s beat every 2 s,
  one-window "nights") or asserted the old 20-beat floor; each rewrite says why.
- New Swift tests: `HrvWindowQualityOracleTests` (twelve synthetic streams, sixty lines pinned as a
  literal), `testSessionHrvWindowsSkipAPairWhoseWallClockSaysABeatIsMissing`, pair-floor and
  zero-length-window tests updated to the new definitions.
- Kotlin: ported line for line with the same fixtures and the **same oracle literal**
  (`HrvWindowQualityOracleTest`). The Android module cannot be compiled on this Mac (no Android SDK);
  `HrvAnalyzer.kt` alone was compiled standalone and its new functions checked against the Swift oracle
  values (see the report below). The `SleepStager.kt` and `AnalyticsEngine.kt` halves are **not
  compiled or run locally** and need `./gradlew testFullDebugUnitTest` on a machine with the SDK.
- App targets (`Strand/Data/IntelligenceEngine.swift`): one tuple field, one log line, three metric
  points. Not compiled locally (needs Xcode); CI's `app-build.yml` is the check.
- `metricsbench selfcheck`: 47/47. `Tools/doc_comment_lint.py`: clean. `Tools/parity_ledger.py
  --refresh-derived` (Python 3.13): accepted, derived snapshot updated.

## Regenerate

```bash
cd Tools/MetricsBench && swift build -c release
./.build/release/metricsbench hrv --data ../../research-data --seed 1 --csv ../../research-data/bench/hrv-1.1-windows.csv
./.build/release/metricsbench selfcheck
```

Run 2026-11-14T10:04:39Z, seed 1, 58 records. Datasets under ODC-By 1.0 (attribution in
`Tools/MetricsBench/README.md`).

# MetricsBench — scoring NOOP's overnight vitals against reference data

`Tools/SleepPSG` scores the sleep stager against polysomnography. This tool does the same job for the
other overnight vitals: the 5-minute HRV windows and night mean (`SleepStager.sessionHrvWindows`,
`sessionAvgHRV`) and the RSA respiratory rate (`SleepStager.respRateFromRR`), run **as shipped** from
`Packages/StrandAnalytics`, over reference beat streams from public PhysioNet datasets — and, because
the question that matters is what these estimators do on a WHOOP 5.0, under a simulator of that strap's
R-R regime: whole-second timestamps, at most four R-R words a second, 500 ms filler words flagged
suspect, and holes.

Everything is read-only. Datasets live outside the tree (`research-data/` is git-ignored), are always
command-line arguments, and no NOOP database or wearer's health data is ever opened. Every report
starts with its regenerating command and run date (`docs/VALIDATION_PROTOCOL.md`, R3).

## Get the data

```bash
Tools/research-data/fetch.sh fantasia slpdb     # ~925 MB, verified against PhysioNet's SHA256SUMS
```

See `Tools/research-data/README.md` for every dataset, its licence and the attribution it requires.

## Run it

```bash
cd Tools/MetricsBench
swift run -c release metricsbench selfcheck                       # no dataset needed
swift run -c release metricsbench hrv  --data ../../research-data  # 5-min RMSSD windows, sparse vs dense
swift run -c release metricsbench resp --data ../../research-data  # RSA rate vs the respiration waveform
```

| flag | meaning |
|---|---|
| `--data DIR` | the root `fetch.sh` fills; `fantasia/` and `slpdb/` are found under it. |
| `--fantasia DIR`, `--slpdb DIR` | a dataset somewhere else. |
| `--records N` | the first N records of each dataset — a fast smoke run. |
| `--seed N` | the sparsity simulator's seed (holes, deletions, shuffles). |
| `--holes 0,0.1,0.3` | hole fractions to simulate. |
| `--csv PATH` | per-window rows for plotting or a different cut. |

`selfcheck` is what `swift test` runs: the WFDB decoder against bytes seen on PhysioNet, the simulator's
invariants, the statistics against known values, and the shipped estimators' direction tracking on
synthetic RSA. It also *pins* two baseline behaviours of the shipped respiratory estimator that the
roadmap's item 1.2 is expected to change: a zero-amplitude tachogram still produces a number, and rates
above about 20 breaths/min resolve coarsely. When 1.2 lands those checks are inverted, on purpose.

## What the reports contain

**`hrv`.** The reference is the pre-1.1 window rule (kept verbatim as `HRVBench.legacyWindows`) over the
dense NN rows of each record (ECG beat annotations, whole-second `ts`), so before and after are paired on
identical input. Each regime (`cap4`, `cap4+holes10%+fillers`, …) is scored per night — shipped code
beside the legacy replica — and per window by the shipped tier (`full` / `limited` / `refused`, with
what the legacy code reported for the windows 1.1 refuses); then the night-tier distribution, the pair
loss the wall-clock skip costs an honest stream by mean R-R, the Kim 2007 random-deletion Monte Carlo
(legacy vs shipped), the pre-registered gap-tolerance sweep (0.5 / 0.75 / 1.0 s) and the night error by
the counts the night tier reads. Fantasia young is the fit split, Fantasia elderly + slpdb the hold-out.
Results and their reading: `docs/research/results/01-hrv-window-quality.md`.

**`resp`.** The reference breathing rate is read from the record's respiration waveform twice per
5-minute window — hysteresis-crossing breath count and dominant spectral frequency — and the window is
scored only when the two agree within 2 breaths/min (the remainder is reported as excluded). Per-window
bias, limits of agreement, MAE and CP2 (fraction within ±2 breaths/min) by regime, by group (Fantasia
young / elderly), by stage class (slpdb), and by reference tercile; per-record night value; the
false-emit rate on shuffled R-R; and the synthetic direction-tracking table.

Neither reference is an expert breath annotation: Fantasia and slpdb ship none. BIDMC does, and is the
next loader to add when the PPG-track work (docs/research/04 §6.4) needs it.

## Attribution — required by the datasets' licences

Both datasets are distributed on PhysioNet under the **Open Data Commons Attribution License v1.0**.

- Iyengar N, Peng C-K, Morin R, Goldberger AL, Lipsitz LA. *Age-related alterations in the fractal
  scaling of cardiac interbeat interval dynamics.* Am J Physiol 1996;271:R1078–R1084. PhysioNet
  `fantasia` 1.0.0.
- Ichimaru Y, Moody GB. *Development of the polysomnographic database on CD-ROM.* Psychiatry Clin
  Neurosci 1999;53:175–177. PhysioNet `slpdb` 1.0.0.
- Goldberger AL, Amaral LAN, Glass L, et al. *PhysioBank, PhysioToolkit, and PhysioNet: components of a
  new research resource for complex physiologic signals.* Circulation 2000;101(23):e215–e220.

The WFDB reader is written from the public format descriptions; no WFDB library code is included.

# research-data — public datasets for the metrics benches

`fetch.sh` downloads the datasets the research in `docs/research/` and the benches in
`Tools/MetricsBench` and `Tools/SleepPSG` score against. Data lands in `<repo>/research-data/`
(git-ignored) or in `$RESEARCH_DATA_DIR`, is verified, and is **never committed** — not the archives,
not an extracted file, not a fixture derived from one without checking its licence first.

```bash
Tools/research-data/fetch.sh list
Tools/research-data/fetch.sh fantasia slpdb
```

`datasets.tsv` is the single list: name, kind, URL, how it is verified, licence, and what it is for.
PhysioNet archives are checked file by file against the `SHA256SUMS.txt` they ship; Zenodo files
against the md5 the records API publishes; UCI and ORA publish no checksum, so the observed sha256 is
written to `<name>/.fetched` for the next person to compare. Two datasets (DREAMT, the Malaga treadmill
tests) need a signed PhysioNet data-use agreement and are documented as manual steps.

Each dataset's licence applies to its use here. All of the open ones require **attribution**; the
bench READMEs carry the citations. Nothing personal — a wearer's strap captures, WHOOP exports or
Health data — belongs in this folder's manifest or in git.

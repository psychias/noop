import Foundation

// Datasets — present each PhysioNet record as the streams the benches score: reference beat times from
// the human-reviewed QRS annotations, the respiration waveform, and (slpdb) the 30-second R&K stages.
//
//   Fantasia (Iyengar et al., Am J Physiol 1996): 40 healthy subjects, 20 young (f1y*, f2y*) and 20
//   elderly (f1o*, f2o*), 120 min supine, ECG + respiration at 250 Hz, beat annotations in `.ecg`.
//   MIT-BIH Polysomnographic (Ichimaru & Moody, 1999): 16 male subjects referred for sleep apnoea, ECG
//   beats in `.ecg`, respiration channels, R&K stages every 30 s as the aux string of `.st`.
//
// Both are distributed under the Open Data Commons Attribution License v1.0 — attribution is required
// (README.md). Nothing here writes to a dataset.

struct BeatRecord {
    let dataset: String
    let name: String
    /// A stratum label for the report: "young" / "elderly" for Fantasia, "slpdb" otherwise.
    let group: String
    let fs: Double
    /// Beat times in seconds from the record start, for every annotation in `WFDB.beatCodes`.
    let beatTimesS: [Double]
    /// True where the beat is annotated NORMAL. An interval is NN only when both of its beats are.
    let beatIsNormal: [Bool]
    /// Respiration waveform in physical units at `fs`, when the record has one.
    let respiration: [Double]?
    /// Stage labels (`W`, `1`–`4`, `R`, `MT`) with the sample at which each 30 s epoch starts.
    let stages: [(sampleStart: Int, stage: String)]
    var durationS: Double { Double(respiration?.count ?? Int(beatTimesS.last ?? 0) * Int(fs)) / fs }
}

enum Datasets {
    static func fantasiaRecords(root: URL) throws -> [String] {
        guard let dir = WFDB.findRecordsDir(root) else { throw WFDBError.io("no RECORDS under \(root.path)") }
        return try WFDB.records(dir: dir)
    }

    static func slpdbRecords(root: URL) throws -> [String] {
        guard let dir = WFDB.findRecordsDir(root) else { throw WFDBError.io("no RECORDS under \(root.path)") }
        return try WFDB.records(dir: dir)
    }

    static func loadFantasia(root: URL, record: String) throws -> BeatRecord {
        guard let dir = WFDB.findRecordsDir(root) else { throw WFDBError.io("no RECORDS under \(root.path)") }
        let h = try WFDB.readHeader(dir: dir, record: record)
        let respIdx = h.signals.firstIndex { $0.description.uppercased().hasPrefix("RESP") }
        let signals = try WFDB.readSignals(dir: dir, header: h, only: respIdx.map { Set([$0]) } ?? [])
        let ann = try WFDB.readAnnotations(dir: dir, record: record, annotator: "ecg")
        let beats = ann.filter { WFDB.beatCodes.contains($0.code) }
        // f1y / f2y = young, f1o / f2o = elderly (dataset naming).
        let group = record.count >= 3 && record[record.index(record.startIndex, offsetBy: 2)] == "y" ? "young" : "elderly"
        return BeatRecord(dataset: "fantasia", name: record, group: group, fs: h.fs,
                          beatTimesS: beats.map { Double($0.sample) / h.fs },
                          beatIsNormal: beats.map { $0.code == WFDB.normalBeat },
                          respiration: respIdx.flatMap { signals[$0] }, stages: [])
    }

    static func loadSlpdb(root: URL, record: String) throws -> BeatRecord {
        guard let dir = WFDB.findRecordsDir(root) else { throw WFDBError.io("no RECORDS under \(root.path)") }
        let h = try WFDB.readHeader(dir: dir, record: record)
        // Prefer the summed / nasal respiration channel when several exist.
        let respIdx = h.signals.firstIndex { $0.description.lowercased().hasPrefix("resp") }
        let signals = try WFDB.readSignals(dir: dir, header: h, only: respIdx.map { Set([$0]) } ?? [])
        let ann = try WFDB.readAnnotations(dir: dir, record: record, annotator: "ecg")
        let beats = ann.filter { WFDB.beatCodes.contains($0.code) }
        let st = try WFDB.readAnnotations(dir: dir, record: record, annotator: "st")
        // The `.st` aux string starts with the stage token (W, 1, 2, 3, 4, R, MT); apnoea codes follow it.
        let stages: [(Int, String)] = st.compactMap { a in
            guard let aux = a.aux, let tok = aux.split(separator: " ").first, !tok.isEmpty else { return nil }
            return (a.sample, String(tok))
        }
        return BeatRecord(dataset: "slpdb", name: record, group: "slpdb", fs: h.fs,
                          beatTimesS: beats.map { Double($0.sample) / h.fs },
                          beatIsNormal: beats.map { $0.code == WFDB.normalBeat },
                          respiration: respIdx.flatMap { signals[$0] }, stages: stages)
    }

    /// Coarse stage class at a time, from the 30 s epochs: "wake", "nrem12", "nrem34", "rem", or "?".
    static func stageClass(_ r: BeatRecord, atS t: Double) -> String {
        let s = Int(t * r.fs)
        var label = "?"
        for e in r.stages { if e.sampleStart <= s { label = e.stage } else { break } }
        switch label {
        case "W", "MT": return "wake"
        case "1", "2": return "nrem12"
        case "3", "4": return "nrem34"
        case "R": return "rem"
        default: return "?"
        }
    }
}

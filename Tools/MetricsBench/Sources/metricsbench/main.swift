import Foundation
import StrandAnalytics
import WhoopProtocol

// metricsbench — score NOOP's shipped overnight-vitals estimators against public reference datasets under
// WHOOP-5.0 R-R sparsity.
//
// USAGE:
//   metricsbench selfcheck
//   metricsbench hrv  --data research-data [--fantasia DIR] [--slpdb DIR] [--records N] [--seed N] [--csv out.csv]
//   metricsbench resp --data research-data [--fantasia DIR] [--slpdb DIR] [--records N] [--seed N] [--csv out.csv]
//
// `--data` is the root `Tools/research-data/fetch.sh` fills; `--fantasia` / `--slpdb` override a dataset's
// location. Datasets are read-only and never committed. Every report starts with its regenerating command
// and run date (docs/VALIDATION_PROTOCOL.md R3).

struct Args {
    var command = ""
    var data: String?
    var fantasia: String?
    var slpdb: String?
    var records: Int?
    var seed: UInt64 = 1
    var csv: String?
    var holes: [Double]?
}

func usage() -> Never {
    print("""
    usage: metricsbench <selfcheck|hrv|resp> [--data DIR] [--fantasia DIR] [--slpdb DIR] [--records N] [--seed N]
                        [--holes 0,0.1,0.3] [--csv PATH]

      selfcheck   dataset-free checks of the WFDB reader, the sparsity simulator, the statistics and the
                  direction tracking of the shipped estimators (what `swift test` runs).
      hrv         5-min RMSSD windows and night means, sparse vs dense: shipped 1.1 tiers vs the pre-1.1 replica,
                  window/night tier distributions, honest-stream pair loss, deletion Monte Carlo, gap-tolerance sweep.
      resp        RSA respiratory rate vs the respiration waveform, per window and per record; false-emit;
                  synthetic direction tracking.
    """)
    exit(2)
}

var a = Args()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next() {
    switch k {
    case "--data": a.data = it.next()
    case "--fantasia": a.fantasia = it.next()
    case "--slpdb": a.slpdb = it.next()
    case "--records": a.records = Int(it.next() ?? "")
    case "--seed": a.seed = UInt64(it.next() ?? "") ?? a.seed
    case "--csv": a.csv = it.next()
    case "--holes": a.holes = (it.next() ?? "").split(separator: ",").compactMap { Double($0) }
    case "-h", "--help": usage()
    default:
        if a.command.isEmpty && !k.hasPrefix("-") { a.command = k } else { FileHandle.standardError.write(Data("unknown argument \(k)\n".utf8)); exit(2) }
    }
}
if a.command.isEmpty { usage() }

let iso = ISO8601DateFormatter()
print("metricsbench \(a.command) — \(iso.string(from: Date()))")
print("regenerate: metricsbench " + CommandLine.arguments.dropFirst().joined(separator: " "))

if a.command == "selfcheck" {
    let checks = SelfCheck.all()
    var failed = 0
    for c in checks {
        print("\(c.ok ? "PASS" : "FAIL")  \(c.name)\(c.ok ? "" : "  — \(c.detail)")")
        if !c.ok { failed += 1 }
    }
    print("\(checks.count - failed)/\(checks.count) checks passed")
    exit(failed == 0 ? 0 : 1)
}

func dir(_ explicit: String?, _ name: String) -> URL? {
    if let e = explicit { return URL(fileURLWithPath: e) }
    if let d = a.data { return URL(fileURLWithPath: d).appendingPathComponent(name) }
    return nil
}

var records: [BeatRecord] = []
func load(_ label: String, _ root: URL?, names: (URL) throws -> [String], one: (URL, String) throws -> BeatRecord) {
    guard let root = root, FileManager.default.fileExists(atPath: root.path) else { print("(\(label): not present, skipped)"); return }
    do {
        var ns = try names(root)
        if let n = a.records { ns = Array(ns.prefix(n)) }
        var loaded = 0
        for n in ns {
            do {
                FileHandle.standardError.write(Data("loading \(label)/\(n)\n".utf8))
                records.append(try one(root, n)); loaded += 1
            }
            catch { FileHandle.standardError.write(Data("\(label)/\(n): \(error)\n".utf8)) }
        }
        print("\(label): \(loaded) records from \(root.path)")
    } catch { FileHandle.standardError.write(Data("\(label): \(error)\n".utf8)) }
}
load("fantasia", dir(a.fantasia, "fantasia"), names: Datasets.fantasiaRecords, one: Datasets.loadFantasia)
load("slpdb", dir(a.slpdb, "slpdb"), names: Datasets.slpdbRecords, one: Datasets.loadSlpdb)
if records.isEmpty { FileHandle.standardError.write(Data("no records loaded — pass --data or --fantasia/--slpdb\n".utf8)); exit(1) }
let totalBeats = records.reduce(0) { $0 + $1.beatTimesS.count }
print("records=\(records.count) beats=\(totalBeats) seed=\(a.seed)")

switch a.command {
case "hrv":
    var o = HRVBench.Options(); o.seed = a.seed; o.csv = a.csv
    if let h = a.holes { o.holeFractions = h }
    print(HRVBench.run(records: records, options: o))
case "resp":
    var o = RespBench.Options(); o.seed = a.seed; o.csv = a.csv
    if let h = a.holes { o.holeFractions = h }
    print(RespBench.run(records: records, options: o))
default: usage()
}

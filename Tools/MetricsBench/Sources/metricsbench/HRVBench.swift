import Foundation
import StrandAnalytics
import WhoopProtocol

// HRVBench — what the shipped 5-minute RMSSD windows (`SleepStager.sessionHrvWindows`) and the night
// mean (`sessionAvgHRV`) do when the dense ECG tachogram is thinned to a WHOOP 5.0 stream.
//
// Reference: the same shipped functions over the DENSE NN rows of the record (ECG beats, whole-second
// `ts`). The question is not "is RMSSD right" — the formula is the Task Force one — but "how far does a
// window or a night move when the strap drops beats", and which windows a floor on valid pairs should
// refuse. That is item 1.1 of docs/research/ROADMAP.md, and this bench is its baseline (step 2 of the
// brief's Phase 3) and later its after-measurement.
//
// `validPairs` here is the harness's own count — consecutive in-range rows whose wall-clock gap agrees
// with the interval (`HRVAnalyzer.beatAccuracyToleranceS`) — because the shipped code does not expose one
// yet. When 1.1 lands, the bench switches to the shipped definition and this comment goes.

struct HRVBench {
    struct Options {
        var holeFractions: [Double] = [0, 0.10, 0.30, 0.50]
        var deletionFractions: [Double] = [0.05, 0.10, 0.20, 0.30]
        var pairFloors: [Int] = [20, 30, 50]
        var seed: UInt64 = 1
        var csv: String?
    }

    struct WindowPair {
        let record: String
        let group: String
        let regime: String
        let startTs: Int
        let refRmssd: Double
        let refCleanBeats: Int
        let estRmssd: Double?
        let estCleanBeats: Int
        let validPairs: Int
        /// Σ RR of the window's in-range rows over the wall-clock span they cover (+1 s for the whole-second
        /// stamps). Rounding does not accumulate, a lost beat does: ≈ 1 on a complete window, lower when beats
        /// are missing. The same quantity `HRVAnalyzer.rrCoverage` computes for the #1118 night gate.
        let coverage: Double
    }

    static let tsOffset = 1_700_000_000   // an arbitrary modern epoch; the shipped code only compares gaps

    /// Harness-side valid-pair count for one window's rows (ts-sorted).
    static func validPairs(_ rows: ArraySlice<RRInterval>) -> Int {
        var n = 0
        var prev: RRInterval? = nil
        for r in rows {
            defer { prev = r }
            let ms = Double(r.rrMs)
            guard ms >= HRVAnalyzer.rrMinMs, ms <= HRVAnalyzer.rrMaxMs else { prev = nil; continue }
            guard let p = prev, Double(p.rrMs) >= HRVAnalyzer.rrMinMs, Double(p.rrMs) <= HRVAnalyzer.rrMaxMs else { continue }
            if abs(Double(r.ts - p.ts) - ms / 1000) <= HRVAnalyzer.beatAccuracyToleranceS { n += 1 }
        }
        return n
    }

    /// Harness-side coverage for one window's rows (ts-sorted): Σ RR over the span, both in seconds.
    static func coverage(_ rows: ArraySlice<RRInterval>) -> Double {
        let inRange = rows.filter { Double($0.rrMs) >= HRVAnalyzer.rrMinMs && Double($0.rrMs) <= HRVAnalyzer.rrMaxMs }
        guard let f = inRange.first, let l = inRange.last, inRange.count >= 2 else { return .nan }
        let sum = inRange.dropFirst().reduce(0.0) { $0 + Double($1.rrMs) / 1000 }
        let span = Double(l.ts - f.ts)
        return span <= 0 ? .nan : sum / span
    }

    static func windowRows(_ rows: [RRInterval], start: Int, end: Int) -> ArraySlice<RRInterval> {
        var lo = 0, hi = rows.count
        while lo < hi { let m = (lo + hi) / 2; if rows[m].ts < start { lo = m + 1 } else { hi = m } }
        var e = lo
        while e < rows.count && rows[e].ts < end { e += 1 }
        return rows[lo..<e]
    }

    static func run(records: [BeatRecord], options: Options) -> String {
        var out = ""
        var pairs: [WindowPair] = []
        var nightRows: [(record: String, group: String, regime: String, ref: Double?, est: Double?)] = []
        var deletionRows: [(record: String, fraction: Double, relErr: Double)] = []

        for r in records {
            FileHandle.standardError.write(Data("hrv \(r.dataset)/\(r.name)\n".utf8))
            let dense = Sparsity.denseRows(r, tsOffset: tsOffset)
            guard dense.count > 60 else { continue }
            let start = dense.first!.ts, end = dense.last!.ts
            let refWindows = SleepStager.sessionHrvWindows(start: start, end: end, rr: dense, stages: [])
            let refByStart = Dictionary(uniqueKeysWithValues: refWindows.map { ($0.startTs, $0) })
            let refNight = SleepStager.sessionAvgHRV(start: start, end: end, rr: dense)

            var regimes: [Whoop5Regime] = []
            for (k, h) in options.holeFractions.enumerated() {
                var reg = Whoop5Regime(); reg.holeFraction = h; reg.seed = options.seed &+ UInt64(k) &* 7919
                regimes.append(reg)
            }
            for reg in regimes {
                let stream = Sparsity.apply(reg, to: dense)
                let clean = stream.clean
                let estWindows = SleepStager.sessionHrvWindows(start: start, end: end, rr: clean, stages: [])
                for w in estWindows {
                    guard let ref = refByStart[w.startTs], let refR = ref.rmssd else { continue }
                    let slice = windowRows(clean, start: w.startTs, end: w.startTs + 300)
                    pairs.append(WindowPair(record: r.name, group: r.group, regime: reg.description, startTs: w.startTs,
                                            refRmssd: refR, refCleanBeats: ref.cleanBeats, estRmssd: w.rmssd,
                                            estCleanBeats: w.cleanBeats, validPairs: validPairs(slice), coverage: coverage(slice)))
                }
                nightRows.append((r.name, r.group, reg.description, refNight, SleepStager.sessionAvgHRV(start: start, end: end, rr: clean)))
            }
            for (k, f) in options.deletionFractions.enumerated() {
                let thinned = Sparsity.deleteBeats(fraction: f, from: dense, seed: options.seed &+ 104_729 &* UInt64(k + 1))
                if let ref = refNight, let est = SleepStager.sessionAvgHRV(start: start, end: end, rr: thinned), ref > 0 {
                    deletionRows.append((r.name, f, (est - ref) / ref))
                }
            }
        }

        out += "\n== HRV: night mean RMSSD, sparse vs dense (same shipped functions, ms)\n"
        out += Stats.padR("regime", 22) + " nights refusd  agreement (estimate − reference)\n"
        for reg in Set(nightRows.map { $0.regime }).sorted() {
            let rows = nightRows.filter { $0.regime == reg && $0.ref != nil }
            let refused = rows.filter { $0.est == nil }.count
            let a = Stats.agreement(estimate: rows.map { $0.est ?? .nan }, reference: rows.map { $0.ref! }, tolerance: 5)
            out += String(format: "%@ %6d %6d  %@\n", Stats.padR(reg, 22), rows.count, refused, a.description)
        }
        for g in Set(nightRows.map { $0.group }).sorted() where Set(nightRows.map { $0.group }).count > 1 {
            out += "  group \(g):\n"
            for reg in Set(nightRows.map { $0.regime }).sorted() {
                let rows = nightRows.filter { $0.regime == reg && $0.group == g && $0.ref != nil }
                let a = Stats.agreement(estimate: rows.map { $0.est ?? .nan }, reference: rows.map { $0.ref! }, tolerance: 5)
                out += String(format: "  %@ %6d         %@\n", Stats.padR(reg, 20), rows.count, a.description)
            }
        }

        out += "\n== HRV: 5-min windows, sparse vs dense, by harness validPairs (ms)\n"
        out += "   'refused' = the shipped minBeats floor already returned nil for the window\n"
        let buckets: [(String, (Int) -> Bool)] = [("<20", { $0 < 20 }), ("20–29", { (20..<30).contains($0) }),
                                                 ("30–49", { (30..<50).contains($0) }), ("≥50", { $0 >= 50 })]
        for reg in Set(pairs.map { $0.regime }).sorted() {
            out += " regime \(reg)\n"
            for (label, pred) in buckets {
                let rows = pairs.filter { $0.regime == reg && pred($0.validPairs) }
                let refused = rows.filter { $0.estRmssd == nil }.count
                let scored = rows.filter { $0.estRmssd != nil }
                let a = Stats.agreement(estimate: scored.map { $0.estRmssd! }, reference: scored.map { $0.refRmssd }, tolerance: 5)
                out += String(format: "  validPairs %@ windows=%6d refused=%5d  %@\n", Stats.padR(label, 6), rows.count, refused, a.description)
            }
        }

        out += "\n== HRV: 5-min windows, sparse vs dense, by window coverage (Σ RR / span)\n"
        let covBuckets: [(String, (Double) -> Bool)] = [("<0.70", { $0 < 0.70 }), ("0.70–0.85", { (0.70..<0.85).contains($0) }),
                                                         ("0.85–0.95", { (0.85..<0.95).contains($0) }), ("≥0.95", { $0 >= 0.95 })]
        for reg in Set(pairs.map { $0.regime }).sorted() {
            out += " regime \(reg)\n"
            for (label, pred) in covBuckets {
                let rows = pairs.filter { $0.regime == reg && !$0.coverage.isNaN && pred($0.coverage) }
                let refused = rows.filter { $0.estRmssd == nil }.count
                let scored = rows.filter { $0.estRmssd != nil }
                let a = Stats.agreement(estimate: scored.map { $0.estRmssd! }, reference: scored.map { $0.refRmssd }, tolerance: 5)
                out += String(format: "  coverage %@ windows=%6d refused=%5d  %@\n", Stats.padR(label, 9), rows.count, refused, a.description)
            }
        }

        out += "\n== HRV: what a validPairs floor would do (windows the floor keeps; nights = mean of kept windows)\n"
        for reg in Set(pairs.map { $0.regime }).sorted() {
            out += " regime \(reg)\n"
            for floor in options.pairFloors {
                let scored = pairs.filter { $0.regime == reg && $0.estRmssd != nil }
                let kept = scored.filter { $0.validPairs >= floor }
                let a = Stats.agreement(estimate: kept.map { $0.estRmssd! }, reference: kept.map { $0.refRmssd }, tolerance: 5)
                // Night-level: mean of kept windows vs the dense night mean over all reference windows.
                var nightE: [Double] = [], nightR: [Double] = []
                for rec in Set(scored.map { $0.record }) {
                    let k = kept.filter { $0.record == rec }
                    let refAll = pairs.filter { $0.regime == reg && $0.record == rec }
                    guard !k.isEmpty, !refAll.isEmpty else { continue }
                    nightE.append(Stats.mean(k.map { $0.estRmssd! }))
                    nightR.append(Stats.mean(refAll.map { $0.refRmssd }))
                }
                let an = Stats.agreement(estimate: nightE, reference: nightR, tolerance: 5)
                out += String(format: "  floor %2d: keeps %5d/%5d windows (%4.1f%%)  windows: %@\n", floor, kept.count, scored.count,
                              scored.isEmpty ? 0 : Double(kept.count) / Double(scored.count) * 100, a.description)
                out += String(format: "            nights (%d): %@\n", nightE.count, an.description)
            }
        }

        out += "\n== HRV: random single-beat deletion (Kim 2007 protocol), relative night-mean RMSSD error\n"
        for f in options.deletionFractions {
            let e = deletionRows.filter { $0.fraction == f }.map { $0.relErr }
            out += String(format: "  delete %3.0f%% of beats: n=%d  mean %+.1f%%  sd %.1f%%  p10 %+.1f%%  p90 %+.1f%%\n",
                          f * 100, e.count, Stats.mean(e) * 100, Stats.sd(e) * 100, Stats.quantile(e, 0.1) * 100, Stats.quantile(e, 0.9) * 100)
        }

        if let path = options.csv {
            var csv = "record,group,regime,startTs,refRmssd,refCleanBeats,estRmssd,estCleanBeats,validPairs,coverage\n"
            for p in pairs {
                csv += "\(p.record),\(p.group),\(p.regime),\(p.startTs),\(Stats.fmt(p.refRmssd, 3)),\(p.refCleanBeats),\(p.estRmssd.map { Stats.fmt($0, 3) } ?? ""),\(p.estCleanBeats),\(p.validPairs),\(Stats.fmt(p.coverage, 3))\n"
            }
            try? csv.write(toFile: path, atomically: true, encoding: .utf8)
            out += "\nper-window CSV written to \(path)\n"
        }
        return out
    }
}

import Foundation
import StrandAnalytics
import WhoopProtocol

// HRVBench — what the shipped 5-minute RMSSD windows (`SleepStager.sessionHrvWindows`) and the night
// mean (`sessionAvgHRV`) do when the dense ECG tachogram is thinned to a WHOOP 5.0 stream.
//
// Reference: the pre-1.1 window rule (`legacyWindows`: range + ectopic cleaning, `minBeats` 20, no
// wall-clock skip) over the DENSE NN rows of the record — the same reference Tier 0 scored against, kept
// as a replica so before and after are paired on identical input. `est` is the SHIPPED code over the
// sparse stream; `legacy` is the replica over the same sparse stream, which reproduces the Tier 0 table
// (R3: re-derive, never cite).
//
// Split (R5): Fantasia young = fit (the gap-tolerance candidate is chosen here); Fantasia elderly and
// slpdb = hold-out (everything is reported there too). The tolerance candidates, the tier thresholds and
// the predictions are in docs/research/results/01-hrv-window-quality.md, written before this ran.

struct HRVBench {
    struct Options {
        var holeFractions: [Double] = [0, 0.10, 0.30, 0.50]
        var deletionFractions: [Double] = [0.05, 0.10, 0.20, 0.30]
        var gapTolerances: [Double] = [0.5, 0.75, 1.0]
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
        let legacyRmssd: Double?
        let estCleanBeats: Int
        let validPairs: Int
        let coverage: Double
        let tier: HRVAnalyzer.HrvWindowTier
    }

    struct NightRow {
        let record: String
        let group: String
        let regime: String
        let ref: Double?
        let est: Double?
        let legacy: Double?
        let quality: SleepStager.HrvNightQuality
    }

    struct DeletionRow {
        let record: String
        let group: String
        let fraction: Double
        let tolerance: Double
        let relErr: Double
        let relErrLegacy: Double
        /// validPairs ÷ (cleanBeats − 1) summed over scored windows: how many pairs the wall-clock skip kept.
        let pairsKept: Double
    }

    static let tsOffset = 1_700_000_000   // an arbitrary modern epoch; the shipped code only compares gaps

    static func split(_ group: String) -> String { group == "young" ? "fit" : "holdout" }

    /// The pre-1.1 window rule, kept verbatim as the reference and the before-side of every paired table.
    static func legacyWindows(start: Int, end: Int, rr: [RRInterval]) -> [(startTs: Int, cleanBeats: Int, rmssd: Double?)] {
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return [] }
        var out: [(Int, Int, Double?)] = []
        var t = start, i = 0
        repeat {
            let isFinal = t + 300 >= end
            while i < seg.count && seg[i].ts < t { i += 1 }
            var j = i
            if isFinal { j = seg.count } else { while j < seg.count && seg[j].ts < t + 300 { j += 1 } }
            let bucket = seg[i..<j].map { Double($0.rrMs) }
            if !isFinal { i = j }
            let cleaned = HRVAnalyzer.cleanRRGapAware(bucket)
            let rmssd: Double? = cleaned.nn.count >= HRVAnalyzer.minBeats ? HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) : nil
            out.append((t, cleaned.nn.count, rmssd))
            t += 300
        } while t < end
        return out
    }
    static func legacyNight(start: Int, end: Int, rr: [RRInterval]) -> Double? {
        let v = legacyWindows(start: start, end: end, rr: rr).compactMap { $0.rmssd }
        return v.isEmpty ? nil : Stats.mean(v)
    }
    /// The shipped night rule without the #1118 over-count gate (never triggered by thinning), for a
    /// given gap tolerance: nil when the night tier is `refuse`, else the mean of the usable windows.
    static func shippedNight(start: Int, end: Int, rr: [RRInterval], tolerance: Double) -> (value: Double?, quality: SleepStager.HrvNightQuality, windows: [SleepStager.HrvWindow]) {
        let w = SleepStager.sessionHrvWindows(start: start, end: end, rr: rr, stages: [], gapToleranceS: tolerance)
        let q = SleepStager.hrvNightQuality(w)
        let v = w.compactMap { $0.rmssd }
        return (q.tier == .refuse || v.isEmpty ? nil : Stats.mean(v), q, w)
    }

    static func run(records: [BeatRecord], options: Options) -> String {
        var out = ""
        var pairs: [WindowPair] = []
        var nights: [NightRow] = []
        var deletions: [DeletionRow] = []
        let tolDefault = HRVAnalyzer.pairGapToleranceS

        for r in records {
            FileHandle.standardError.write(Data("hrv \(r.dataset)/\(r.name)\n".utf8))
            let dense = Sparsity.denseRows(r, tsOffset: tsOffset)
            guard dense.count > 60 else { continue }
            let start = dense.first!.ts, end = dense.last!.ts
            let refWindows = legacyWindows(start: start, end: end, rr: dense)
            let refByStart = Dictionary(uniqueKeysWithValues: refWindows.map { ($0.startTs, $0) })
            let refNight = legacyNight(start: start, end: end, rr: dense)

            var regimes: [Whoop5Regime] = []
            for (k, h) in options.holeFractions.enumerated() {
                var reg = Whoop5Regime(); reg.holeFraction = h; reg.seed = options.seed &+ UInt64(k) &* 7919
                regimes.append(reg)
            }
            for reg in regimes {
                let clean = Sparsity.apply(reg, to: dense).clean
                let shipped = shippedNight(start: start, end: end, rr: clean, tolerance: tolDefault)
                let legacyW = Dictionary(uniqueKeysWithValues: legacyWindows(start: start, end: end, rr: clean).map { ($0.startTs, $0) })
                for w in shipped.windows {
                    guard let ref = refByStart[w.startTs], let refR = ref.rmssd else { continue }
                    pairs.append(WindowPair(record: r.name, group: r.group, regime: reg.description, startTs: w.startTs,
                                            refRmssd: refR, refCleanBeats: ref.cleanBeats, estRmssd: w.rmssd,
                                            legacyRmssd: legacyW[w.startTs]?.rmssd, estCleanBeats: w.cleanBeats,
                                            validPairs: w.validPairs, coverage: w.coverage, tier: w.tier))
                }
                nights.append(NightRow(record: r.name, group: r.group, regime: reg.description, ref: refNight,
                                       est: shipped.value, legacy: legacyNight(start: start, end: end, rr: clean), quality: shipped.quality))
            }
            for (k, f) in options.deletionFractions.enumerated() {
                let thinned = Sparsity.deleteBeats(fraction: f, from: dense, seed: options.seed &+ 104_729 &* UInt64(k + 1))
                guard let ref = refNight, ref > 0, let leg = legacyNight(start: start, end: end, rr: thinned) else { continue }
                for tol in options.gapTolerances {
                    let s = shippedNight(start: start, end: end, rr: thinned, tolerance: tol)
                    guard let est = s.value else { continue }
                    let scored = s.windows.filter { $0.rmssd != nil }
                    let kept = Double(scored.reduce(0) { $0 + $1.validPairs }) / Double(max(1, scored.reduce(0) { $0 + max(0, $1.cleanBeats - 1) }))
                    deletions.append(DeletionRow(record: r.name, group: r.group, fraction: f, tolerance: tol,
                                                 relErr: (est - ref) / ref, relErrLegacy: (leg - ref) / ref, pairsKept: kept))
                }
            }
        }

        let regimesSorted = Set(nights.map { $0.regime }).sorted()
        let splits = ["fit", "holdout"]

        out += "\n== HRV: night mean RMSSD, sparse vs dense (ms). shipped = 1.1 code; legacy = pre-1.1 replica on the same stream\n"
        out += Stats.padR("regime", 22) + " split    nights refusd  shipped (estimate − reference)                                   | legacy\n"
        for reg in regimesSorted {
            for sp in splits {
                let rows = nights.filter { $0.regime == reg && split($0.group) == sp && $0.ref != nil }
                guard !rows.isEmpty else { continue }
                let refused = rows.filter { $0.est == nil }.count
                let a = Stats.agreement(estimate: rows.map { $0.est ?? .nan }, reference: rows.map { $0.ref! }, tolerance: 5)
                let l = Stats.agreement(estimate: rows.map { $0.legacy ?? .nan }, reference: rows.map { $0.ref! }, tolerance: 5)
                out += String(format: "%@ %@ %6d %6d  %@ | bias %+.2f MAE %.2f\n", Stats.padR(reg, 22), Stats.padR(sp, 8), rows.count, refused, a.description, l.bias, l.mae)
            }
        }

        out += "\n== HRV: night tier distribution by regime (shipped)\n"
        out += Stats.padR("regime", 22) + " split    nights  normal limited refuse   full/limited/refused windows (mean per night)\n"
        for reg in regimesSorted {
            for sp in splits {
                let rows = nights.filter { $0.regime == reg && split($0.group) == sp }
                guard !rows.isEmpty else { continue }
                let n = rows.count
                func c(_ t: HRVAnalyzer.HrvNightTier) -> Int { rows.filter { $0.quality.tier == t }.count }
                let f = Stats.mean(rows.map { Double($0.quality.fullWindows) }), li = Stats.mean(rows.map { Double($0.quality.limitedWindows) }), re = Stats.mean(rows.map { Double($0.quality.refusedWindows) })
                out += String(format: "%@ %@ %6d  %6d %7d %6d   %.1f / %.1f / %.1f\n", Stats.padR(reg, 22), Stats.padR(sp, 8), n, c(.normal), c(.limited), c(.refuse), f, li, re)
            }
        }

        out += "\n== HRV: 5-min windows by shipped tier, estimate − reference (ms). 'refused: legacy' = what the pre-1.1 code reported for the windows 1.1 refuses\n"
        for reg in regimesSorted {
            out += " regime \(reg)\n"
            for sp in splits {
                let rows = pairs.filter { $0.regime == reg && split($0.group) == sp }
                guard !rows.isEmpty else { continue }
                for tier in [HRVAnalyzer.HrvWindowTier.full, .limited] {
                    let t = rows.filter { $0.tier == tier && $0.estRmssd != nil }
                    let a = Stats.agreement(estimate: t.map { $0.estRmssd! }, reference: t.map { $0.refRmssd }, tolerance: 5)
                    out += String(format: "  %@ %@ windows=%6d  %@\n", Stats.padR(sp, 8), Stats.padR(tier.rawValue, 8), t.count, a.description)
                }
                let refused = rows.filter { $0.tier == .refuse }
                let legacyScored = refused.filter { $0.legacyRmssd != nil }
                let a = Stats.agreement(estimate: legacyScored.map { $0.legacyRmssd! }, reference: legacyScored.map { $0.refRmssd }, tolerance: 5)
                out += String(format: "  %@ refused  windows=%6d  of which legacy scored %d: %@\n", Stats.padR(sp, 8), refused.count, legacyScored.count, a.description)
            }
        }

        out += "\n== HRV: wall-clock skip on an HONEST stream (cap4, no loss): pairs kept = validPairs ÷ (cleanBeats − 1) per scored window, by window mean R-R\n"
        out += "   prediction: with whole-second stamps a pair is skipped with probability frac(RR) when frac(RR) < tolerance, never otherwise\n"
        let cap4 = pairs.filter { $0.regime == "cap4" && $0.estRmssd != nil && $0.estCleanBeats > 1 }
        let rrBuckets: [(String, (Double) -> Bool)] = [("< 0.80 s", { $0 < 0.80 }), ("0.80–0.99", { (0.80..<1.0).contains($0) }),
                                                        ("1.00–1.24", { (1.0..<1.25).contains($0) }), ("≥ 1.25 s", { $0 >= 1.25 })]
        for sp in splits {
            for (label, pred) in rrBuckets {
                // Window mean R-R from reference clean beats ≈ 300 s / cleanBeats (dense windows are complete).
                let rows = cap4.filter { split($0.group) == sp && pred(300.0 / Double(max(1, $0.refCleanBeats))) }
                guard !rows.isEmpty else { continue }
                let kept = rows.map { Double($0.validPairs) / Double($0.estCleanBeats - 1) }
                out += String(format: "  %@ RR %@ windows=%6d  kept mean %.3f  p10 %.3f  min %.3f\n", Stats.padR(sp, 8), Stats.padR(label, 10), rows.count, Stats.mean(kept), Stats.quantile(kept, 0.1), kept.min() ?? .nan)
            }
        }

        out += "\n== HRV: random single-beat deletion (Kim 2007 protocol), relative night-mean error, legacy vs shipped at the DEFAULT tolerance \(tolDefault) s\n"
        for sp in splits {
            for f in options.deletionFractions {
                let rows = deletions.filter { $0.fraction == f && $0.tolerance == tolDefault && split($0.group) == sp }
                guard !rows.isEmpty else { continue }
                let l = rows.map { $0.relErrLegacy }, e = rows.map { $0.relErr }
                out += String(format: "  %@ delete %3.0f%%: n=%3d  legacy mean %+.1f%% sd %.1f%%   shipped mean %+.1f%% sd %.1f%% p10 %+.1f%% p90 %+.1f%%  pairs kept %.2f\n",
                              Stats.padR(sp, 8), f * 100, rows.count, Stats.mean(l) * 100, Stats.sd(l) * 100, Stats.mean(e) * 100, Stats.sd(e) * 100,
                              Stats.quantile(e, 0.1) * 100, Stats.quantile(e, 0.9) * 100, Stats.mean(rows.map { $0.pairsKept }))
            }
        }

        out += "\n== HRV: gap-tolerance candidates (pre-registered 0.5 / 0.75 / 1.0 s). Selection rule: on FIT, smallest |mean error| at 30 % deletion among candidates whose cap4 night error stays within ±1 %\n"
        for sp in splits {
            for tol in options.gapTolerances {
                var line = String(format: "  %@ tol %.2f:", Stats.padR(sp, 8), tol)
                for f in options.deletionFractions {
                    let rows = deletions.filter { $0.fraction == f && $0.tolerance == tol && split($0.group) == sp }
                    line += String(format: "  del %2.0f%% %+.1f%%", f * 100, rows.isEmpty ? .nan : Stats.mean(rows.map { $0.relErr }) * 100)
                }
                // cap4 (no loss) night error and pairs kept at this tolerance, recomputed per night.
                var capErr: [Double] = [], capKept: [Double] = []
                for r in records {
                    guard split(r.group) == sp else { continue }
                    let dense = Sparsity.denseRows(r, tsOffset: tsOffset)
                    guard dense.count > 60 else { continue }
                    let start = dense.first!.ts, end = dense.last!.ts
                    var reg = Whoop5Regime(); reg.seed = options.seed
                    let clean = Sparsity.apply(reg, to: dense).clean
                    guard let ref = legacyNight(start: start, end: end, rr: dense), ref > 0 else { continue }
                    let s = shippedNight(start: start, end: end, rr: clean, tolerance: tol)
                    if let est = s.value { capErr.append((est - ref) / ref) }
                    let scored = s.windows.filter { $0.rmssd != nil }
                    capKept.append(Double(scored.reduce(0) { $0 + $1.validPairs }) / Double(max(1, scored.reduce(0) { $0 + max(0, $1.cleanBeats - 1) })))
                }
                line += String(format: "  | cap4 %+.2f%% (n=%d) pairs kept %.3f\n", Stats.mean(capErr) * 100, capErr.count, Stats.mean(capKept))
                out += line
            }
        }

        out += "\n== HRV: night |error| by the counts the night tier reads (holes regimes, shipped). Evidence for the 3 / 150 / 6 thresholds\n"
        let holed = nights.filter { $0.regime != "cap4" && $0.ref != nil }
        let fullBuckets: [(String, (Int) -> Bool)] = [("full <3", { $0 < 3 }), ("full 3–5", { (3...5).contains($0) }), ("full 6–11", { (6...11).contains($0) }), ("full ≥12", { $0 >= 12 })]
        for (label, pred) in fullBuckets {
            let rows = holed.filter { pred($0.quality.fullWindows) }
            let scored = rows.filter { $0.est != nil }
            let a = Stats.agreement(estimate: scored.map { $0.est! }, reference: scored.map { $0.ref! }, tolerance: 5)
            let legacyOnRefused = rows.filter { $0.est == nil && $0.legacy != nil }
            let l = Stats.agreement(estimate: legacyOnRefused.map { $0.legacy! }, reference: legacyOnRefused.map { $0.ref! }, tolerance: 5)
            out += String(format: "  %@ nights=%4d scored=%4d  %@ | refused %d, legacy on those: MAE %.2f\n", Stats.padR(label, 10), rows.count, scored.count, a.description, legacyOnRefused.count, l.mae)
        }
        let pairBuckets: [(String, (Int) -> Bool)] = [("pairs <150", { $0 < 150 }), ("150–499", { (150..<500).contains($0) }), ("500–1999", { (500..<2000).contains($0) }), ("≥2000", { $0 >= 2000 })]
        for (label, pred) in pairBuckets {
            let rows = holed.filter { pred($0.quality.validPairs) }
            let scored = rows.filter { $0.est != nil }
            let a = Stats.agreement(estimate: scored.map { $0.est! }, reference: scored.map { $0.ref! }, tolerance: 5)
            out += String(format: "  %@ nights=%4d scored=%4d  %@\n", Stats.padR(label, 10), rows.count, scored.count, a.description)
        }

        if let path = options.csv {
            var csv = "record,group,split,regime,startTs,refRmssd,refCleanBeats,estRmssd,legacyRmssd,estCleanBeats,validPairs,coverage,tier\n"
            for p in pairs {
                csv += "\(p.record),\(p.group),\(split(p.group)),\(p.regime),\(p.startTs),\(Stats.fmt(p.refRmssd, 3)),\(p.refCleanBeats),\(p.estRmssd.map { Stats.fmt($0, 3) } ?? ""),\(p.legacyRmssd.map { Stats.fmt($0, 3) } ?? ""),\(p.estCleanBeats),\(p.validPairs),\(Stats.fmt(p.coverage, 3)),\(p.tier.rawValue)\n"
            }
            try? csv.write(toFile: path, atomically: true, encoding: .utf8)
            out += "\nper-window CSV written to \(path)\n"
        }
        return out
    }
}

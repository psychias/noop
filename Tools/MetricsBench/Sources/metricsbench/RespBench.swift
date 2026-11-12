import Foundation
import StrandAnalytics
import WhoopProtocol

// RespBench — the shipped RSA respiratory-rate estimator (`SleepStager.respRateFromRR`) against a
// reference breathing rate read from the record's respiration waveform, per 5-minute window and per
// record, under dense and WHOOP-5.0-sparse R-R, plus the two honesty checks docs/research/04 asks for:
// the false-emit rate on shuffled R-R (the 13.33 breaths/min floor) and direction tracking on synthetic
// RSA at several injected rates.
//
// REFERENCE INSTRUMENT (R4). Two readings of the respiration waveform per window: a breath count (peaks of
// the detrended, smoothed waveform, rate = 60 / median interval) and the dominant spectral frequency in
// the 0.08–0.60 Hz band. A window is scored only when the two agree within 2 breaths/min; otherwise the
// reference itself is unreliable (the Charlton 2016 practice) and the window is excluded and counted.
// Neither reading is an expert annotation: Fantasia and slpdb ship no breath marks.

struct RespBench {
    struct Options {
        var holeFractions: [Double] = [0, 0.10, 0.30]
        var seed: UInt64 = 1
        var csv: String?
    }

    struct WindowRow {
        let record: String
        let group: String
        let stage: String
        let regime: String
        let startS: Int
        let reference: Double
        let estimate: Double     // NaN when the estimator refused
    }

    static let windowS = 300
    static let tsOffset = HRVBench.tsOffset

    // MARK: reference from the waveform

    /// Per-window reference rate (breaths/min) from a respiration waveform at `fs`, or nil when the two
    /// readings disagree or the window is flat. Also returns the pair for the report's reference audit.
    static func referenceRate(_ x: ArraySlice<Double>, fs: Double) -> (rate: Double?, count: Double, spectral: Double) {
        let y = detrendAndSmooth(Array(x), fs: fs)
        let count = countingRate(y, fs: fs)
        let spec = spectralRate(y, fs: fs)
        guard !count.isNaN, !spec.isNaN, abs(count - spec) <= 2.0 else { return (nil, count, spec) }
        return (count, count, spec)
    }

    static func detrendAndSmooth(_ x: [Double], fs: Double) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        // Subtract a centred 10 s moving mean (removes drift), then a 1 s moving mean (removes cardiac
        // and mains ripple) — both plain box filters, so the instrument is reproducible anywhere.
        func box(_ v: [Double], halfWidth: Int) -> [Double] {
            var cum = [Double](repeating: 0, count: v.count + 1)
            for i in 0..<v.count { cum[i + 1] = cum[i] + v[i] }
            var o = [Double](repeating: 0, count: v.count)
            for i in 0..<v.count {
                let a = max(0, i - halfWidth), b = min(v.count - 1, i + halfWidth)
                o[i] = (cum[b + 1] - cum[a]) / Double(b - a + 1)
            }
            return o
        }
        let trend = box(x, halfWidth: Int(5 * fs))
        var d = [Double](repeating: 0, count: n)
        for i in 0..<n { d[i] = x[i] - trend[i] }
        return box(d, halfWidth: Int(0.5 * fs))
    }

    /// Breath count by hysteresis crossings (Schäfer & Kratky 2008's "count" family): one breath per upward
    /// crossing of +h after the signal has been below −h, with h = 0.2 × the window SD, so residual cardiac
    /// ripple cannot add breaths. Rate = 60 / median(interval between crossings).
    static func countingRate(_ y: [Double], fs: Double) -> Double {
        let sd = Stats.sd(y)
        guard !sd.isNaN, sd > 0 else { return .nan }
        let h = 0.2 * sd
        var armed = false
        var crossings: [Int] = []
        for i in 0..<y.count {
            if y[i] < -h { armed = true }
            else if armed && y[i] > h { crossings.append(i); armed = false }
        }
        guard crossings.count >= 4 else { return .nan }
        var gaps: [Double] = []
        for k in 1..<crossings.count { gaps.append(Double(crossings[k] - crossings[k - 1]) / fs) }
        let med = Stats.median(gaps)
        return med > 0 ? 60 / med : .nan
    }

    /// Dominant frequency in 0.08–0.60 Hz by direct DFT on a decimated copy (every 25 ms), 0.005 Hz steps.
    static func spectralRate(_ y: [Double], fs: Double) -> Double {
        let step = max(1, Int(fs / 40))
        let z = stride(from: 0, to: y.count, by: step).map { y[$0] }
        let dt = Double(step) / fs
        guard z.count >= 16 else { return .nan }
        let m = Stats.mean(z)
        var bestF = Double.nan, bestP = 0.0
        var f = 0.08
        while f <= 0.60 + 1e-9 {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f * dt
            for (j, v) in z.enumerated() { let a = w * Double(j); re += (v - m) * cos(a); im -= (v - m) * sin(a) }
            let p = re * re + im * im
            if p > bestP { bestP = p; bestF = f }
            f += 0.005
        }
        return bestF.isNaN ? .nan : bestF * 60
    }

    // MARK: run

    static func run(records: [BeatRecord], options: Options) -> String {
        var out = ""
        var rows: [WindowRow] = []
        var nights: [(record: String, group: String, regime: String, ref: Double, est: Double)] = []
        var refAudit = (scored: 0, disagreeing: 0, flat: 0)
        var shuffled: [(record: String, est: Double)] = []

        for r in records {
            FileHandle.standardError.write(Data("resp \(r.dataset)/\(r.name)\n".utf8))
            guard let resp = r.respiration else { continue }
            let dense = Sparsity.denseRows(r, tsOffset: tsOffset)
            guard dense.count > 60 else { continue }
            let totalS = Int(Double(resp.count) / r.fs)
            // Reference per window.
            var refs: [Int: Double] = [:]
            var t = 0
            while t + windowS <= totalS {
                let a = Int(Double(t) * r.fs), b = min(resp.count, Int(Double(t + windowS) * r.fs))
                let ref = referenceRate(resp[a..<b], fs: r.fs)
                if let v = ref.rate { refs[t] = v; refAudit.scored += 1 }
                else if ref.count.isNaN || ref.spectral.isNaN { refAudit.flat += 1 }
                else { refAudit.disagreeing += 1 }
                t += windowS
            }
            guard !refs.isEmpty else { continue }
            var regimes: [Whoop5Regime] = []
            for (k, h) in options.holeFractions.enumerated() {
                var reg = Whoop5Regime(); reg.holeFraction = h; reg.seed = options.seed &+ UInt64(k) &* 7919
                regimes.append(reg)
            }
            let denseRegimeName = "dense"
            let streams: [(String, [RRInterval])] = [(denseRegimeName, dense)] + regimes.map { ($0.description, Sparsity.apply($0, to: dense).clean) }
            for (name, rr) in streams {
                for (t, ref) in refs.sorted(by: { $0.key < $1.key }) {
                    let s = tsOffset + t, e = tsOffset + t + windowS
                    let est = SleepStager.respRateFromRR(rr, start: s, end: e)
                    rows.append(WindowRow(record: r.name, group: r.group, stage: r.stages.isEmpty ? "-" : Datasets.stageClass(r, atS: Double(t) + 150),
                                          regime: name, startS: t, reference: ref, estimate: est))
                }
                let refMedian = Stats.median(Array(refs.values))
                let nightEst = SleepStager.respRateFromRR(rr, start: tsOffset, end: tsOffset + totalS)
                nights.append((r.name, r.group, name, refMedian, nightEst))
            }
            // False-emit: values shuffled, timestamps kept.
            let sh = Sparsity.shuffleValues(dense, seed: options.seed &+ 31)
            shuffled.append((r.name, SleepStager.respRateFromRR(sh, start: tsOffset, end: tsOffset + totalS)))
        }

        out += "\n== RESP: reference audit (5-min windows of the respiration waveform)\n"
        out += "  scored=\(refAudit.scored)  excluded: count/spectral disagree >2 bpm=\(refAudit.disagreeing)  flat=\(refAudit.flat)\n"

        let regimes = ["dense"] + Set(rows.map { $0.regime }).subtracting(["dense"]).sorted()
        out += "\n== RESP: per-window, estimate − reference (breaths/min); 'retained' = estimator returned a number\n"
        for reg in regimes {
            let rs = rows.filter { $0.regime == reg }
            let kept = rs.filter { !$0.estimate.isNaN }
            let a = Stats.agreement(estimate: kept.map { $0.estimate }, reference: kept.map { $0.reference }, tolerance: 2)
            out += String(format: "  %@ retained %5d/%5d (%4.1f%%)  %@\n", Stats.padR(reg, 22), kept.count, rs.count,
                          rs.isEmpty ? 0 : Double(kept.count) / Double(rs.count) * 100, a.description)
        }
        let groups = Set(rows.map { $0.group }).sorted()
        if groups.count > 1 {
            out += "  by group (dense):\n"
            for g in groups {
                let kept = rows.filter { $0.regime == "dense" && $0.group == g && !$0.estimate.isNaN }
                let a = Stats.agreement(estimate: kept.map { $0.estimate }, reference: kept.map { $0.reference }, tolerance: 2)
                out += String(format: "    %@ %@\n", Stats.padR(g, 10), a.description)
            }
        }
        let stages = Set(rows.map { $0.stage }).subtracting(["-"]).sorted()
        if !stages.isEmpty {
            out += "  by stage class (dense):\n"
            for s in stages {
                let kept = rows.filter { $0.regime == "dense" && $0.stage == s && !$0.estimate.isNaN }
                let a = Stats.agreement(estimate: kept.map { $0.estimate }, reference: kept.map { $0.reference }, tolerance: 2)
                out += String(format: "    %@ %@\n", Stats.padR(s, 10), a.description)
            }
        }
        out += "  by reference tercile (dense):\n"
        let denseRows = rows.filter { $0.regime == "dense" }
        let t1 = Stats.quantile(denseRows.map { $0.reference }, 1.0 / 3), t2 = Stats.quantile(denseRows.map { $0.reference }, 2.0 / 3)
        for (label, pred) in [("slow", { (x: Double) in x < t1 }), ("mid", { (x: Double) in x >= t1 && x < t2 }), ("fast", { (x: Double) in x >= t2 })] {
            let kept = denseRows.filter { pred($0.reference) && !$0.estimate.isNaN }
            let a = Stats.agreement(estimate: kept.map { $0.estimate }, reference: kept.map { $0.reference }, tolerance: 2)
            out += String(format: "    %@ %@\n", Stats.padR(label, 10), a.description)
        }

        out += "\n== RESP: per-record night value (shipped median over the whole record) vs reference median\n"
        for reg in regimes {
            let ns = nights.filter { $0.regime == reg }
            let kept = ns.filter { !$0.est.isNaN }
            let a = Stats.agreement(estimate: kept.map { $0.est }, reference: kept.map { $0.ref }, tolerance: 1)
            out += String(format: "  %@ retained %3d/%3d  %@\n", Stats.padR(reg, 22), kept.count, ns.count, a.description)
        }

        out += "\n== RESP: false-emit on shuffled R-R values (timestamps kept; no breathing exists in the input)\n"
        let emitted = shuffled.filter { !$0.est.isNaN }
        out += "  records=\(shuffled.count)  emitted a number=\(emitted.count)"
        if !emitted.isEmpty {
            let v = emitted.map { $0.est }
            out += String(format: "  values: median %.2f  min %.2f  max %.2f", Stats.median(v), v.min()!, v.max()!)
        }
        out += "\n  (a correct estimator refuses all of these; 13.33 is the peak-picker's own floor)\n"

        out += "\n== RESP: direction tracking on synthetic RSA (dense, whole-second ts)\n"
        for line in SyntheticRSA.trackingReport() { out += "  \(line)\n" }

        if let path = options.csv {
            var csv = "record,group,stage,regime,startS,reference,estimate\n"
            for w in rows { csv += "\(w.record),\(w.group),\(w.stage),\(w.regime),\(w.startS),\(Stats.fmt(w.reference, 3)),\(w.estimate.isNaN ? "" : Stats.fmt(w.estimate, 3))\n" }
            try? csv.write(toFile: path, atomically: true, encoding: .utf8)
            out += "\nper-window CSV written to \(path)\n"
        }
        return out
    }
}

/// Synthetic R-R with a known RSA component — the "validate against the artifact" rule (AGENTS.md): the
/// estimator must recover SEVERAL injected rates, and must refuse when the modulation is gone.
enum SyntheticRSA {
    static let rates: [Double] = [8, 11, 15, 20, 24]
    static let amplitudesMs: [Double] = [60, 30, 15, 5, 0]

    /// `minutes` of beats at `meanRRMs` with an RSA sinusoid of `amplitudeMs` at `breathsPerMin`, plus a
    /// little deterministic jitter so the tachogram is never a pure tone. Whole-second `ts`.
    static func rows(breathsPerMin: Double, amplitudeMs: Double, meanRRMs: Double = 1000, minutes: Double = 10,
                     jitterMs: Double = 8, seed: UInt64 = 7) -> [RRInterval] {
        var rng = SplitMix64(seed: seed)
        var t = 0.0
        var out: [RRInterval] = []
        let f = breathsPerMin / 60
        while t < minutes * 60 {
            let rr = meanRRMs + amplitudeMs * sin(2 * Double.pi * f * t) + (rng.nextDouble() - 0.5) * 2 * jitterMs
            t += rr / 1000
            out.append(RRInterval(ts: HRVBench.tsOffset + Int(t.rounded(.down)), rrMs: Int(rr.rounded()), srcChannel: .whoop5Historical))
        }
        return out
    }

    static func estimate(breathsPerMin: Double, amplitudeMs: Double) -> Double {
        let r = rows(breathsPerMin: breathsPerMin, amplitudeMs: amplitudeMs)
        return SleepStager.respRateFromRR(r, start: r.first!.ts, end: r.last!.ts)
    }

    static func trackingReport() -> [String] {
        var lines: [String] = []
        var header = Stats.padR("amplitude \\ rate", 14)
        for r in rates { header += String(format: "%8.0f", r) }
        lines.append(header)
        for a in amplitudesMs {
            var line = Stats.padR("\(Int(a)) ms", 14)
            for r in rates {
                let e = estimate(breathsPerMin: r, amplitudeMs: a)
                line += e.isNaN ? Stats.padL("refuse", 8) : String(format: "%8.2f", e)
            }
            lines.append(line)
        }
        lines.append("(amplitude 0 ms has no breathing in it; every number on that row is a false emit)")
        return lines
    }
}

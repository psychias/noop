import Foundation
import StrandAnalytics
import WhoopProtocol

// SelfCheck — the dataset-free checks that keep this harness honest. `swift test` runs them in CI through
// `metricsbenchTests`; `metricsbench selfcheck` runs the same functions on a machine without XCTest.
//
// Each check returns (name, passed, detail). Nothing here reads a file.

struct Check { let name: String; let ok: Bool; let detail: String }

enum SelfCheck {
    static func all() -> [Check] {
        var c: [Check] = []
        c += wfdbHeader()
        c += wfdbSignals()
        c += wfdbAnnotations()
        c += sparsity()
        c += stats()
        c += respReference()
        c += rsaDirectionTracking()
        c += hrvWindows()
        return c
    }

    // MARK: WFDB

    static func wfdbHeader() -> [Check] {
        var out: [Check] = []
        // Verbatim shapes seen on PhysioNet: Fantasia f1y01 (format 16), f2y01 (212), slpdb slp01a (counter
        // frequency after the slash), BIDMC (gain with baseline and units).
        let f1 = "f1y01 2 250 1806271\r\nf1y01.dat 16 2000 16 0 1600 -1 0 ECG\r\nf1y01.dat 16 2000 16 0 1600 -1 0 RESP\r\n"
        if let h = try? WFDB.parseHeader(f1) {
            out.append(Check(name: "hea: fantasia f1y01", ok: h.record == "f1y01" && h.fs == 250 && h.nSamples == 1806271 && h.signals.count == 2 && h.signals[0].format == 16 && h.signals[0].gain == 2000 && h.signals[1].description == "RESP", detail: "\(h)"))
        } else { out.append(Check(name: "hea: fantasia f1y01", ok: false, detail: "parse threw")) }
        let slp = "slp01a 4 250/0.033333333(94) 1800000 23:07:00 19/1/1989\nslp01a.dat 212 -200/mV 12 0 -17 59911 0 ECG\nslp01a.dat 212 4.77778(-477)/mmHg 12 0 -248 19332 0 BP\nslp01a.dat 212 -6430/mV 12 0 252 49594 0 EEG (C4-A1)\nslp01a.dat 212 690/l 12 0 -180 912 0 Resp (sum)\n# 44 M 89 32-01-89\n"
        if let h = try? WFDB.parseHeader(slp) {
            let s1 = h.signals[1], s3 = h.signals[3]
            out.append(Check(name: "hea: slpdb slp01a", ok: h.fs == 250 && h.signals.count == 4 && h.signals[0].gain == -200 && s1.gain == 4.77778 && s1.baseline == -477 && s1.units == "mmHg" && s3.description == "Resp (sum)" && h.comments == ["44 M 89 32-01-89"], detail: "\(h)"))
        } else { out.append(Check(name: "hea: slpdb slp01a", ok: false, detail: "parse threw")) }
        let bid = "bidmc01 1 125 60001\nbidmc01.dat 16 65534(-32767)/pm 0 0 -9577 5854 0 RESP, \n"
        if let h = try? WFDB.parseHeader(bid) {
            out.append(Check(name: "hea: bidmc gain(baseline)/units", ok: h.signals.count == 1 && h.signals[0].gain == 65534 && h.signals[0].baseline == -32767 && h.signals[0].units == "pm", detail: "\(h.signals[0])"))
        } else { out.append(Check(name: "hea: bidmc gain(baseline)/units", ok: false, detail: "parse threw")) }
        let multi = "x/3 2 250 100\n"
        out.append(Check(name: "hea: multi-segment is rejected", ok: (try? WFDB.parseHeader(multi)) == nil, detail: ""))
        return out
    }

    static func wfdbSignals() -> [Check] {
        var out: [Check] = []
        // Format 16: little-endian two's complement.
        let d16 = Data([0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80, 0xFF, 0x7F])
        out.append(Check(name: "fmt16 decode", ok: WFDB.decode16(d16) == [1, -1, -32768, 32767], detail: "\(WFDB.decode16(d16))"))
        // Format 212: s1 = b0 | (b1&0x0F)<<8 ; s2 = b2 | (b1&0xF0)<<4, 12-bit two's complement.
        // 0x7FF (2047) and 0x800 (-2048): bytes FF 87 00 → s1 = 0xFF | 0x700 = 2047; s2 = 0x00 | 0x800 = -2048.
        let d212 = Data([0xFF, 0x87, 0x00, 0x34, 0x10, 0x56])
        out.append(Check(name: "fmt212 decode", ok: WFDB.decode212(d212) == [2047, -2048, 0x034, 0x156], detail: "\(WFDB.decode212(d212))"))
        // A trailing unpaired sample (2 bytes) is kept.
        out.append(Check(name: "fmt212 trailing sample", ok: WFDB.decode212(Data([0x01, 0x00, 0x02, 0x03, 0x00])) == [1, 2, 3], detail: ""))
        // Interleaving through readSignals: two signals in one format-16 file, gain 2 / baseline 1.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metricsbench-selfcheck-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = "t 2 100 3\nt.dat 16 2(1)/mV 16 0 0 0 0 A\nt.dat 16 1 16 0 0 0 0 B\n"
        try? hea.write(to: dir.appendingPathComponent("t.hea"), atomically: true, encoding: .utf8)
        try? Data([3, 0, 10, 0, 5, 0, 20, 0, 7, 0, 30, 0]).write(to: dir.appendingPathComponent("t.dat"))
        if let h = try? WFDB.readHeader(dir: dir, record: "t"), let s = try? WFDB.readSignals(dir: dir, header: h) {
            out.append(Check(name: "readSignals interleave + gain/baseline", ok: s[0] == [1, 2, 3] && s[1] == [10, 20, 30], detail: "\(s)"))
        } else { out.append(Check(name: "readSignals interleave + gain/baseline", ok: false, detail: "threw")) }
        return out
    }

    static func wfdbAnnotations() -> [Check] {
        var out: [Check] = []
        // The first six bytes of Fantasia f1y01.ecg as served by PhysioNet: 52 4 | 184 4 | 186 4 →
        // words 0x0434, 0x04B8, 0x04BA → NORMAL (code 1) at sample 52, then +184 = 236, then +186 = 422.
        let a = WFDB.parseAnnotations(Data([52, 4, 184, 4, 186, 4, 0, 0]))
        out.append(Check(name: "ann: fantasia head bytes", ok: a.map { $0.sample } == [52, 236, 422] && a.allSatisfy { $0.code == 1 }, detail: "\(a)"))
        // SKIP: 4 bytes, high word first, each little-endian. 7500 samples = 0x1D4C → hi 0x0000, lo 0x1D4C.
        // Sequence: NOTE(22) at +100 ; SKIP 7500 ; NOTE at +100 → samples 100, 7700. Aux "W" (odd length,
        // padded) attaches to the first, "2 H" to the second.
        var bytes: [UInt8] = []
        func word(_ code: Int, _ inc: Int) { let w = (code << 10) | inc; bytes += [UInt8(w & 0xFF), UInt8(w >> 8)] }
        word(22, 100); word(63, 1); bytes += [UInt8(ascii: "W"), 0]
        word(59, 0); bytes += [0x00, 0x00, 0x4C, 0x1D]
        word(22, 100); word(63, 3); bytes += Array("2 H".utf8) + [0]
        word(0, 0)
        let b = WFDB.parseAnnotations(Data(bytes))
        out.append(Check(name: "ann: SKIP + AUX", ok: b.count == 2 && b[0].sample == 100 && b[0].aux == "W" && b[1].sample == 7700 && b[1].aux == "2 H", detail: "\(b)"))
        // Negative SKIP (high word 0xFFFF): −1 → the next annotation lands one sample earlier.
        bytes = []; word(1, 10); word(59, 0); bytes += [0xFF, 0xFF, 0xFF, 0xFF]; word(1, 5); word(0, 0)
        let c = WFDB.parseAnnotations(Data(bytes))
        out.append(Check(name: "ann: negative SKIP", ok: c.map { $0.sample } == [10, 14], detail: "\(c)"))
        // NUM / CHN persist; SUB applies once.
        bytes = []; word(1, 1); word(60, 3); word(62, 2); word(61, 9); word(1, 1); word(0, 0)
        let d = WFDB.parseAnnotations(Data(bytes))
        out.append(Check(name: "ann: NUM/CHN persist, SUB once", ok: d.count == 2 && d[0].num == 3 && d[0].chan == 2 && d[0].subtype == 9 && d[1].num == 3 && d[1].chan == 2 && d[1].subtype == 0, detail: "\(d)"))
        return out
    }

    // MARK: sparsity

    static func sparsity() -> [Check] {
        var out: [Check] = []
        // 20 minutes of 0.4 s beats (150 bpm) so every second holds 2–3 beats; a cap of 2 must bite.
        var times: [Double] = []
        var t = 0.0
        while t < 1200 { times.append(t); t += 0.4 }
        let rec = BeatRecord(dataset: "syn", name: "syn", group: "syn", fs: 250, beatTimesS: times,
                             beatIsNormal: times.indices.map { $0 != 500 }, respiration: nil, stages: [])
        let dense = Sparsity.denseRows(rec, tsOffset: 1000)
        let expectedRows = times.count - 1 - 2   // one non-normal beat removes the two intervals it touches
        out.append(Check(name: "dense rows: NN only, whole-second ts", ok: dense.count == expectedRows && dense.allSatisfy { $0.rrMs == 400 } && dense.first!.ts == 1000 && dense.map { $0.ts } == dense.map { $0.ts }.sorted(), detail: "\(dense.count) vs \(expectedRows)"))
        var reg = Whoop5Regime(); reg.maxWordsPerSecond = 2; reg.holeFraction = 0
        let capped = Sparsity.apply(reg, to: dense)
        let perSec = Dictionary(grouping: capped.rows, by: { $0.ts }).values.map { $0.count }.max() ?? 0
        out.append(Check(name: "cap words per second", ok: perSec == 2 && capped.fillerCount == 0 && capped.rows.count < dense.count, detail: "max/s=\(perSec) rows=\(capped.rows.count)"))
        var holes = Whoop5Regime(); holes.holeFraction = 0.3; holes.holeMinS = 5; holes.holeMaxS = 20; holes.fillerSeconds = 2; holes.seed = 42
        let h1 = Sparsity.apply(holes, to: dense), h2 = Sparsity.apply(holes, to: dense)
        let removed = 1 - Double(h1.clean.count) / Double(Sparsity.apply(Whoop5Regime(), to: dense).rows.count)
        out.append(Check(name: "holes: deterministic, near target fraction, fillers flagged", ok: h1.rows.map { $0.ts } == h2.rows.map { $0.ts } && removed > 0.15 && removed < 0.45 && h1.fillerCount > 0 && h1.rows.filter { $0.rrMs == 500 }.count == h1.fillerCount && h1.clean.allSatisfy { $0.rrMs != 500 }, detail: String(format: "removed %.2f fillers %d", removed, h1.fillerCount)))
        let sorted = h1.rows.map { $0.ts } == h1.rows.map { $0.ts }.sorted()
        out.append(Check(name: "holes: output stays ts-sorted", ok: sorted, detail: ""))
        let del = Sparsity.deleteBeats(fraction: 0.2, from: dense, seed: 3)
        let frac = 1 - Double(del.count) / Double(dense.count)
        out.append(Check(name: "deleteBeats near fraction", ok: frac > 0.15 && frac < 0.25, detail: String(format: "%.3f", frac)))
        let sh = Sparsity.shuffleValues(dense, seed: 5)
        out.append(Check(name: "shuffleValues keeps ts and multiset", ok: sh.map { $0.ts } == dense.map { $0.ts } && sh.map { $0.rrMs }.sorted() == dense.map { $0.rrMs }.sorted(), detail: ""))
        return out
    }

    // MARK: stats

    static func stats() -> [Check] {
        var out: [Check] = []
        out.append(Check(name: "quantile linear", ok: Stats.quantile([1, 2, 3, 4], 0.5) == 2.5 && Stats.quantile([3, 1, 2], 0.5) == 2 && Stats.quantile([1, 2, 3, 4], 0.25) == 1.75, detail: ""))
        out.append(Check(name: "sd sample", ok: abs(Stats.sd([2, 4, 4, 4, 5, 5, 7, 9]) - 2.138089935) < 1e-6, detail: "\(Stats.sd([2, 4, 4, 4, 5, 5, 7, 9]))"))
        let a = Stats.agreement(estimate: [11, 9, 12, 8], reference: [10, 10, 10, 10], tolerance: 1)
        let okA = a.n == 4 && abs(a.bias - 0) < 1e-12 && abs(a.mae - 1.5) < 1e-12 && abs(a.mape - 0.15) < 1e-12 && a.within == 0.5
        out.append(Check(name: "agreement bias/MAE/MAPE/within", ok: okA, detail: a.description))
        out.append(Check(name: "ccc perfect = 1", ok: abs(Stats.ccc([1, 2, 3, 4], [1, 2, 3, 4]) - 1) < 1e-12, detail: ""))
        out.append(Check(name: "ccc penalises offset", ok: Stats.ccc([1, 2, 3, 4], [2, 3, 4, 5]) < Stats.pearson([1, 2, 3, 4], [2, 3, 4, 5]), detail: ""))
        out.append(Check(name: "agreement drops NaN pairs", ok: Stats.agreement(estimate: [1, .nan, 3], reference: [1, 2, .nan], tolerance: 1).n == 1, detail: ""))
        return out
    }

    // MARK: respiration reference

    static func respReference() -> [Check] {
        var out: [Check] = []
        let fs = 250.0
        for bpm in [8.0, 12.0, 18.0, 24.0] {
            var x: [Double] = []
            let n = Int(300 * fs)
            for i in 0..<n {
                let t = Double(i) / fs
                // breathing + slow drift + cardiac ripple at 1.1 Hz
                x.append(sin(2 * .pi * bpm / 60 * t) + 0.5 * sin(2 * .pi * 0.01 * t) + 0.15 * sin(2 * .pi * 1.1 * t))
            }
            let r = RespBench.referenceRate(x[...], fs: fs)
            out.append(Check(name: "resp reference recovers \(Int(bpm)) bpm", ok: r.rate != nil && abs(r.rate! - bpm) < 0.6 && abs(r.spectral - bpm) < 0.6, detail: "count \(Stats.fmt(r.count)) spectral \(Stats.fmt(r.spectral))"))
        }
        let flat = [Double](repeating: 0.3, count: Int(300 * fs))
        out.append(Check(name: "resp reference refuses a flat window", ok: RespBench.referenceRate(flat[...], fs: fs).rate == nil, detail: ""))
        return out
    }

    // MARK: the shipped estimator on synthetic RSA

    static func rsaDirectionTracking() -> [Check] {
        var out: [Check] = []
        // The shipped estimator must track the injected rate at a physiological RSA amplitude (within 1.5
        // breaths/min at 30 ms; the strap's whole-second ts and 8 ms jitter are in the input).
        for r in [8.0, 11, 15, 20] {
            let e = SyntheticRSA.estimate(breathsPerMin: r, amplitudeMs: 30)
            out.append(Check(name: "shipped respRateFromRR tracks \(Int(r)) bpm @30 ms", ok: !e.isNaN && abs(e - r) <= 1.5, detail: "got \(Stats.fmt(e))"))
        }
        // Upper band, documented: the picker works on a 4 Hz grid with `rsaMinPeakDistanceS` = 2.5 s, so above
        // ~20 breaths/min the interval snaps between grid cells (22 bpm reads 20.0 here). Pinned as baseline.
        let upper = SyntheticRSA.estimate(breathsPerMin: 22, amplitudeMs: 30)
        out.append(Check(name: "baseline: 22 bpm resolves coarsely (within 3 bpm)", ok: !upper.isNaN && abs(upper - 22) <= 3, detail: "got \(Stats.fmt(upper))"))
        // Band edge, documented: `rsaMinPeakDistanceS` is 2.5 s, so a 24 breaths/min tachogram (2.5 s period)
        // has its peaks merged and the estimator reports about HALF the rate. Pinned as baseline so the
        // report's 24-column is read as an edge case and not as noise.
        let edge = SyntheticRSA.estimate(breathsPerMin: 24, amplitudeMs: 30)
        out.append(Check(name: "baseline: 24 bpm sits on the peak-distance edge (reports ≈ half or refuses)", ok: edge.isNaN || abs(edge - 12) <= 1.5 || abs(edge - 24) <= 1.5, detail: "got \(Stats.fmt(edge))"))
        // Documented behaviour, NOT a target: with the modulation removed the shipped estimator still emits
        // a number (the 13.33 floor, docs/research/04 §3). This check pins the baseline so the fix in item
        // 1.2 is measurable; it is expected to be inverted when 1.2 lands.
        let zero = SyntheticRSA.estimate(breathsPerMin: 15, amplitudeMs: 0)
        out.append(Check(name: "baseline: zero-amplitude input currently emits a value (known false emit)", ok: !zero.isNaN, detail: "got \(Stats.fmt(zero)) — expected to flip to refuse after ROADMAP 1.2"))
        return out
    }

    // MARK: HRV windows

    static func hrvWindows() -> [Check] {
        var out: [Check] = []
        // 20 minutes of RSA-modulated beats at 60 bpm: four 5-min windows, each with ≥ minBeats clean beats.
        let rows = SyntheticRSA.rows(breathsPerMin: 12, amplitudeMs: 40, meanRRMs: 1000, minutes: 20)
        let w = SleepStager.sessionHrvWindows(start: rows.first!.ts, end: rows.last!.ts, rr: rows, stages: [])
        out.append(Check(name: "sessionHrvWindows: 4 windows, all scored", ok: w.count == 4 && w.allSatisfy { $0.rmssd != nil && $0.cleanBeats >= HRVAnalyzer.minBeats }, detail: "\(w.map { $0.cleanBeats })"))
        // Whole-second stamping against a 0.5 s tolerance: a pair fails whenever the floor() of two beats
        // about 1 s apart lands them 0 or 2 seconds apart, which happens with probability ≈ |1 − RR| per
        // pair on a PERFECT stream (≈ 4–8 % here at 1000 ± 40 ms). That is a property of the shipped
        // definition (`HRVAnalyzer.beatAccurateFraction`), not of this harness, and it is why the bench also
        // reports window COVERAGE (Σ RR vs wall span), where rounding does not accumulate but a lost beat does.
        let vp = HRVBench.validPairs(rows[...])
        out.append(Check(name: "validPairs on a perfect whole-second stream loses only rounding pairs", ok: vp >= Int(0.85 * Double(rows.count)) && vp <= rows.count - 1, detail: "\(vp) of \(rows.count)"))
        let cov = HRVBench.coverage(rows[...])
        out.append(Check(name: "coverage ≈ 1 on a perfect stream, < 1 with a third of beats gone", ok: abs(cov - 1) < 0.03 && HRVBench.coverage(rows.enumerated().compactMap { $0.offset % 3 == 2 ? nil : $0.element }[...]) < 0.75, detail: String(format: "%.3f", cov)))
        // Banked timestamps (all beats stamped on one second) → almost no valid pairs.
        let banked = rows.map { RRInterval(ts: rows[0].ts, rrMs: $0.rrMs) }
        out.append(Check(name: "validPairs collapses on banked timestamps", ok: HRVBench.validPairs(banked[...]) < rows.count / 10, detail: "\(HRVBench.validPairs(banked[...]))"))
        // Removing every third beat drops the valid-pair count by about a third of the remaining pairs.
        let thinned = rows.enumerated().compactMap { $0.offset % 3 == 2 ? nil : $0.element }
        let vpThin = HRVBench.validPairs(thinned[...])
        out.append(Check(name: "validPairs sees deletions", ok: Double(vpThin) < 0.6 * Double(thinned.count), detail: "\(vpThin) of \(thinned.count)"))
        return out
    }
}

import Foundation
import WhoopProtocol

// Sparsity — turn reference beat times into the R-R stream a WHOOP 5.0 delivers, so the shipped
// estimators are scored on the input they really get rather than on a dense ECG tachogram.
//
// The regime, from docs/WHOOP5_DEEP_DATA.md and docs/RR-OPTIMIZATION.md:
//   • every beat is stamped with the WHOLE SECOND it was reported in (the R18 record's `ts`), so
//     same-second beats share a timestamp and a 0.8 s interval can sit on a 0 s or 1 s wall-clock gap;
//   • a record carries at most four R-R words, so a second with five beats loses one;
//   • when the optical beat track is lost the firmware emits 500 ms FILLER words, which the store flags
//     `tsSuspect = 1` (migration v47) and the read policy removes before analytics;
//   • the stream has holes: stretches of seconds with no R-R at all (v26 bursts without beats, motion).
//
// Everything is deterministic from `seed` (SplitMix64), so a table can be regenerated exactly.

struct Whoop5Regime: CustomStringConvertible {
    var maxWordsPerSecond = 4
    /// Target fraction of the span's seconds removed as holes (0 = none).
    var holeFraction = 0.0
    var holeMinS = 5
    var holeMaxS = 60
    /// Seconds at the start of every hole that carry 500 ms filler words (flagged suspect); 0 = none.
    var fillerSeconds = 2
    var fillerMs = 500
    var seed: UInt64 = 0x5EED_0001

    var description: String {
        holeFraction == 0 ? "cap\(maxWordsPerSecond)" : "cap\(maxWordsPerSecond)+holes\(Int((holeFraction * 100).rounded()))%\(fillerSeconds > 0 ? "+fillers" : "")"
    }
}

struct SparseStream {
    /// What the store would hold, in emission order, ts-sorted.
    let rows: [RRInterval]
    /// Parallel to `rows`: true for a filler word (`tsSuspect = 1`). The shipped read policy drops these
    /// before any analytics sees them; `clean` is that view.
    let suspect: [Bool]
    var clean: [RRInterval] { zip(rows, suspect).compactMap { $1 ? nil : $0 } }
    var fillerCount: Int { suspect.filter { $0 }.count }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextInt(_ lo: Int, _ hi: Int) -> Int { lo + Int(nextDouble() * Double(hi - lo + 1)) }
}

enum Sparsity {
    /// The dense reference as R-R rows: one row per NN interval (both beats annotated NORMAL and the
    /// interval inside the 300–2000 ms physiological range), `rrMs` rounded to the millisecond, `ts` the
    /// whole second of the interval's closing beat plus `tsOffset`. A non-normal beat leaves no row, so the
    /// store-level signature of a dropped beat (a wall-clock jump the R-R does not account for) is present
    /// exactly as it would be on a strap.
    static func denseRows(_ r: BeatRecord, tsOffset: Int, channel: RRSourceChannel? = .whoop5Historical) -> [RRInterval] {
        var out: [RRInterval] = []
        out.reserveCapacity(r.beatTimesS.count)
        for i in 1..<max(1, r.beatTimesS.count) {
            guard r.beatIsNormal[i], r.beatIsNormal[i - 1] else { continue }
            let ms = Int(((r.beatTimesS[i] - r.beatTimesS[i - 1]) * 1000).rounded())
            guard ms >= 300, ms <= 2000 else { continue }
            out.append(RRInterval(ts: tsOffset + Int(r.beatTimesS[i].rounded(.down)), rrMs: ms, srcChannel: channel))
        }
        return out
    }

    /// Apply the regime to ts-sorted rows.
    static func apply(_ regime: Whoop5Regime, to rows: [RRInterval]) -> SparseStream {
        guard let first = rows.first, let last = rows.last else { return SparseStream(rows: [], suspect: []) }
        var rng = SplitMix64(seed: regime.seed)
        // 1. Holes: a set of seconds to drop, chosen so the expected removed fraction is holeFraction.
        var holeStart = Set<Int>()
        var inHole = Set<Int>()
        if regime.holeFraction > 0 {
            let meanLen = Double(regime.holeMinS + regime.holeMaxS) / 2
            let p = regime.holeFraction / meanLen
            var t = first.ts
            while t <= last.ts {
                if rng.nextDouble() < p {
                    let len = rng.nextInt(regime.holeMinS, regime.holeMaxS)
                    holeStart.insert(t)
                    for s in t..<(t + len) { inHole.insert(s) }
                    t += len
                } else {
                    t += 1
                }
            }
        }
        // 2. Per-second word cap, in emission order.
        var out: [RRInterval] = []
        var suspect: [Bool] = []
        var perSecond: [Int: Int] = [:]
        var fillerDone = Set<Int>()
        for row in rows {
            if inHole.contains(row.ts) {
                // The first fillerSeconds seconds of a hole carry two 500 ms filler words each.
                if regime.fillerSeconds > 0, let start = holeStartFor(row.ts, holeStart, inHole) {
                    for s in start..<(start + regime.fillerSeconds) where !fillerDone.contains(s) && inHole.contains(s) {
                        fillerDone.insert(s)
                        for _ in 0..<2 {
                            out.append(RRInterval(ts: s, rrMs: regime.fillerMs, srcChannel: row.srcChannel))
                            suspect.append(true)
                        }
                    }
                }
                continue
            }
            let n = perSecond[row.ts, default: 0]
            if n >= regime.maxWordsPerSecond { continue }
            perSecond[row.ts] = n + 1
            out.append(row)
            suspect.append(false)
        }
        // Keep ts order stable after filler insertion.
        let order = out.indices.sorted { (out[$0].ts, $0) < (out[$1].ts, $1) }
        return SparseStream(rows: order.map { out[$0] }, suspect: order.map { suspect[$0] })
    }

    private static func holeStartFor(_ s: Int, _ starts: Set<Int>, _ inHole: Set<Int>) -> Int? {
        var t = s
        while inHole.contains(t) { if starts.contains(t) { return t }; t -= 1 }
        return nil
    }

    /// Remove a fraction of rows uniformly at random (the Kim 2007 / Morelli 2019 "missing beats" protocol).
    /// The surviving rows keep their timestamps, so the deletion is visible as a wall-clock jump.
    static func deleteBeats(fraction: Double, from rows: [RRInterval], seed: UInt64) -> [RRInterval] {
        var rng = SplitMix64(seed: seed)
        return rows.filter { _ in rng.nextDouble() >= fraction }
    }

    /// Shuffle the R-R VALUES while keeping every timestamp in place: the same beats, the same wall clock,
    /// no physiology. Any estimate that survives this is reading its own structure, not the signal.
    static func shuffleValues(_ rows: [RRInterval], seed: UInt64) -> [RRInterval] {
        var rng = SplitMix64(seed: seed)
        var vals = rows.map { $0.rrMs }
        if vals.count > 1 {
            for i in stride(from: vals.count - 1, to: 0, by: -1) {
                let j = rng.nextInt(0, i)
                vals.swapAt(i, j)
            }
        }
        return zip(rows, vals).map { RRInterval(ts: $0.ts, rrMs: $1, srcChannel: $0.srcChannel) }
    }
}

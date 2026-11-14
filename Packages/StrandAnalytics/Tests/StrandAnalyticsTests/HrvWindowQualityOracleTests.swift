import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The per-window quality step of `SleepStager.sessionHrvWindows` (wall-clock pair skip, valid pairs,
/// in-range coverage, window tier) and the night fold (`hrvNightQuality`), pinned as an ORACLE: a fixed
/// spread of synthetic 20-minute streams, each printed as one line per window plus one night line, compared
/// against the literal below.
///
/// The literal is this test's own stdout from the Swift reference implementation, pasted verbatim, and the
/// Kotlin twin (`HrvWindowQualityOracleTest`) asserts the SAME literal over the same cases — which is how
/// the parity contract in AGENTS.md is verified for analytics: by oracle, not by eye. If a deliberate change
/// moves a value, regenerate here first and paste the new literal into both tests.
///
/// Numbers are printed as integers in thousandths so both platforms round the same way.
final class HrvWindowQualityOracleTests: XCTestCase {

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 20 minutes of beats around `meanMs` with a 7-beat modulation and ±10 ms jitter, each stamped with the
    /// whole second it falls in (what a strap stamps).
    static func stream(meanMs: Int, seed: UInt64, start: Int = 1_800_000_000) -> [RRInterval] {
        var g = SplitMix(seed: seed)
        var out: [RRInterval] = []
        var beatMs = start * 1000
        var i = 0
        while beatMs < (start + 1200) * 1000 {
            let mod = Int((60.0 * sin(2.0 * Double.pi * Double(i) / 7.0)).rounded())
            let ms = meanMs + mod + Int(g.next() % 21) - 10
            beatMs += ms
            out.append(RRInterval(ts: beatMs / 1000, rrMs: ms))
            i += 1
        }
        return out
    }

    static func cases() -> [(String, [RRInterval])] {
        let base = stream(meanMs: 1000, seed: 11)
        let slow = stream(meanMs: 1250, seed: 12)
        let fast = stream(meanMs: 650, seed: 13)
        var g = SplitMix(seed: 99)
        let start = base[0].ts
        return [
            ("dense60", base),
            ("dense48", slow),
            ("dense92", fast),
            ("everyOther", base.enumerated().compactMap { $0.offset % 2 == 1 ? nil : $0.element }),
            ("everyFourth", base.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }),
            ("random10", base.filter { _ in g.next() % 100 >= 10 }),
            ("hole60s", base.filter { ($0.ts - start) % 300 < 120 || ($0.ts - start) % 300 >= 180 }),
            ("banked", base.map { RRInterval(ts: start, rrMs: $0.rrMs) }),
            ("ectopic", base.enumerated().map { $0.offset % 15 == 0 ? RRInterval(ts: $0.element.ts, rrMs: $0.element.rrMs + 600) : $0.element }),
            ("garbage", base.enumerated().map { $0.offset % 20 == 0 ? RRInterval(ts: $0.element.ts, rrMs: 2500) : $0.element }),
            ("tsEqualsIndex900", (0..<1200).map { RRInterval(ts: start + $0, rrMs: 900) }),
            ("tsTwoPerBeat1200", (0..<600).map { RRInterval(ts: start + 2 * $0, rrMs: 1200) }),
        ]
    }

    static func render() -> [String] {
        var lines: [String] = []
        func k(_ x: Double) -> Int { Int((x * 1000).rounded()) }
        for (name, rr) in cases() {
            let start = 1_800_000_000, end = start + 1200
            let w = SleepStager.sessionHrvWindows(start: start, end: end, rr: rr, stages: [])
            for (i, x) in w.enumerated() {
                lines.append("\(name) w\(i) in=\(x.inputBeats) clean=\(x.cleanBeats) pairs=\(x.validPairs) cov=\(k(x.coverage)) tier=\(x.tier.rawValue) rmssd=\(x.rmssd.map { String(k($0)) } ?? "nil")")
            }
            let q = SleepStager.hrvNightQuality(w)
            lines.append("\(name) night tier=\(q.tier.rawValue) full=\(q.fullWindows) limited=\(q.limitedWindows) refused=\(q.refusedWindows) pairs=\(q.validPairs) input=\(q.inputBeats) avg=\(SleepStager.sessionAvgHRV(start: start, end: end, rr: rr).map { String(k($0)) } ?? "nil")")
        }
        return lines
    }

    /// Swift stdout, pasted verbatim. Shared with Kotlin `HrvWindowQualityOracleTest.EXPECTED`.
    static let expected: [String] = [
        "dense60 w0 in=299 clean=299 pairs=297 cov=1001 tier=full rmssd=37834",
        "dense60 w1 in=300 clean=300 pairs=299 cov=1004 tier=full rmssd=38016",
        "dense60 w2 in=300 clean=300 pairs=299 cov=1004 tier=full rmssd=37395",
        "dense60 w3 in=301 clean=301 pairs=300 cov=1003 tier=full rmssd=38160",
        "dense60 night tier=limited full=4 limited=0 refused=0 pairs=1195 input=1200 avg=37851",
        "dense48 w0 in=239 clean=239 pairs=179 cov=1006 tier=full rmssd=38464",
        "dense48 w1 in=240 clean=240 pairs=179 cov=1004 tier=full rmssd=38044",
        "dense48 w2 in=240 clean=240 pairs=179 cov=1003 tier=full rmssd=37411",
        "dense48 w3 in=241 clean=241 pairs=180 cov=1004 tier=full rmssd=36874",
        "dense48 night tier=limited full=4 limited=0 refused=0 pairs=717 input=960 avg=37698",
        "dense92 w0 in=461 clean=461 pairs=460 cov=1003 tier=full rmssd=37643",
        "dense92 w1 in=461 clean=461 pairs=460 cov=1003 tier=full rmssd=37791",
        "dense92 w2 in=462 clean=462 pairs=461 cov=1004 tier=full rmssd=37589",
        "dense92 w3 in=462 clean=462 pairs=461 cov=1001 tier=full rmssd=37847",
        "dense92 night tier=limited full=4 limited=0 refused=0 pairs=1842 input=1846 avg=37717",
        "everyOther w0 in=150 clean=150 pairs=0 cov=502 tier=refuse rmssd=nil",
        "everyOther w1 in=150 clean=150 pairs=0 cov=504 tier=refuse rmssd=nil",
        "everyOther w2 in=150 clean=150 pairs=0 cov=504 tier=refuse rmssd=nil",
        "everyOther w3 in=150 clean=150 pairs=0 cov=503 tier=refuse rmssd=nil",
        "everyOther night tier=refuse full=0 limited=0 refused=4 pairs=0 input=600 avg=nil",
        "everyFourth w0 in=225 clean=225 pairs=149 cov=753 tier=limited rmssd=37711",
        "everyFourth w1 in=225 clean=225 pairs=150 cov=755 tier=limited rmssd=37921",
        "everyFourth w2 in=225 clean=225 pairs=150 cov=756 tier=limited rmssd=37113",
        "everyFourth w3 in=225 clean=225 pairs=150 cov=755 tier=limited rmssd=37899",
        "everyFourth night tier=limited full=0 limited=4 refused=0 pairs=599 input=900 avg=37661",
        "random10 w0 in=263 clean=263 pairs=232 cov=880 tier=limited rmssd=37355",
        "random10 w1 in=274 clean=274 pairs=247 cov=917 tier=full rmssd=37958",
        "random10 w2 in=260 clean=260 pairs=226 cov=875 tier=limited rmssd=38485",
        "random10 w3 in=266 clean=266 pairs=235 cov=886 tier=limited rmssd=38757",
        "random10 night tier=limited full=1 limited=3 refused=0 pairs=940 input=1063 avg=38139",
        "hole60s w0 in=239 clean=239 pairs=236 cov=799 tier=limited rmssd=37821",
        "hole60s w1 in=240 clean=240 pairs=238 cov=803 tier=limited rmssd=38163",
        "hole60s w2 in=240 clean=240 pairs=238 cov=803 tier=limited rmssd=37194",
        "hole60s w3 in=241 clean=241 pairs=239 cov=804 tier=limited rmssd=37812",
        "hole60s night tier=limited full=0 limited=4 refused=0 pairs=951 input=960 avg=37747",
        "banked w0 in=1200 clean=1200 pairs=1199 cov=0 tier=limited rmssd=37876",
        "banked w1 in=0 clean=0 pairs=0 cov=0 tier=refuse rmssd=nil",
        "banked w2 in=0 clean=0 pairs=0 cov=0 tier=refuse rmssd=nil",
        "banked w3 in=0 clean=0 pairs=0 cov=0 tier=refuse rmssd=nil",
        "banked night tier=refuse full=0 limited=1 refused=3 pairs=1199 input=1200 avg=nil",
        "ectopic w0 in=299 clean=279 pairs=259 cov=1041 tier=full rmssd=38016",
        "ectopic w1 in=300 clean=279 pairs=259 cov=1044 tier=full rmssd=37863",
        "ectopic w2 in=300 clean=279 pairs=259 cov=1044 tier=full rmssd=37309",
        "ectopic w3 in=301 clean=281 pairs=260 cov=1043 tier=full rmssd=38120",
        "ectopic night tier=limited full=4 limited=0 refused=0 pairs=1037 input=1200 avg=37827",
        "garbage w0 in=299 clean=284 pairs=269 cov=957 tier=full rmssd=37866",
        "garbage w1 in=300 clean=285 pairs=269 cov=954 tier=full rmssd=37840",
        "garbage w2 in=300 clean=285 pairs=269 cov=954 tier=full rmssd=37362",
        "garbage w3 in=301 clean=286 pairs=270 cov=953 tier=full rmssd=37986",
        "garbage night tier=limited full=4 limited=0 refused=0 pairs=1077 input=1200 avg=37763",
        "tsEqualsIndex900 w0 in=300 clean=300 pairs=299 cov=903 tier=full rmssd=0",
        "tsEqualsIndex900 w1 in=300 clean=300 pairs=299 cov=903 tier=full rmssd=0",
        "tsEqualsIndex900 w2 in=300 clean=300 pairs=299 cov=903 tier=full rmssd=0",
        "tsEqualsIndex900 w3 in=300 clean=300 pairs=299 cov=903 tier=full rmssd=0",
        "tsEqualsIndex900 night tier=limited full=4 limited=0 refused=0 pairs=1196 input=1200 avg=0",
        "tsTwoPerBeat1200 w0 in=150 clean=150 pairs=0 cov=604 tier=refuse rmssd=nil",
        "tsTwoPerBeat1200 w1 in=150 clean=150 pairs=0 cov=604 tier=refuse rmssd=nil",
        "tsTwoPerBeat1200 w2 in=150 clean=150 pairs=0 cov=604 tier=refuse rmssd=nil",
        "tsTwoPerBeat1200 w3 in=150 clean=150 pairs=0 cov=604 tier=refuse rmssd=nil",
        "tsTwoPerBeat1200 night tier=refuse full=0 limited=0 refused=4 pairs=0 input=600 avg=nil",
    ]

    func testWindowQualityMatchesTheOracle() {
        let actual = Self.render()
        if actual != Self.expected {
            XCTFail("oracle mismatch; actual output follows:\n" + actual.joined(separator: "\n"))
        }
    }
}

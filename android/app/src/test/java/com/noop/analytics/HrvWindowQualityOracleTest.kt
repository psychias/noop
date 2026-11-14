package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The per-window quality step of [SleepStager.sessionHrvWindows] (wall-clock pair skip, valid pairs, in-range
 * coverage, window tier) and the night fold ([SleepStager.hrvNightQuality]), pinned as an ORACLE: a fixed
 * spread of synthetic 20-minute streams, each printed as one line per window plus one night line, compared
 * against the literal below.
 *
 * [EXPECTED] is the Swift reference implementation's stdout (`HrvWindowQualityOracleTests`), pasted verbatim
 * — the parity contract in AGENTS.md verified by oracle, not by eye. If a deliberate change moves a value,
 * regenerate on the Swift side first and paste the new literal into both tests.
 *
 * Numbers are printed as integers in thousandths so both platforms round the same way.
 */
class HrvWindowQualityOracleTest {

    private class SplitMix(seed: Long) {
        private var state = seed * -0x61c8_8646_80b5_83ebL
        fun next(): Long {
            state += -0x61c8_8646_80b5_83ebL
            var z = state
            z = (z xor (z ushr 30)) * -0x40a7_b892_e31b_1a47L
            z = (z xor (z ushr 27)) * -0x6b2f_b644_ecce_ee15L
            return z xor (z ushr 31)
        }
    }

    private fun rr(ts: Long, ms: Int) = RrInterval(deviceId = "d", ts = ts, rrMs = ms)

    /** 20 minutes of beats around [meanMs] with a 7-beat modulation and ±10 ms jitter, each stamped with the
     *  whole second it falls in (what a strap stamps). Twin of the Swift `stream`. */
    private fun stream(meanMs: Int, seed: Long, start: Long = 1_800_000_000L): List<RrInterval> {
        val g = SplitMix(seed)
        val out = ArrayList<RrInterval>()
        var beatMs = start * 1000
        var i = 0
        while (beatMs < (start + 1200) * 1000) {
            val mod = (60.0 * sin(2.0 * PI * i.toDouble() / 7.0)).roundToInt()
            val ms = meanMs + mod + java.lang.Long.remainderUnsigned(g.next(), 21L).toInt() - 10
            beatMs += ms
            out.add(rr(beatMs / 1000, ms))
            i++
        }
        return out
    }

    private fun cases(): List<Pair<String, List<RrInterval>>> {
        val base = stream(1000, 11)
        val slow = stream(1250, 12)
        val fast = stream(650, 13)
        val g = SplitMix(99)
        val start = base[0].ts
        return listOf(
            "dense60" to base,
            "dense48" to slow,
            "dense92" to fast,
            "everyOther" to base.filterIndexed { idx, _ -> idx % 2 != 1 },
            "everyFourth" to base.filterIndexed { idx, _ -> idx % 4 != 3 },
            "random10" to base.filter { java.lang.Long.remainderUnsigned(g.next(), 100L) >= 10 },
            "hole60s" to base.filter { (it.ts - start) % 300 < 120 || (it.ts - start) % 300 >= 180 },
            "banked" to base.map { rr(start, it.rrMs) },
            "ectopic" to base.mapIndexed { idx, b -> if (idx % 15 == 0) rr(b.ts, b.rrMs + 600) else b },
            "garbage" to base.mapIndexed { idx, b -> if (idx % 20 == 0) rr(b.ts, 2500) else b },
            "tsEqualsIndex900" to (0 until 1200).map { rr(start + it, 900) },
            "tsTwoPerBeat1200" to (0 until 600).map { rr(start + 2L * it, 1200) },
        )
    }

    private fun k(x: Double): Long = Math.round(x * 1000)

    private fun render(): List<String> {
        val lines = ArrayList<String>()
        for ((name, rr) in cases()) {
            val start = 1_800_000_000L
            val end = start + 1200
            val w = SleepStager.sessionHrvWindows(start, end, rr, emptyList())
            for ((i, x) in w.withIndex()) {
                lines.add(
                    "$name w$i in=${x.inputBeats} clean=${x.cleanBeats} pairs=${x.validPairs} cov=${k(x.coverage)} " +
                        "tier=${x.tier.raw} rmssd=${x.rmssd?.let { k(it).toString() } ?: "nil"}",
                )
            }
            val q = SleepStager.hrvNightQuality(w)
            lines.add(
                "$name night tier=${q.tier.raw} full=${q.fullWindows} limited=${q.limitedWindows} refused=${q.refusedWindows} " +
                    "pairs=${q.validPairs} input=${q.inputBeats} avg=${SleepStager.sessionAvgHRV(start, end, rr)?.let { k(it).toString() } ?: "nil"}",
            )
        }
        return lines
    }

    /** Swift stdout, pasted verbatim. Shared with Swift `HrvWindowQualityOracleTests.expected`. */
    private val EXPECTED = listOf(
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
    )

    @Test fun windowQualityMatchesTheOracle() {
        val actual = render()
        assertEquals("oracle mismatch; actual output follows:\n" + actual.joinToString("\n"), EXPECTED, actual)
    }
}

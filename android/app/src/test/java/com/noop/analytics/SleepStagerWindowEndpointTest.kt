package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Tests the closed-window binning of the SHIPPED per-session HR/HRV path,
 * SleepStager.sessionRestingHR and SleepStager.sessionHrvWindows.
 *
 * Both prefilter ts ∈ [start, end] but binned as [t, t+300) with a loop stopping at `end`, so a
 * sample sitting exactly on an ALIGNED end was admitted and then belonged to no window. The final
 * bin now closes on `end` — the same rule RecoveryScorer already carries. Each case is paired with
 * a non-aligned twin that was always correct.
 *
 * Parity: the expected values are the verbatim stdout of a standalone Swift oracle built from the
 * fixed Swift binning (CLAUDE.md's byte-identical-by-oracle rule), not values read off this Kotlin
 * implementation. SleepStagerTests.swift pins the same scenarios on the Swift side.
 */
class SleepStagerWindowEndpointTest {

    private val dev = "test"

    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)

    private fun rr(ts: Long, rrMs: Int) = RrInterval(deviceId = dev, ts = ts, rrMs = rrMs)

    @Test
    fun alignedEndpointSampleReachesABin() {
        // Minimal case: start = 0, end = 300 (one window wide), five samples on the endpoint.
        // Already returned 60 before the fix, but only via the all-sample fallback.
        val samples = (0 until 5).map { hr(300L, 60) }
        assertEquals(
            "a sample exactly on an aligned end must belong to the final bin",
            60, SleepStager.sessionRestingHR(0L, 300L, samples)
        )
    }

    @Test
    fun nonAlignedEndpointSampleReachesABin() {
        // Paired non-aligned case: end = 450 falls mid-window, so the endpoint sample was always
        // inside the trailing partial bin. Same answer, before and after.
        val samples = (0 until 5).map { hr(450L, 60) }
        assertEquals(
            "a sample on a non-aligned end stays in the trailing partial bin",
            60, SleepStager.sessionRestingHR(0L, 450L, samples)
        )
    }

    @Test
    fun endpointSampleLandsInFinalBinOnly() {
        // Where the fallback cannot hide the dropped sample: a dense 70 bpm first bin plus five
        // endpoint beats at 40 makes the floor 40. Before the fix the shipped resting HR read 70.
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 70))
        for (i in 0 until 5) samples.add(hr(600L, 40))
        assertEquals(
            "the endpoint sample belongs to the final bin only",
            40, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun degenerateZeroLengthWindow() {
        // start == end: the single instant is one closed bin — the same number the all-sample
        // fallback produced before.
        val samples = (0 until 5).map { hr(1000L, 58) }
        assertEquals(58, SleepStager.sessionRestingHR(1000L, 1000L, samples))
    }

    @Test
    fun sessionRestingHrEndpointSweepMatchesSwiftOracle() {
        // `end` walks a whole window width and beyond in 25 s steps against a dense 70 bpm opening
        // bin plus five endpoint beats at 60. Verbatim Swift oracle stdout — the check that catches
        // drift the eye does not, including end = 300 where the single closed bin holds BOTH groups.
        val expected = listOf(
            62, 68, 69, 69, 70, 70, 70, 70, 70, 70, 70, 70, 70,
            60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60,
            60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60
        )
        var i = 0
        var endTs = 0L
        while (endTs <= 900L) {
            val samples = ArrayList<HrSample>()
            for (s in 0 until 300) samples.add(hr(s.toLong(), 70))
            for (s in 0 until 5) samples.add(hr(endTs, 60))
            assertEquals(
                "sessionRestingHR.end=$endTs", expected[i], SleepStager.sessionRestingHR(0L, endTs, samples)
            )
            i++
            endTs += 25L
        }
    }

    // MARK: - #1943: sessionRestingHR bin-population + plausibility gates

    @Test
    fun thinBinCannotWinTheFloor() {
        // 300 samples at 60 in the first bin (qualifies), one sample at 38 in the final bin (thin).
        // Before #1943 the floor was 38; now the thin bin is excluded and the floor is 60.
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 60))
        samples.add(hr(600L, 38))
        assertEquals(
            "a one-sample bin cannot win the floor under the #1943 gate",
            60, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun implausibleBinCannotWinTheFloor() {
        // 300 samples at 60 (qualifies), then 300 samples at 20 (well-populated but implausible).
        // Before #1943 the floor was 20; now the implausible bin is excluded and the floor is 60.
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 60))
        for (i in 300 until 600) samples.add(hr(i.toLong(), 20))
        assertEquals(
            "a sub-25 bpm bin cannot win the floor under the #1943 gate",
            60, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun allBinsGatedFallsBackToUngatedMin() {
        // Two bins, each with one sample: 40 and 50. Neither qualifies (both thin). The fallback
        // is the min of all bin means = 40, the same value the ungated path produced.
        val samples = listOf(hr(0L, 40), hr(300L, 50))
        assertEquals(
            "when no bin qualifies, the floor falls back to the ungated min",
            40, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun denseNightUnchangedByGate() {
        val samples = (0 until 1800).map { hr(it.toLong(), 60) }
        assertEquals(
            "a well-populated night is unchanged by the gate",
            60, SleepStager.sessionRestingHR(0L, 1800L, samples)
        )
    }

    @Test
    fun binSampleCountBoundary() {
        // First bin: 300 samples at 70 (qualifies). Final bin: 4 samples at 40 (below threshold).
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 70))
        for (i in 0 until 4) samples.add(hr(600L, 40))
        assertEquals(
            "a 4-sample bin is below the minBinSamples=5 threshold and cannot win",
            70, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun plausibilityBoundary() {
        // First bin: 300 samples at 60 (qualifies). Final bin: 300 samples at 24 (implausible).
        val samples = ArrayList<HrSample>()
        for (i in 0 until 300) samples.add(hr(i.toLong(), 60))
        for (i in 300 until 600) samples.add(hr(i.toLong(), 24))
        assertEquals(
            "a 24-bpm mean is below the minPlausibleBpm=25 threshold and cannot win",
            60, SleepStager.sessionRestingHR(0L, 600L, samples)
        )
    }

    @Test
    fun alignedEndpointBeatsFillTheFinalHrvWindow() {
        // 120 beats in the opening window plus 35 beats exactly on an aligned end = 600 (34 valid pairs,
        // enough to clear the WINDOW_REFUSE_PAIRS floor). The second window is the final one, so it closes on
        // `end` and holds them; before the fix it was emitted empty and its RMSSD was null. Constant 900 ms RR
        // keeps the RMSSD analytically 0.0 on both platforms — this pins the BINNING, not the RMSSD math.
        val beats = ArrayList<RrInterval>()
        for (i in 0 until 120) beats.add(rr(i.toLong(), 900))
        for (i in 0 until 35) beats.add(rr(600L, 900))
        val wins = SleepStager.sessionHrvWindows(0L, 600L, beats, emptyList())
        assertEquals(listOf(0L, 300L), wins.map { it.startTs })
        assertEquals(
            "the endpoint beats must fill the final window",
            listOf(120, 35), wins.map { it.cleanBeats }
        )
        assertEquals(listOf(0.0, 0.0), wins.map { it.rmssd })
    }

    @Test
    fun nonAlignedEndpointHrvWindowUnchanged() {
        // Paired non-aligned case: end = 450 sits mid-window, so the endpoint beats were already
        // inside the trailing partial window. Same shape, before and after.
        val beats = ArrayList<RrInterval>()
        for (i in 0 until 120) beats.add(rr(i.toLong(), 900))
        for (i in 0 until 3) beats.add(rr(450L, 900))
        val wins = SleepStager.sessionHrvWindows(0L, 450L, beats, emptyList())
        assertEquals(listOf(0L, 300L), wins.map { it.startTs })
        assertEquals(listOf(120, 3), wins.map { it.cleanBeats })
    }

    @Test
    fun hrvWindowsZeroLengthWindowUsesTheEndpointBeats() {
        // The window-level consequence: a zero-length window (start == end) is one closed bin, so beats
        // admitted by the prefilter produce a window with a number instead of null. The NIGHT built from it is
        // refused on purpose — one window is below HrvAnalyzer.NIGHT_MIN_WINDOWS — so the value-level call
        // returns null for a different, documented reason. Twin of Swift
        // testSessionHrvWindowsZeroLengthWindowUsesTheEndpointBeats.
        val beats = (0 until 35).map { rr(1000L, 900) }
        val wins = SleepStager.sessionHrvWindows(1000L, 1000L, beats, emptyList())
        assertEquals(listOf(35), wins.map { it.cleanBeats })
        assertEquals(listOf(0.0), wins.map { it.rmssd })
        assertNull("a one-window session is below the night's minimum and reports nothing",
            SleepStager.sessionAvgHRV(1000L, 1000L, beats))
    }

    @Test
    fun hrvWindowNeedsWindowRefusePairsValidPairs() {
        // A window emits an RMSSD only with HrvAnalyzer.WINDOW_REFUSE_PAIRS (30) valid successive pairs, i.e.
        // 31 clean, time-consistent beats: 30 beats is null, 31 is a value. The floor used to be 20 clean
        // beats; Baek 2015 puts the shortest reliable RMSSD length at 30 s.
        fun window(n: Int): Double? {
            val beats = (0 until n).map { rr(it.toLong(), 900) }
            return SleepStager.sessionHrvWindows(0L, 300L, beats, emptyList()).first().rmssd
        }
        assertNull(window(HrvAnalyzer.WINDOW_REFUSE_PAIRS))
        assertEquals(0.0, window(HrvAnalyzer.WINDOW_REFUSE_PAIRS + 1)!!, 1e-9)
    }

    @Test
    fun sessionAvgHrvIgnoresASparseWindow() {
        // Same fixture as Swift testSessionAvgHRVIgnoresASparseWindow: three full windows of alternating
        // 900/1000 ms (RMSSD 100) next to a sparse one of 900/1300 ms (RMSSD 400, 10 beats). Without the
        // floor the sparse window counted equally and pulled the mean up; with it the sparse window is refused
        // and the night is the full windows' 100.
        val full = (0 until 900).map { rr(it.toLong(), if (it % 2 == 0) 900 else 1000) }
        val sparse = (0 until 10).map { rr(900L + it * 25L, if (it % 2 == 0) 900 else 1300) }
        assertEquals(100.0, SleepStager.sessionAvgHRV(0L, 1200L, full + sparse)!!, 1e-9)
    }

    @Test
    fun hrvWindowsSkipAPairWhoseWallClockSaysABeatIsMissing() {
        // Twin of Swift testSessionHrvWindowsSkipAPairWhoseWallClockSaysABeatIsMissing. A 950/1050/1150/1050
        // triangle of time-consistent beats: every successive |difference| is 100 ms, so RMSSD is exactly 100.
        // Dropping every fourth beat leaves the survivors' R-R values untouched, but the difference across each
        // gap (1150 → 950) is a two-beat difference of 200 ms. Counted, as the pre-1.1 code did, those splices
        // inflate the window to ≈ 141. Each gap spans 2.00 s against a 0.95 s interval, so the wall clock
        // catches every one (HrvAnalyzer.pairIsTimeConsistent), and every pair that survives is a real pair
        // with |difference| 100: the window reads exactly 100 again.
        val pattern = intArrayOf(950, 1050, 1150, 1050)
        val dense = ArrayList<RrInterval>()
        var beatMs = 0L
        for (i in 0 until 320) {
            val ms = pattern[i % 4]
            beatMs += ms
            dense.add(rr(beatMs / 1000, ms))
        }
        val thinned = dense.filterIndexed { idx, _ -> idx % 4 != 3 }
        val legacy = HrvAnalyzer.cleanRRGapAware(thinned.map { it.rrMs.toDouble() })
        val spliced = HrvAnalyzer.rmssdGapAware(legacy.nn, legacy.contiguous) ?: 0.0
        assertTrue("precondition: counting the splices inflates the window", spliced > 130.0)
        val w = SleepStager.sessionHrvWindows(0L, 300L, thinned, emptyList())
        assertEquals(1, w.size)
        assertEquals("the skipped splices no longer inflate the window", 100.0, w[0].rmssd!!, 1e-9)
        assertEquals("a quarter of the beats missing inside the span is limited, not full",
            HrvAnalyzer.HrvWindowTier.LIMITED, w[0].tier)
        assertTrue(w[0].coverage < 0.80)
        assertTrue("the skipped pairs are counted out", w[0].validPairs < w[0].cleanBeats - 1 - 60)
    }
}

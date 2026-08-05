package io.polyfence.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The score is only meaningful if every dimension it reports on was actually
 * measured. Its inputs arrive by name from the debug collector, and a name
 * that does not match resolves to zero — which for latency and error count is
 * the *best* possible reading. A silently-missing input therefore inflates the
 * result rather than depressing it, which is the failure direction nobody
 * notices.
 *
 * `latency is read under the name the collector publishes` is the regression
 * guard for that: it fails if the key the tracker looks up ever drifts from
 * the key the collector emits.
 */
@RunWith(RobolectricTestRunner::class)
class HealthScoreCalculatorTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun score(
        gps: Double? = 1.0,
        latencyMs: Double? = 0.0,
        errors: Int = 0,
        falseEvents: Double? = 0.0
    ) = HealthScoreCalculator.calculate(
        gpsGoodRatio = gps,
        avgDetectionLatencyMs = latencyMs,
        errorCountRecent = errors,
        falseEventRatio = falseEvents,
        isTracking = true,
        activeZoneCount = 5
    )

    @Test
    fun `a perfect device scores full`() {
        assertEquals(100, score().score)
        assertNull(score().topIssue)
    }

    @Test
    fun `a fully degraded device scores zero`() {
        val result = score(gps = 0.0, latencyMs = 9_000.0, errors = 50, falseEvents = 0.9)
        assertEquals(0, result.score)
        assertNotNull(result.topIssue)
    }

    /**
     * One dimension at zero, three perfect: the score loses exactly a quarter.
     * This pins the rescale — a fifth dimension silently returning to the sum
     * would change every number here.
     */
    @Test
    fun `each dimension carries a quarter of the score`() {
        assertEquals(75, score(gps = 0.0).score)
        assertEquals(75, score(latencyMs = 9_000.0).score)
        assertEquals(75, score(errors = 50).score)
        assertEquals(75, score(falseEvents = 0.9).score)
    }

    /**
     * No crossing detected yet: latency has no samples. Excluding it leaves
     * three dimensions, so a device perfect on those still reads 100 — but a
     * device bad on them cannot hide behind a free 25.
     */
    @Test
    fun `an unmeasured dimension is excluded rather than scored perfect`() {
        assertEquals(100, score(latencyMs = null).score)
        assertEquals(67, score(gps = 0.0, latencyMs = null).score)
    }

    /**
     * Zero means opposite things on the two ratio scales, so defaulting them
     * fails in both directions at once: an unsampled GPS ratio reads as the
     * worst possible signal, and an unsampled false-event ratio as the best
     * possible accuracy. Neither is a reading.
     */
    @Test
    fun `an unsampled ratio is excluded rather than scored at either extreme`() {
        // GPS absent: three dimensions remain, all perfect.
        assertEquals(100, score(gps = null).score)
        // False events absent: no free marks for accuracy never shown.
        assertEquals(100, score(falseEvents = null).score)
        // A device that has only errored, with nothing else sampled yet, is
        // judged on the one thing that was measured.
        assertEquals(0, score(gps = null, latencyMs = null, errors = 50, falseEvents = null).score)
    }

    /**
     * Dimension totals that land on .5 once rescaled. Pinned because the two
     * platforms round through different standard-library calls and must agree.
     */
    @Test
    fun `the rescale rounds halves up`() {
        assertEquals(13, score(gps = 0.5, latencyMs = 9_000.0, errors = 50, falseEvents = 0.9).score)
        assertEquals(63, score(gps = 1.0, latencyMs = 400.0, errors = 4, falseEvents = 0.3).score)
    }

    @Test
    fun `not tracking scores zero regardless of everything else`() {
        val result = HealthScoreCalculator.calculate(
            gpsGoodRatio = 1.0,
            avgDetectionLatencyMs = 0.0,
            errorCountRecent = 0,
            falseEventRatio = 0.0,
            isTracking = false,
            activeZoneCount = 5
        )
        assertEquals(0, result.score)
        assertEquals("Tracking is not active", result.topIssue)
    }

    /**
     * GPS is merely poor (loses 10 of 20); latency is at its floor (loses 20).
     * The worst one is the one worth telling a developer about.
     */
    @Test
    fun `top issue names the worst dimension not merely a failing one`() {
        val result = score(gps = 0.5, latencyMs = 9_000.0)
        assertTrue(result.topIssue!!.contains("Detection latency"))
    }

    @Test
    fun `latency is read under the name the collector publishes`() {
        var info: Map<String, Any>? = null
        val worker = Thread { info = PolyfenceDebugCollector.collectDebugInfo(context) }
        worker.start()
        worker.join()

        val performance = info!!["performance"] as Map<*, *>
        // Presence, not value: the entry is null until a crossing has been
        // detected, and null is exactly what tells the score to leave the
        // dimension out rather than award it full marks.
        assertTrue(
            "the tracker reads this key to score latency; a rename here scores a dimension nobody measured",
            performance.containsKey("averageDetectionLatency")
        )
    }
}

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
        gps: Double = 1.0,
        latencyMs: Double = 0.0,
        errors: Int = 0,
        falseEvents: Double = 0.0
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
        assertNotNull(
            "the tracker reads this key to score latency; a rename here scores a dimension nobody measured",
            performance["averageDetectionLatency"]
        )
    }
}

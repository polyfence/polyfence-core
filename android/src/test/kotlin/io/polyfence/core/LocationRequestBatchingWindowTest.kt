package io.polyfence.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Coverage for the batching window a location request is built with.
 *
 * The battery strategy signals "pause GPS" by returning [Long.MAX_VALUE] as the
 * update interval, and `calculateCurrentInterval` takes the longest of the
 * candidate strategies — so that value reaches the request builder whenever the
 * device is below the critical battery threshold and away from every zone.
 * Doubling it to derive the batching window wraps to a negative number, which
 * `LocationRequest.Builder.setMaxUpdateDelayMillis` rejects, taking the tracking
 * service down with it.
 *
 * Being near a zone returns earlier with the proximity interval, which is why
 * the arithmetic holds for the whole of a typical test session and fails only
 * once a low battery coincides with being away from zones.
 *
 * The helper is private; reflection reaches it the same way
 * `LocationTrackerPersistHookTest` reaches the persist hook, rather than
 * widening production visibility for a test.
 */
class LocationRequestBatchingWindowTest {

    private fun batchingWindowFor(interval: Long): Long {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "batchingWindowFor",
            Long::class.javaPrimitiveType
        )
        method.isAccessible = true
        // The helper reads no instance state, so an allocated-but-unstarted
        // Service is enough of a receiver to invoke it.
        val instance = LocationTracker()
        return method.invoke(instance, interval) as Long
    }

    @Test
    fun `a paused-GPS interval yields a valid window rather than overflowing`() {
        val window = batchingWindowFor(Long.MAX_VALUE)

        assertTrue(
            "A batching window must never be negative — LocationRequest rejects it",
            window >= 0
        )
        assertEquals(Long.MAX_VALUE, window)
    }

    @Test
    fun `an interval just past the doubling threshold saturates`() {
        val justOver = Long.MAX_VALUE / 2 + 1

        assertTrue(batchingWindowFor(justOver) >= 0)
        assertEquals(Long.MAX_VALUE, batchingWindowFor(justOver))
    }

    @Test
    fun `an interval at the doubling threshold still doubles exactly`() {
        val atThreshold = Long.MAX_VALUE / 2

        assertEquals(atThreshold * 2, batchingWindowFor(atThreshold))
    }

    @Test
    fun `ordinary intervals are doubled`() {
        assertEquals(10_000L, batchingWindowFor(5_000L))
        assertEquals(240_000L, batchingWindowFor(120_000L))
    }
}

package io.polyfence.core

import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * Regression coverage for BUG-016: PolyfenceErrorManager.reportError
 * must persist the error to PolyfenceDebugCollector's history in
 * addition to invoking the real-time onError callback. Pre-fix the
 * two systems were separate and errorHistory() always returned []
 * regardless of how many errors had fired.
 *
 * PolyfenceDebugCollector is a companion-scoped singleton with no
 * public reset, so each test uses a unique error `type` and asserts
 * by filtering on that type — that way concurrent / prior state on
 * the shared deque can't confuse the assertion.
 */
class PolyfenceErrorManagerHistoryTest {

    @After
    fun tearDown() {
        PolyfenceErrorManager.dispose()
    }

    @Test
    fun `reportError persists to errorHistory even without an onError subscriber`() {
        // Deliberately do NOT initialise a callback. Pre-fix the error
        // vanished entirely in this case — no callback + no history
        // write. Post-fix, the history captures it.
        val marker = "bug016_no_subscriber_${System.nanoTime()}"
        PolyfenceErrorManager.reportError(
            type = marker,
            message = "Battery optimization bypass required",
            context = mapOf("platform" to "android")
        )

        val history = PolyfenceDebugCollector.getErrorHistory(null, listOf(marker))
        assertEquals("errorHistory must capture the reported error", 1, history.size)
        assertEquals(marker, history[0]["type"])
        assertEquals("Battery optimization bypass required", history[0]["message"])
    }

    @Test
    fun `reportError persists even when an onError callback is registered`() {
        // Both paths fire — the real-time callback stays intact and the
        // history captures the error.
        val marker = "bug016_with_subscriber_${System.nanoTime()}"
        val received = mutableListOf<Map<String, Any>>()
        PolyfenceErrorManager.initialize { received.add(it) }

        PolyfenceErrorManager.reportError(
            type = marker,
            message = "GPS signal timeout",
            context = mapOf("platform" to "android")
        )

        assertEquals(1, received.size)
        assertEquals(marker, received[0]["type"])

        val history = PolyfenceDebugCollector.getErrorHistory(null, listOf(marker))
        assertEquals(1, history.size)
        assertEquals(marker, history[0]["type"])
    }

    @Test
    fun `errorHistory returns errors filtered by type`() {
        val gpsMarker = "bug016_gps_${System.nanoTime()}"
        val batteryMarker = "bug016_battery_${System.nanoTime()}"
        PolyfenceErrorManager.reportError(gpsMarker, "gps 1")
        PolyfenceErrorManager.reportError(batteryMarker, "batt 1")
        PolyfenceErrorManager.reportError(gpsMarker, "gps 2")

        val onlyGps = PolyfenceDebugCollector.getErrorHistory(null, listOf(gpsMarker))
        assertEquals(2, onlyGps.size)
        assertTrue(onlyGps.all { it["type"] == gpsMarker })

        val onlyBattery = PolyfenceDebugCollector.getErrorHistory(null, listOf(batteryMarker))
        assertEquals(1, onlyBattery.size)
        assertEquals("batt 1", onlyBattery[0]["message"])
    }
}

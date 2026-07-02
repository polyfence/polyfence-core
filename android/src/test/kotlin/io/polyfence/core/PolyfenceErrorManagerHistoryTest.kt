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
    fun `history preserves correlationId across the callback and the history entry`() {
        // Parity nit from the peer review: history entry must carry
        // the same correlationId the callback sees, so consumers can
        // correlate a persisted row with a live onError event.
        val marker = "bug016_correlation_${System.nanoTime()}"
        var callbackCorrelationId: String? = null
        PolyfenceErrorManager.initialize { errorMap ->
            callbackCorrelationId = errorMap["correlationId"] as? String
        }

        PolyfenceErrorManager.reportError(
            type = marker,
            message = "test",
            context = emptyMap()
        )

        val history = PolyfenceDebugCollector.getErrorHistory(null, listOf(marker))
        assertEquals(1, history.size)
        assertNotNull("callback must have received a correlationId", callbackCorrelationId)
        assertEquals(callbackCorrelationId, history[0]["correlationId"])
    }

    @Test
    fun `history is persisted even when the onError callback throws`() {
        // Tannu's nit on PR #46: if a consumer's callback throws, the
        // history-write must still land. Regression lock for the
        // ordering guarantee — record-then-invoke.
        val marker = "bug016_callback_throws_${System.nanoTime()}"
        PolyfenceErrorManager.initialize { _ ->
            throw RuntimeException("consumer onError blew up")
        }

        try {
            PolyfenceErrorManager.reportError(
                type = marker,
                message = "test",
                context = emptyMap()
            )
            // reportError doesn't try/catch the callback, so the
            // exception propagates. That's the current contract —
            // fine as long as the history was written first.
            fail("expected the throwing callback to propagate")
        } catch (e: RuntimeException) {
            assertEquals("consumer onError blew up", e.message)
        }

        val history = PolyfenceDebugCollector.getErrorHistory(null, listOf(marker))
        assertEquals(
            "history must capture the reported error even when the callback throws",
            1,
            history.size
        )
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

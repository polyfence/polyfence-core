package io.polyfence.core

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * Read-after-write coverage for the direct-apply zone helpers
 * ([LocationTracker.applyAddZoneDirect] / [applyRemoveZoneDirect] /
 * [applyClearZonesDirect]).
 *
 * Bug-021 was that the Intent-based zone ops on Android returned
 * before the Service processed them, so an immediately-following
 * `getCurrentZoneStates()` did not reflect the change. The direct
 * helpers dispatch straight to the running Service instance — engine
 * state and persistence updated synchronously before return. These
 * tests verify that contract with zero sleep.
 *
 * `isRunning` is flipped to `true` via reflection in `@Before` to
 * simulate an active tracking session — the `addZoneById` guard
 * mirrors the `ACTION_ADD_ZONE` Intent handler and drops zone-add
 * calls when tracking is stopped. Robolectric cannot cleanly call
 * `tracker.startTracking()` because that path requires runtime
 * permissions and `startForeground` ceremony not available in a
 * pure-JVM Robolectric context.
 *
 * Fallback-when-no-service behaviour is not covered here: Robolectric
 * builds a Service instance for the whole test, so [currentInstance]
 * is always populated and the direct path is exercised. Fallback is a
 * plain `startService(Intent)` call — same shape as the pre-fix code
 * path that the existing bridges relied on for months.
 */
@RunWith(RobolectricTestRunner::class)
class LocationTrackerZoneOpsTest {

    private lateinit var tracker: LocationTracker

    @Before
    fun setUp() {
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
        setIsRunning(true)
        // Reset the engine to a known-empty baseline between tests — the
        // companion `currentInstance` is process-wide so any zones left
        // by a previous test would poison the read.
        LocationTracker.applyClearZonesDirect(tracker)
    }

    @After
    fun tearDown() {
        LocationTracker.applyClearZonesDirect(tracker)
        setIsRunning(false)
        // Release the Service instance's process-wide references
        // (currentInstance, telemetryAggregator, health handlers) so a
        // subsequent test method starts from a clean slate.
        tracker.onDestroy()
    }

    private fun setIsRunning(value: Boolean) {
        // Kotlin compiles a companion `var isRunning` with private set
        // to a static field on the enclosing class (not the Companion
        // inner class). Grab the backing field, force accessible, set.
        val field = LocationTracker::class.java.getDeclaredField("isRunning")
        field.isAccessible = true
        field.setBoolean(null, value)
    }

    private fun circleZone(
        lat: Double = 40.7128,
        lng: Double = -74.0060,
        radius: Double = 100.0
    ): Map<String, Any> = mapOf(
        "type" to "circle",
        "center" to mapOf(
            "latitude" to lat,
            "longitude" to lng
        ),
        "radius" to radius
    )

    // -------- applyAddZoneDirect: read-after-write --------

    @Test
    fun `applyAddZoneDirect makes the new zone observable on immediate read`() {
        assertEquals(0, LocationTracker.getCurrentZoneStates().size)

        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())

        val states = LocationTracker.getCurrentZoneStates()
        assertTrue("expected office in $states", states.containsKey("office"))
        assertEquals(false, states["office"]) // initial state: outside
    }

    @Test
    fun `applyAddZoneDirect adding multiple zones makes them all observable on immediate read`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.applyAddZoneDirect(tracker, "gym", "Gym", circleZone(lat = 40.7500))
        LocationTracker.applyAddZoneDirect(tracker, "home", "Home", circleZone(lat = 40.8000))

        val states = LocationTracker.getCurrentZoneStates()
        assertEquals(3, states.size)
        assertTrue(states.containsKey("office"))
        assertTrue(states.containsKey("gym"))
        assertTrue(states.containsKey("home"))
    }

    @Test
    fun `applyAddZoneDirect rejects invalid zone data and does not persist`() {
        // Malformed circle: unrecognised type. ZoneData.fromMap must throw,
        // addZoneById's catch branch fires, reportError is dispatched,
        // and the zone must NOT land in getCurrentZoneStates() or the
        // engine's persisted set.
        val invalidZone = mapOf(
            "type" to "trapezoid",
            "center" to mapOf("latitude" to 40.0, "longitude" to -74.0),
            "radius" to 100.0
        )

        LocationTracker.applyAddZoneDirect(tracker, "bad-zone", "Bad", invalidZone)

        val states = LocationTracker.getCurrentZoneStates()
        assertFalse("bad-zone must not be in $states", states.containsKey("bad-zone"))
        assertEquals(0, states.size)
    }

    @Test
    fun `applyAddZoneDirect is a no-op when tracking is not active`() {
        // Guard mirrors the ACTION_ADD_ZONE Intent handler: add-zone is
        // meaningful only while the Service is actively tracking. Bridges
        // handle the pre-tracking case with their own local persistence
        // and never call applyAddZoneDirect in that state — the guard
        // exists to defend the direct path against the race window between
        // stopTracking() firing and the Service's onDestroy running.
        setIsRunning(false)

        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())

        assertEquals(0, LocationTracker.getCurrentZoneStates().size)
    }

    // -------- applyRemoveZoneDirect: read-after-write --------

    @Test
    fun `applyRemoveZoneDirect makes the removal observable on immediate read`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.applyAddZoneDirect(tracker, "gym", "Gym", circleZone(lat = 40.7500))
        assertEquals(2, LocationTracker.getCurrentZoneStates().size)

        LocationTracker.applyRemoveZoneDirect(tracker, "office")

        val states = LocationTracker.getCurrentZoneStates()
        assertEquals(1, states.size)
        assertFalse("office should be gone from $states", states.containsKey("office"))
        assertTrue(states.containsKey("gym"))
    }

    @Test
    fun `applyRemoveZoneDirect on an unknown zone id is a safe no-op`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())

        LocationTracker.applyRemoveZoneDirect(tracker, "no-such-zone")

        assertEquals(1, LocationTracker.getCurrentZoneStates().size)
        assertTrue(LocationTracker.getCurrentZoneStates().containsKey("office"))
    }

    // -------- applyClearZonesDirect: read-after-write --------

    @Test
    fun `applyClearZonesDirect makes the wipe observable on immediate read`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.applyAddZoneDirect(tracker, "gym", "Gym", circleZone(lat = 40.7500))
        LocationTracker.applyAddZoneDirect(tracker, "home", "Home", circleZone(lat = 40.8000))
        assertEquals(3, LocationTracker.getCurrentZoneStates().size)

        LocationTracker.applyClearZonesDirect(tracker)

        assertEquals(0, LocationTracker.getCurrentZoneStates().size)
    }
}

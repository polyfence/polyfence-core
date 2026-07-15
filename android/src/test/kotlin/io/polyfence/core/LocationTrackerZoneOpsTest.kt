package io.polyfence.core

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
        // Reset the tracker's engine to a known-empty baseline between
        // tests — the companion `currentInstance` is process-wide so
        // any zones left by a previous test would poison the read.
        LocationTracker.applyClearZonesDirect(tracker)
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

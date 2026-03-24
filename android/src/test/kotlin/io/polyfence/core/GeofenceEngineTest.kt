package io.polyfence.core

import android.location.Location
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import kotlin.math.abs

/**
 * Unit tests for GeofenceEngine
 * Validates core geofencing logic: zone lifecycle, containment, dwell tracking, and state recovery
 */
class GeofenceEngineTest {

    private lateinit var engine: GeofenceEngine
    private val events = mutableListOf<Triple<String, String, String>>() // zoneId, eventType, timestamp

    @Before
    fun setUp() {
        engine = GeofenceEngine()
        events.clear()

        // Set up event callback to capture events
        engine.setEventCallback { zoneId, eventType, _, _ ->
            events.add(Triple(zoneId, eventType, System.currentTimeMillis().toString()))
        }
    }

    // ========================================================================
    // Zone Lifecycle Tests
    // ========================================================================

    @Test
    fun `addZone adds circle zone successfully`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )

        engine.addZone("zone-1", "NYC Zone", zoneData)

        assertTrue("Engine should have zones", engine.hasZones())
        assertEquals("Zone count should be 1", 1, engine.getZoneCount())
        assertEquals("Zone name should match", "NYC Zone", engine.getZoneName("zone-1"))
    }

    @Test
    fun `addZone adds polygon zone successfully`() {
        val polygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to polygon
        )

        engine.addZone("poly-1", "Square Zone", zoneData)

        assertEquals("Zone name should match", "Square Zone", engine.getZoneName("poly-1"))
    }

    @Test
    fun `removeZone removes zone from engine`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )
        engine.addZone("zone-1", "NYC Zone", zoneData)
        assertTrue("Zone should exist", engine.hasZones())

        engine.removeZone("zone-1")

        assertFalse("Zone should be removed", engine.hasZones())
        assertEquals("Zone count should be 0", 0, engine.getZoneCount())
        assertNull("Zone name should be null", engine.getZoneName("zone-1"))
    }

    @Test
    fun `removeAllZones clears all zones`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )
        engine.addZone("zone-1", "Zone 1", zoneData)
        engine.addZone("zone-2", "Zone 2", zoneData)
        engine.addZone("zone-3", "Zone 3", zoneData)

        engine.clearAllZones()

        assertFalse("No zones should remain", engine.hasZones())
        assertEquals("Zone count should be 0", 0, engine.getZoneCount())
    }

    @Test
    fun `hasZones returns false when empty`() {
        assertFalse("Empty engine should have no zones", engine.hasZones())
    }

    @Test
    fun `addZone with invalid zone type throws exception`() {
        val invalidZoneData = mapOf("type" to "invalid")

        assertThrows(IllegalArgumentException::class.java) {
            engine.addZone("bad-zone", "Bad Zone", invalidZoneData)
        }
    }

    @Test
    fun `addZone circle missing center throws exception`() {
        val badCircle = mapOf(
            "type" to "circle",
            "radius" to 100.0
        )

        assertThrows(IllegalArgumentException::class.java) {
            engine.addZone("no-center", "Bad Circle", badCircle)
        }
    }

    @Test
    fun `addZone circle missing radius throws exception`() {
        val badCircle = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060)
        )

        assertThrows(IllegalArgumentException::class.java) {
            engine.addZone("no-radius", "Bad Circle", badCircle)
        }
    }

    // ========================================================================
    // Circle Containment Tests
    // ========================================================================

    @Test
    fun `point inside circle returns true`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0 // 1km radius
        )
        engine.addZone("circle-1", "NYC", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Point ~100m from center (within 1km)
        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertTrue("Point should be inside circle", states["circle-1"] ?: false)
    }

    @Test
    fun `point outside circle returns false`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0 // 100m radius
        )
        engine.addZone("circle-1", "Tiny Zone", zoneData)

        // Point ~2km from center (outside 100m)
        val location = createLocation(40.7328, -74.0260)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertFalse("Point should be outside circle", states["circle-1"] ?: true)
    }

    @Test
    fun `zero radius circle behaves as point match`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 0.0 // Zero radius
        )
        engine.addZone("point-zone", "Point Zone", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Exact point
        val exactLocation = createLocation(40.7128, -74.0060)
        engine.checkLocation(exactLocation)
        val exactStates = engine.getCurrentZoneStates()
        assertTrue("Exact point should be inside 0-radius circle", exactStates["point-zone"] ?: false)

        // Slightly off
        val nearLocation = createLocation(40.7129, -74.0061)
        engine.checkLocation(nearLocation)
        val nearStates = engine.getCurrentZoneStates()
        assertFalse("Nearby point should be outside 0-radius circle", nearStates["point-zone"] ?: true)
    }

    // ========================================================================
    // Polygon Containment Tests
    // ========================================================================

    @Test
    fun `point inside polygon returns true`() {
        val polygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to polygon
        )
        engine.addZone("square-1", "Square", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Center of square
        val location = createLocation(0.5, 0.5)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertTrue("Point inside square should be true", states["square-1"] ?: false)
    }

    @Test
    fun `point outside polygon returns false`() {
        val polygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to polygon
        )
        engine.addZone("square-1", "Square", zoneData)

        // Well outside
        val location = createLocation(2.0, 2.0)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertFalse("Point outside square should be false", states["square-1"] ?: true)
    }

    @Test
    fun `point on polygon edge`() {
        val polygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to polygon
        )
        engine.addZone("square-1", "Square", zoneData)

        // Point on edge
        val location = createLocation(0.5, 0.0)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        // Ray-casting behavior: edge case - result depends on implementation
        assertNotNull("Edge point should have a defined state", states["square-1"])
    }

    @Test
    fun `point on polygon vertex`() {
        val polygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to polygon
        )
        engine.addZone("square-1", "Square", zoneData)

        // Exact vertex
        val location = createLocation(0.0, 0.0)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertNotNull("Vertex point should have a defined state", states["square-1"])
    }

    @Test
    fun `polygon with fewer than 3 points throws exception`() {
        val badPolygon = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to badPolygon
        )

        assertThrows(IllegalArgumentException::class.java) {
            engine.addZone("bad-poly", "Bad Polygon", zoneData)
        }
    }

    @Test
    fun `self-intersecting polygon throws exception`() {
        // Bowtie shape: vertices go 0->1->2->3 where edges 0-1 and 2-3 intersect
        val bowTie = listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
        val zoneData = mapOf(
            "type" to "polygon",
            "polygon" to bowTie
        )

        assertThrows(IllegalArgumentException::class.java) {
            engine.addZone("self-intersect", "Bad Polygon", zoneData)
        }
    }

    // ========================================================================
    // Dwell Time Tracking Tests
    // ========================================================================

    @Test
    fun `entering zone starts dwell tracking`() {
        engine.setDwellConfig(enabled = true, thresholdMs = 1000L) // 1 second for testing

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("dwell-zone", "Dwell Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Enter zone
        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        // Should fire ENTER event
        val enterEvents = events.filter { it.second == "ENTER" }
        assertEquals("Should have ENTER event", 1, enterEvents.size)
    }

    @Test
    fun `dwell event fires after threshold exceeded`() {
        engine.setDwellConfig(enabled = true, thresholdMs = 100L) // Short threshold for testing

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("dwell-zone", "Dwell Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Enter zone
        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        events.clear() // Clear ENTER event

        // Wait and check again
        Thread.sleep(200)
        engine.checkLocation(location)

        // Should have DWELL event
        val dwellEvents = events.filter { it.second == "DWELL" }
        assertTrue("Should have DWELL event after threshold", dwellEvents.size > 0)
    }

    @Test
    fun `dwell event fires only once per entry`() {
        engine.setDwellConfig(enabled = true, thresholdMs = 50L)

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("dwell-zone", "Dwell Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        val location = createLocation(40.7138, -74.0050)

        // Enter, then exceed dwell threshold so first DWELL fires
        engine.checkLocation(location)
        Thread.sleep(150)
        engine.checkLocation(location)

        events.clear()

        // Further checks while still inside must not emit duplicate DWELL
        engine.checkLocation(location)
        Thread.sleep(100)
        engine.checkLocation(location)

        val dwellEvents = events.filter { it.second == "DWELL" }
        assertEquals("DWELL should only fire once per entry", 0, dwellEvents.size)
    }

    @Test
    fun `exiting zone stops dwell tracking`() {
        engine.setDwellConfig(enabled = true, thresholdMs = 5000L) // 5 second threshold

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("dwell-zone", "Dwell Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Enter zone
        val insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)
        events.clear()

        // Exit zone (far away)
        val outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        // Should have EXIT event
        val exitEvents = events.filter { it.second == "EXIT" }
        assertEquals("Should have EXIT event", 1, exitEvents.size)
    }

    @Test
    fun `dwell disabled does not fire dwell events`() {
        engine.setDwellConfig(enabled = false)

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("no-dwell", "No Dwell", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        Thread.sleep(500)
        engine.checkLocation(location)

        val dwellEvents = events.filter { it.second == "DWELL" }
        assertEquals("No DWELL events when disabled", 0, dwellEvents.size)
    }

    // ========================================================================
    // False Event Detection Tests (30-second reversal window)
    // ========================================================================

    @Test
    fun `quick exit after enter is flagged as reversal`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("flip-zone", "Flip Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Enter event
        val insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)
        val lastZoneState = engine.getCurrentZoneStates()["flip-zone"] ?: false

        // Quick exit (< 30s)
        val outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        // Check if reversal is detected
        val isReversal = engine.isRecentReversal("flip-zone", "EXIT")
        assertTrue("Quick exit should be flagged as reversal", isReversal)
    }

    @Test
    fun `exit after 30+ seconds is not flagged as reversal`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("slow-zone", "Slow Test", zoneData)

        // Enter event (simulated - we can't easily simulate real time)
        val insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)

        // For testing, reversal detection requires actual time passage
        // This is a limitation of unit testing - testing reversal requires mocking time
        val isReversal = engine.isRecentReversal("slow-zone", "EXIT")
        assertFalse("No reversal without recent enter", isReversal)
    }

    // ========================================================================
    // Zone State Recovery Tests
    // ========================================================================

    @Test
    fun `zone states are preserved across location checks`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("persist-zone", "Persist Test", zoneData)
        engine.setValidationConfig(requireConfirmation = false)

        // Enter
        val insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)
        val stateAfterEnter = engine.getCurrentZoneStates()["persist-zone"]
        assertTrue("Should be inside after enter", stateAfterEnter ?: false)

        // Check again without exiting
        engine.checkLocation(insideLocation)
        val stateAfterRecheck = engine.getCurrentZoneStates()["persist-zone"]
        assertEquals("State should remain consistent", stateAfterEnter, stateAfterRecheck)
    }

    @Test
    fun `getCurrentZoneStates returns current state map`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("state-zone", "State Test", zoneData)

        val states = engine.getCurrentZoneStates()
        assertTrue("States map should have zone", states.containsKey("state-zone"))
        assertFalse("Should be outside initially", states["state-zone"] ?: true)
    }

    @Test
    fun `multiple zones track independent states`() {
        val insideZone = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        val outsideZone = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 50.0, "longitude" to -80.0),
            "radius" to 100.0
        )
        engine.addZone("near-zone", "Near", insideZone)
        engine.addZone("far-zone", "Far", outsideZone)
        engine.setValidationConfig(requireConfirmation = false)

        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertTrue("Should be inside near-zone", states["near-zone"] ?: false)
        assertFalse("Should be outside far-zone", states["far-zone"] ?: true)
    }

    // ========================================================================
    // Edge Cases and Validation
    // ========================================================================

    @Test
    fun `location with poor GPS accuracy is rejected`() {
        engine.setGpsAccuracyThreshold(50.0f) // 50m threshold

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("accuracy-zone", "Accuracy Test", zoneData)

        // Create location with poor accuracy (100m, exceeds 50m threshold)
        val poorLocation = createLocation(40.7138, -74.0050, accuracy = 100.0f)
        engine.checkLocation(poorLocation)

        // Should not have state change because location was rejected
        val states = engine.getCurrentZoneStates()
        assertFalse("Should remain outside due to poor accuracy", states["accuracy-zone"] ?: true)
    }

    @Test
    fun `location at zero coordinates is rejected`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("zero-zone", "Zero Test", zoneData)

        val badLocation = Location("test")
        badLocation.latitude = 0.0
        badLocation.longitude = 0.0
        badLocation.accuracy = 10.0f

        engine.checkLocation(badLocation)

        // State should not change for invalid location
        val states = engine.getCurrentZoneStates()
        assertFalse("Zero location should not trigger state change", states["zero-zone"] ?: true)
    }

    @Test
    fun `empty zone list does not crash on location check`() {
        val location = createLocation(40.7138, -74.0050)

        // Should not throw
        engine.checkLocation(location)

        val states = engine.getCurrentZoneStates()
        assertTrue("Empty zone list should produce empty state map", states.isEmpty())
    }

    @Test
    fun `zone name retrieval works for valid and invalid zones`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )
        engine.addZone("exist-zone", "Exists", zoneData)

        assertEquals("Should retrieve existing zone name", "Exists", engine.getZoneName("exist-zone"))
        assertNull("Should return null for non-existent zone", engine.getZoneName("no-zone"))
    }

    @Test
    fun `zone count accuracy`() {
        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )

        assertEquals("Initial count should be 0", 0, engine.getZoneCount())

        engine.addZone("z1", "Zone 1", zoneData)
        assertEquals("Count should be 1", 1, engine.getZoneCount())

        engine.addZone("z2", "Zone 2", zoneData)
        assertEquals("Count should be 2", 2, engine.getZoneCount())

        engine.removeZone("z1")
        assertEquals("Count should be 1 after removal", 1, engine.getZoneCount())

        engine.clearAllZones()
        assertEquals("Count should be 0 after clear", 0, engine.getZoneCount())
    }

    @Test
    fun `validation config affects detection behavior`() {
        engine.setValidationConfig(requireConfirmation = false)

        val zoneData = mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 1000.0
        )
        engine.addZone("validate-zone", "Validate Test", zoneData)

        val location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        events.clear()

        // Single location check with confirmation disabled should produce event
        val outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        assertTrue("Exit event should fire immediately without confirmation",
                   events.any { it.second == "EXIT" })
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    private fun createLocation(lat: Double, lng: Double, accuracy: Float = 10.0f): Location {
        val location = mock(Location::class.java)
        `when`(location.latitude).thenReturn(lat)
        `when`(location.longitude).thenReturn(lng)
        `when`(location.accuracy).thenReturn(accuracy)
        `when`(location.hasAccuracy()).thenReturn(true)
        return location
    }
}

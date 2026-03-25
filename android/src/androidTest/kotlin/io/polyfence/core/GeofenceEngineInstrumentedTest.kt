package io.polyfence.core

import android.location.Location
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.polyfence.core.utils.GeoMath
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/**
 * Instrumented tests for GeofenceEngine.
 * Validates core geofencing algorithms on a real Android device/emulator.
 */
@RunWith(AndroidJUnit4::class)
class GeofenceEngineInstrumentedTest {

    private lateinit var engine: GeofenceEngine
    private val events = mutableListOf<Pair<String, String>>() // zoneId, eventType

    @Before
    fun setUp() {
        engine = GeofenceEngine()
        events.clear()
        engine.setEventCallback { zoneId, eventType, _, _ ->
            events.add(Pair(zoneId, eventType))
        }
    }

    // ========================================================================
    // Haversine Distance Tests
    // ========================================================================

    @Test
    fun haversineDistance_knownPoints_returnsAccurateResult() {
        // NYC to London: ~5570 km
        val distance = GeoMath.haversineDistance(40.7128, -74.0060, 51.5074, -0.1278)
        assertTrue("NYC to London should be ~5570km, got ${distance / 1000}km",
            abs(distance - 5_570_000) < 50_000) // within 50km tolerance
    }

    @Test
    fun haversineDistance_samePoint_returnsZero() {
        val distance = GeoMath.haversineDistance(40.7128, -74.0060, 40.7128, -74.0060)
        assertEquals("Same point distance should be 0", 0.0, distance, 0.001)
    }

    @Test
    fun haversineDistance_antipodal_returnsHalfCircumference() {
        // North pole to south pole: ~20,000 km
        val distance = GeoMath.haversineDistance(90.0, 0.0, -90.0, 0.0)
        assertTrue("Pole to pole should be ~20000km, got ${distance / 1000}km",
            abs(distance - 20_015_000) < 100_000)
    }

    // ========================================================================
    // Ray-Casting (Point-in-Polygon) Tests
    // ========================================================================

    @Test
    fun rayCasting_pointInsideSquare_returnsTrue() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        assertTrue("Point at center should be inside", GeoMath.isPointInPolygon(0.5, 0.5, square))
    }

    @Test
    fun rayCasting_pointOutsideSquare_returnsFalse() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        assertFalse("Point outside should not be inside", GeoMath.isPointInPolygon(2.0, 2.0, square))
    }

    @Test
    fun rayCasting_concavePolygon_handlesCorrectly() {
        // L-shaped polygon
        val lShape = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 2.0),
            Pair(1.0, 2.0),
            Pair(1.0, 1.0),
            Pair(2.0, 1.0),
            Pair(2.0, 0.0)
        )
        assertTrue("Inside L should be true", GeoMath.isPointInPolygon(0.5, 0.5, lShape))
        assertFalse("Outside L concavity should be false", GeoMath.isPointInPolygon(1.5, 1.5, lShape))
    }

    // ========================================================================
    // Circle Zone Detection Tests
    // ========================================================================

    @Test
    fun circleZone_pointInside_detectedAsEnter() {
        @Suppress("DEPRECATION")
        engine.addZone("circle-1", "Test Circle", mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 500.0
        ))

        val location = createLocation(40.7128, -74.0060, 10f)
        engine.processLocation(location)

        assertTrue("Should detect ENTER event", events.any { it.second == "ENTER" })
    }

    @Test
    fun circleZone_pointOutside_noEnterEvent() {
        @Suppress("DEPRECATION")
        engine.addZone("circle-1", "Test Circle", mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        ))

        // Point 1km away
        val location = createLocation(40.7228, -74.0060, 10f)
        engine.processLocation(location)

        assertFalse("Should not detect ENTER event", events.any { it.second == "ENTER" })
    }

    // ========================================================================
    // Polygon Zone Detection Tests
    // ========================================================================

    @Test
    fun polygonZone_pointInside_detectedAsEnter() {
        @Suppress("DEPRECATION")
        engine.addZone("poly-1", "Test Polygon", mapOf(
            "type" to "polygon",
            "polygon" to listOf(
                mapOf("latitude" to 40.71, "longitude" to -74.01),
                mapOf("latitude" to 40.71, "longitude" to -74.00),
                mapOf("latitude" to 40.72, "longitude" to -74.00),
                mapOf("latitude" to 40.72, "longitude" to -74.01)
            )
        ))

        val location = createLocation(40.715, -74.005, 10f)
        engine.processLocation(location)

        assertTrue("Should detect ENTER for polygon", events.any { it.second == "ENTER" })
    }

    // ========================================================================
    // ZoneConfig Typed API Tests
    // ========================================================================

    @Test
    fun zoneConfig_circleFactory_createsValidZone() {
        val config = ZoneConfig.circle(
            id = "typed-circle",
            name = "Typed Circle",
            center = GeofenceEngine.LatLng(40.7128, -74.0060),
            radius = 200.0
        )

        engine.addZone(config)

        assertTrue("Engine should have zones", engine.hasZones())
        assertEquals("Zone count should be 1", 1, engine.getZoneCount())
    }

    @Test
    fun zoneConfig_polygonFactory_createsValidZone() {
        val config = ZoneConfig.polygon(
            id = "typed-poly",
            name = "Typed Polygon",
            polygon = listOf(
                GeofenceEngine.LatLng(40.71, -74.01),
                GeofenceEngine.LatLng(40.71, -74.00),
                GeofenceEngine.LatLng(40.72, -74.00),
                GeofenceEngine.LatLng(40.72, -74.01)
            )
        )

        engine.addZone(config)

        assertTrue("Engine should have zones", engine.hasZones())
        assertEquals("Zone count should be 1", 1, engine.getZoneCount())
    }

    @Test
    fun zoneConfig_toMap_roundTrips() {
        val config = ZoneConfig.circle(
            id = "rt-circle",
            name = "Round Trip",
            center = GeofenceEngine.LatLng(40.7128, -74.0060),
            radius = 150.0
        )

        val map = config.toMap()
        assertEquals("circle", map["type"])
        assertNotNull(map["center"])
        assertEquals(150.0, map["radius"])
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    private fun createLocation(lat: Double, lng: Double, accuracy: Float): Location {
        return Location("test").apply {
            latitude = lat
            longitude = lng
            this.accuracy = accuracy
            time = System.currentTimeMillis()
        }
    }
}

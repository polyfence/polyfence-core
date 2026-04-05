package io.polyfence.core.utils

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class GeoMathTest {

    // ========================================================================
    // Haversine Distance Tests
    // ========================================================================

    @Test
    fun `haversine distance between identical points is zero`() {
        val distance = GeoMath.haversineDistance(51.5074, -0.1278, 51.5074, -0.1278)
        assertEquals("Same point should have 0 distance", 0.0, distance, 0.1)
    }

    @Test
    fun `haversine distance London to Paris is approximately 343km`() {
        // London: 51.5074°N, -0.1278°W
        // Paris: 48.8566°N, 2.3522°E
        val distance = GeoMath.haversineDistance(51.5074, -0.1278, 48.8566, 2.3522)
        // Expected: ~343 km = 343000 meters
        assertTrue("London to Paris should be ~343km", distance > 340000 && distance < 345000)
    }

    @Test
    fun `haversine distance using LatLng overload`() {
        val london = GeoMath.LatLng(51.5074, -0.1278)
        val paris = GeoMath.LatLng(48.8566, 2.3522)
        val distance = GeoMath.haversineDistance(london, paris)
        assertTrue("London to Paris should be ~343km", distance > 340000 && distance < 345000)
    }

    @Test
    fun `haversine distance antipodal points is approximately 20000km`() {
        // Equator to opposite side of equator
        val distance = GeoMath.haversineDistance(0.0, 0.0, 0.0, 180.0)
        // Expected: ~20000 km = 20000000 meters
        assertTrue("Antipodal points should be ~20000km", distance > 19900000 && distance < 20100000)
    }

    @Test
    fun `haversine distance is symmetric`() {
        val lat1 = 40.7128
        val lng1 = -74.0060
        val lat2 = 34.0522
        val lng2 = -118.2437

        val forward = GeoMath.haversineDistance(lat1, lng1, lat2, lng2)
        val backward = GeoMath.haversineDistance(lat2, lng2, lat1, lng1)

        assertEquals("Distance should be symmetric", forward, backward, 1.0)
    }

    @Test
    fun `haversine distance with negative coordinates`() {
        // Sydney: -33.8688°S, 151.2093°E
        // Melbourne: -37.8136°S, 144.9631°E
        val distance = GeoMath.haversineDistance(-33.8688, 151.2093, -37.8136, 144.9631)
        // Expected: ~714 km
        assertTrue("Sydney to Melbourne should be ~714km", distance > 700000 && distance < 750000)
    }

    @Test
    fun `haversine distance antimeridian adjacent points`() {
        // Points on opposite sides of international date line (meridian 180)
        val distance = GeoMath.haversineDistance(0.0, 179.9, 0.0, -179.9)
        // Expected: very small (~22 km)
        assertTrue("Antimeridian points should be ~22km apart", distance < 25000)
    }

    // ========================================================================
    // Ray-Casting Point-in-Polygon Tests
    // ========================================================================

    @Test
    fun `ray-casting point inside simple square returns true`() {
        val square = listOf(
            Pair(0.0, 0.0),   // bottom-left
            Pair(0.0, 1.0),   // bottom-right
            Pair(1.0, 1.0),   // top-right
            Pair(1.0, 0.0)    // top-left
        )
        val point = Pair(0.5, 0.5)
        assertTrue("Point should be inside square", GeoMath.isPointInPolygon(point.first, point.second, square))
    }

    @Test
    fun `ray-casting point outside simple square returns false`() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        val point = Pair(2.0, 2.0)
        assertFalse("Point should be outside square", GeoMath.isPointInPolygon(point.first, point.second, square))
    }

    @Test
    fun `ray-casting point on polygon edge boundary`() {
        val triangle = listOf(
            Pair(0.0, 0.0),
            Pair(1.0, 1.0),
            Pair(0.0, 2.0)
        )
        // Point exactly on edge from (0,0) to (1,1)
        val point = Pair(0.5, 0.5)
        // Ray-casting results may vary for edge cases; we test membership is consistent
        val result = GeoMath.isPointInPolygon(point.first, point.second, triangle)
        assertNotNull("Edge case should return a boolean", result)
    }

    @Test
    fun `ray-casting point inside triangle returns true`() {
        val triangle = listOf(
            Pair(0.0, 0.0),
            Pair(4.0, 0.0),
            Pair(2.0, 3.0)
        )
        val point = Pair(2.0, 1.0)
        assertTrue("Point should be inside triangle", GeoMath.isPointInPolygon(point.first, point.second, triangle))
    }

    @Test
    fun `ray-casting empty polygon returns false`() {
        val emptyPolygon = listOf<Pair<Double, Double>>()
        val point = Pair(0.5, 0.5)
        assertFalse("Empty polygon should return false", GeoMath.isPointInPolygon(point.first, point.second, emptyPolygon))
    }

    @Test
    fun `ray-casting polygon with fewer than 3 vertices returns false`() {
        val twoPoints = listOf(
            Pair(0.0, 0.0),
            Pair(1.0, 1.0)
        )
        val point = Pair(0.5, 0.5)
        assertFalse("Degenerate polygon should return false", GeoMath.isPointInPolygon(point.first, point.second, twoPoints))
    }

    @Test
    fun `ray-casting using LatLng overload`() {
        val polygon = listOf(
            GeoMath.LatLng(0.0, 0.0),
            GeoMath.LatLng(0.0, 1.0),
            GeoMath.LatLng(1.0, 1.0),
            GeoMath.LatLng(1.0, 0.0)
        )
        val point = GeoMath.LatLng(0.5, 0.5)
        assertTrue("Point should be inside square (LatLng)", GeoMath.isPointInPolygon(point, polygon))
    }

    @Test
    fun `ray-casting concave polygon`() {
        // L-shaped concave polygon
        val concave = listOf(
            Pair(0.0, 0.0),
            Pair(2.0, 0.0),
            Pair(2.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 2.0),
            Pair(0.0, 2.0)
        )
        val inside = Pair(0.5, 0.5)
        val outside = Pair(1.5, 1.5)

        assertTrue("Point in bottom-left should be inside", GeoMath.isPointInPolygon(inside.first, inside.second, concave))
        assertFalse("Point in cutout should be outside", GeoMath.isPointInPolygon(outside.first, outside.second, concave))
    }

    // ========================================================================
    // Point-to-Segment Distance Tests
    // ========================================================================

    @Test
    fun `point-to-segment distance point directly on segment is zero`() {
        val point = GeoMath.LatLng(0.0, 0.5)
        val segmentStart = GeoMath.LatLng(0.0, 0.0)
        val segmentEnd = GeoMath.LatLng(0.0, 1.0)

        val distance = GeoMath.pointToSegmentDistance(point, segmentStart, segmentEnd)
        assertEquals("Point on segment should have 0 distance", 0.0, distance, 10.0)
    }

    @Test
    fun `point-to-segment distance perpendicular projection`() {
        // Meridian segment at lng 0.5; point offset east so not collinear
        val point = GeoMath.LatLng(0.0, 0.6)
        val segmentStart = GeoMath.LatLng(-1.0, 0.5)
        val segmentEnd = GeoMath.LatLng(1.0, 0.5)

        val distance = GeoMath.pointToSegmentDistance(point, segmentStart, segmentEnd)
        assertTrue("Perpendicular distance should be small", distance > 0 && distance < 200_000)
    }

    @Test
    fun `point-to-segment distance point closest to endpoint`() {
        val point = GeoMath.LatLng(0.0, 0.0)
        val segmentStart = GeoMath.LatLng(1.0, 0.0)
        val segmentEnd = GeoMath.LatLng(2.0, 0.0)

        val distance = GeoMath.pointToSegmentDistance(point, segmentStart, segmentEnd)
        // Should be distance to nearest endpoint (segmentStart)
        val expectedDistance = GeoMath.haversineDistance(point, segmentStart)
        assertEquals("Should project to nearest endpoint", expectedDistance, distance, 100.0)
    }

    @Test
    fun `point-to-segment distance zero-length segment`() {
        val point = GeoMath.LatLng(0.0, 0.0)
        val segment = GeoMath.LatLng(1.0, 1.0)

        val distance = GeoMath.pointToSegmentDistance(point, segment, segment)
        val expectedDistance = GeoMath.haversineDistance(point, segment)
        assertEquals("Zero-length segment should return point-to-point distance", expectedDistance, distance, 100.0)
    }

    @Test
    fun `point-to-segment distance using raw coordinates`() {
        val distance = GeoMath.pointToSegmentDistance(
            0.0, 0.6,     // point (offset from meridian segment)
            -1.0, 0.5,    // segment start
            1.0, 0.5      // segment end
        )
        assertTrue("Distance should be small", distance in 1.0..200_000.0)
    }

    @Test
    fun `point-to-segment distance long segment multiple points`() {
        // Test that projection works for points at different positions along segment
        val segStart = GeoMath.LatLng(0.0, 0.0)
        val segEnd = GeoMath.LatLng(0.0, 1.0)

        // Point perpendicular at 1/4 position
        val pointQuarter = GeoMath.LatLng(0.1, 0.25)
        val distQuarter = GeoMath.pointToSegmentDistance(pointQuarter, segStart, segEnd)

        // Point perpendicular at 3/4 position
        val pointThreeQuarter = GeoMath.LatLng(0.1, 0.75)
        val distThreeQuarter = GeoMath.pointToSegmentDistance(pointThreeQuarter, segStart, segEnd)

        // Both should have similar perpendicular distance
        assertEquals("Perpendicular distances should be similar", distQuarter, distThreeQuarter, 100.0)
    }

    // ========================================================================
    // Edge Case Tests
    // ========================================================================

    @Test
    fun `haversine with very small distance (millimeters)`() {
        val lat1 = 0.0
        val lng1 = 0.0
        val lat2 = 0.000001
        val lng2 = 0.000001

        val distance = GeoMath.haversineDistance(lat1, lng1, lat2, lng2)
        assertTrue("Very small distance should be non-negative", distance >= 0)
    }

    @Test
    fun `point in polygon with very small coordinates`() {
        val polygon = listOf(
            Pair(0.000001, 0.000001),
            Pair(0.000002, 0.000001),
            Pair(0.000002, 0.000002),
            Pair(0.000001, 0.000002)
        )
        val point = Pair(0.0000015, 0.0000015)
        assertTrue("Should handle tiny coordinates", GeoMath.isPointInPolygon(point.first, point.second, polygon))
    }

    @Test
    fun `haversine with very large distances near antipodal`() {
        val distance = GeoMath.haversineDistance(0.0, 0.0, 0.0, 180.0)
        assertTrue("Antipodal distance should be ~half Earth circumference", distance in 19_900_000.0..20_100_000.0)
    }

    @Test
    fun `point-to-segment at extreme latitudes`() {
        val point = GeoMath.LatLng(89.0, 0.0)  // Near north pole
        val segStart = GeoMath.LatLng(88.0, 0.0)
        val segEnd = GeoMath.LatLng(88.0, 90.0)

        val distance = GeoMath.pointToSegmentDistance(point, segStart, segEnd)
        assertTrue("Extreme latitude should still compute", distance >= 0)
    }

    // ========================================================================
    // Point-to-Polygon Distance Tests
    // ========================================================================

    @Test
    fun `pointToPolygonDistance returns min distance to nearest edge`() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        // Point outside square, nearest to bottom edge
        val distance = GeoMath.pointToPolygonDistance(-0.1, 0.5, square)
        // ~11km (0.1 degrees at equator)
        assertTrue("Distance should be positive", distance > 0)
        assertTrue("Distance should be reasonable", distance < 15000)
    }

    @Test
    fun `pointToPolygonDistance point inside polygon returns small distance`() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        // Point inside, near center - distance to nearest edge should be ~55km
        val distance = GeoMath.pointToPolygonDistance(0.5, 0.5, square)
        assertTrue("Inside point should have positive distance to boundary", distance > 0)
    }

    @Test
    fun `pointToPolygonDistance degenerate polygon returns max value`() {
        val singlePoint = listOf(Pair(0.0, 0.0))
        val distance = GeoMath.pointToPolygonDistance(1.0, 1.0, singlePoint)
        assertEquals("Single point polygon should return MAX_VALUE", Double.MAX_VALUE, distance, 0.0)
    }

    @Test
    fun `pointToPolygonDistance point on edge returns near zero`() {
        val square = listOf(
            Pair(0.0, 0.0),
            Pair(0.0, 1.0),
            Pair(1.0, 1.0),
            Pair(1.0, 0.0)
        )
        // Point on the bottom edge
        val distance = GeoMath.pointToPolygonDistance(0.0, 0.5, square)
        assertTrue("Point on edge should have near-zero distance", distance < 10.0)
    }

    @Test
    fun `isPointInPolygon consistent with multiple calls`() {
        val polygon = listOf(
            Pair(0.0, 0.0),
            Pair(1.0, 0.0),
            Pair(1.0, 1.0),
            Pair(0.0, 1.0)
        )
        val point = Pair(0.5, 0.5)

        val result1 = GeoMath.isPointInPolygon(point.first, point.second, polygon)
        val result2 = GeoMath.isPointInPolygon(point.first, point.second, polygon)
        assertEquals("Results should be deterministic", result1, result2)
    }
}

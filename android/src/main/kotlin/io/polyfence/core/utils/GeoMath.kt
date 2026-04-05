package io.polyfence.core.utils

import kotlin.math.*

/**
 * Centralized geospatial mathematics utility.
 * Single source of truth for geofencing algorithms across the engine.
 * Ensures algorithm parity with iOS implementation.
 *
 * Thread-safe: all functions are pure (no side effects).
 */
internal object GeoMath {
    private const val EARTH_RADIUS_METERS = 6371000.0

    data class LatLng(val latitude: Double, val longitude: Double)

    /**
     * Check if a polygon crosses the antimeridian (±180° longitude).
     * A polygon crosses if any consecutive edge spans >180° longitude difference.
     *
     * @param polygon List of (latitude, longitude) pairs
     * @return true if polygon crosses antimeridian, false otherwise
     */
    private fun crossesAntimeridian(polygon: List<Pair<Double, Double>>): Boolean {
        for (i in polygon.indices) {
            val p1 = polygon[i]
            val p2 = polygon[(i + 1) % polygon.size]
            val lngDiff = Math.abs(p2.second - p1.second)
            if (lngDiff > 180.0) {
                return true
            }
        }
        return false
    }

    /**
     * Normalize longitude from [-180, 180] to [0, 360].
     * Used for antimeridian-crossing polygon handling.
     *
     * @param lng Longitude in [-180, 180]
     * @return Longitude in [0, 360]
     */
    private fun normalizeLongitude(lng: Double): Double {
        return if (lng < 0) lng + 360.0 else lng
    }

    /**
     * Calculate distance between two points using Haversine formula.
     *
     * Reference: Sinnott, R.W. (1984). "Virtues of the Haversine."
     * Sky & Telescope 68(2): 158-159.
     *
     * @param lat1 First point latitude
     * @param lng1 First point longitude
     * @param lat2 Second point latitude
     * @param lng2 Second point longitude
     * @return Distance in meters
     */
    fun haversineDistance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val dLat = Math.toRadians(lat2 - lat1)
        val dLng = Math.toRadians(lng2 - lng1)

        val a = sin(dLat / 2).pow(2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
                sin(dLng / 2).pow(2)

        val c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return EARTH_RADIUS_METERS * c
    }

    /**
     * Convenience overload: calculate distance between two LatLng points.
     */
    fun haversineDistance(point1: LatLng, point2: LatLng): Double {
        return haversineDistance(point1.latitude, point1.longitude, point2.latitude, point2.longitude)
    }

    /**
     * Point-in-polygon detection using ray casting algorithm.
     * Handles antimeridian-crossing polygons by normalizing longitudes.
     *
     * Reference: Shimrat, M. (1962). "Algorithm 112: Position of point relative to polygon."
     * Communications of the ACM 5(8): 434. DOI: 10.1145/368637.368653
     *
     * @param lat Point latitude
     * @param lng Point longitude
     * @param polygon List of polygon vertices as (lat, lng) pairs
     * @return true if point is inside polygon, false otherwise
     */
    fun isPointInPolygon(lat: Double, lng: Double, polygon: List<Pair<Double, Double>>): Boolean {
        if (polygon.isEmpty()) return false

        // Check if polygon crosses antimeridian
        if (crossesAntimeridian(polygon)) {
            // Normalize all longitudes to [0, 360] range
            val normalizedPolygon = polygon.map { (lat, lng) ->
                Pair(lat, normalizeLongitude(lng))
            }
            val normalizedTestLng = normalizeLongitude(lng)
            return isPointInPolygonRaw(lat, normalizedTestLng, normalizedPolygon)
        }

        return isPointInPolygonRaw(lat, lng, polygon)
    }

    /**
     * Raw ray-casting algorithm without antimeridian handling.
     * Internal helper for isPointInPolygon.
     */
    private fun isPointInPolygonRaw(lat: Double, lng: Double, polygon: List<Pair<Double, Double>>): Boolean {
        var intersections = 0
        val x = lng
        val y = lat

        for (i in polygon.indices) {
            val p1 = polygon[i]
            val p2 = polygon[(i + 1) % polygon.size]

            if (((p1.first > y) != (p2.first > y)) &&
                (x < (p2.second - p1.second) * (y - p1.first) / (p2.first - p1.first) + p1.second)) {
                intersections++
            }
        }

        return intersections % 2 == 1
    }

    /**
     * Convenience overload: point-in-polygon with LatLng point and polygon.
     */
    fun isPointInPolygon(point: LatLng, polygon: List<LatLng>): Boolean {
        val pairPolygon = polygon.map { Pair(it.latitude, it.longitude) }
        return isPointInPolygon(point.latitude, point.longitude, pairPolygon)
    }

    /**
     * Distance from a point to a line segment in meters.
     * Uses cosLat-adjusted flat-earth projection for accurate distance calculation.
     * Handles antimeridian-crossing segments by normalizing longitudes.
     * Distance calculation via vector projection (classical geometric method).
     *
     * @param pLat Point latitude
     * @param pLng Point longitude
     * @param aLat Start point latitude
     * @param aLng Start point longitude
     * @param bLat End point latitude
     * @param bLng End point longitude
     * @return Distance in meters
     */
    fun pointToSegmentDistance(
        pLat: Double,
        pLng: Double,
        aLat: Double,
        aLng: Double,
        bLat: Double,
        bLng: Double
    ): Double {
        // Check if segment crosses antimeridian
        val lngDiff = Math.abs(bLng - aLng)
        if (lngDiff > 180.0) {
            // Normalize all longitudes to [0, 360] range
            val normalizedPLng = normalizeLongitude(pLng)
            val normalizedALng = normalizeLongitude(aLng)
            val normalizedBLng = normalizeLongitude(bLng)
            return pointToSegmentDistanceRaw(pLat, normalizedPLng, aLat, normalizedALng, bLat, normalizedBLng)
        }

        return pointToSegmentDistanceRaw(pLat, pLng, aLat, aLng, bLat, bLng)
    }

    /**
     * Raw point-to-segment distance calculation without antimeridian handling.
     * Internal helper for pointToSegmentDistance.
     */
    private fun pointToSegmentDistanceRaw(
        pLat: Double,
        pLng: Double,
        aLat: Double,
        aLng: Double,
        bLat: Double,
        bLng: Double
    ): Double {
        val ab = haversineDistance(aLat, aLng, bLat, bLng)
        if (ab < 0.001) return haversineDistance(pLat, pLng, aLat, aLng)

        // Flat-earth projection for segment math (valid for short segments)
        val cosLat = cos(Math.toRadians((aLat + bLat) / 2))
        val dx = Math.toRadians(bLng - aLng) * cosLat * EARTH_RADIUS_METERS
        val dy = Math.toRadians(bLat - aLat) * EARTH_RADIUS_METERS
        val px = Math.toRadians(pLng - aLng) * cos(Math.toRadians((aLat + pLat) / 2)) * EARTH_RADIUS_METERS
        val py = Math.toRadians(pLat - aLat) * EARTH_RADIUS_METERS

        val abLenSq = dx * dx + dy * dy
        if (abLenSq < 0.001) return haversineDistance(pLat, pLng, aLat, aLng)

        val t = ((px * dx + py * dy) / abLenSq).coerceIn(0.0, 1.0)

        val projLat = aLat + t * (bLat - aLat)
        val projLng = aLng + t * (bLng - aLng)

        return haversineDistance(pLat, pLng, projLat, projLng)
    }

    /**
     * Convenience overload: point-to-segment with LatLng points.
     */
    fun pointToSegmentDistance(p: LatLng, a: LatLng, b: LatLng): Double {
        return pointToSegmentDistance(p.latitude, p.longitude, a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /**
     * Minimum distance from a point to a polygon boundary in meters.
     * Iterates over all edges of the polygon and returns the smallest point-to-segment distance.
     *
     * @param pLat Point latitude
     * @param pLng Point longitude
     * @param polygon List of (latitude, longitude) pairs forming the polygon
     * @return Minimum distance in meters from the point to any polygon edge
     */
    fun pointToPolygonDistance(pLat: Double, pLng: Double, polygon: List<Pair<Double, Double>>): Double {
        if (polygon.size < 2) return Double.MAX_VALUE
        var minDist = Double.MAX_VALUE
        for (i in polygon.indices) {
            val j = (i + 1) % polygon.size
            val dist = pointToSegmentDistance(
                pLat, pLng,
                polygon[i].first, polygon[i].second,
                polygon[j].first, polygon[j].second
            )
            if (dist < minDist) minDist = dist
        }
        return minDist
    }
}

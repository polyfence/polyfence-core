import Foundation
import CoreLocation

/**
 * Centralized geospatial mathematics utility.
 * Single source of truth for geofencing algorithms across the engine.
 * Ensures algorithm parity with Kotlin (Android) implementation.
 *
 * Thread-safe: all methods are pure (no side effects).
 */
internal enum GeoMath {
    private static let EARTH_RADIUS_METERS: Double = 6371000.0

    /**
     * Check if a polygon crosses the antimeridian (±180° longitude).
     * A polygon crosses if any consecutive edge spans >180° longitude difference.
     *
     * - Parameter polygon: List of polygon vertices
     * - Returns: true if polygon crosses antimeridian, false otherwise
     */
    private static func crossesAntimeridian(_ polygon: [CLLocationCoordinate2D]) -> Bool {
        for i in 0..<polygon.count {
            let p1 = polygon[i]
            let p2 = polygon[(i + 1) % polygon.count]
            let lngDiff = abs(p2.longitude - p1.longitude)
            if lngDiff > 180.0 {
                return true
            }
        }
        return false
    }

    /**
     * Normalize longitude from [-180, 180] to [0, 360].
     * Used for antimeridian-crossing polygon handling.
     *
     * - Parameter lng: Longitude in [-180, 180]
     * - Returns: Longitude in [0, 360]
     */
    private static func normalizeLongitude(_ lng: Double) -> Double {
        return lng < 0 ? lng + 360.0 : lng
    }

    /**
     * Calculate distance between two points using Haversine formula.
     *
     * - Parameters:
     *   - point1: First coordinate
     *   - point2: Second coordinate
     * - Returns: Distance in meters
     */
    static func haversineDistance(
        point1: CLLocationCoordinate2D,
        point2: CLLocationCoordinate2D
    ) -> Double {
        return haversineDistance(
            lat1: point1.latitude,
            lng1: point1.longitude,
            lat2: point2.latitude,
            lng2: point2.longitude
        )
    }

    /**
     * Calculate distance between two points using Haversine formula.
     *
     * - Parameters:
     *   - lat1: First point latitude
     *   - lng1: First point longitude
     *   - lat2: Second point latitude
     *   - lng2: Second point longitude
     * - Returns: Distance in meters
     */
    static func haversineDistance(
        lat1: Double,
        lng1: Double,
        lat2: Double,
        lng2: Double
    ) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLng / 2) * sin(dLng / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return EARTH_RADIUS_METERS * c
    }

    /**
     * Point-in-polygon detection using ray casting algorithm.
     * Handles antimeridian-crossing polygons by normalizing longitudes.
     *
     * - Parameters:
     *   - point: Point coordinate
     *   - polygon: List of polygon vertices
     * - Returns: true if point is inside polygon, false otherwise
     */
    static func isPointInPolygon(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard !polygon.isEmpty else { return false }

        // Check if polygon crosses antimeridian
        if crossesAntimeridian(polygon) {
            // Normalize all longitudes to [0, 360] range
            let normalizedPolygon = polygon.map { coord -> CLLocationCoordinate2D in
                return CLLocationCoordinate2D(latitude: coord.latitude, longitude: normalizeLongitude(coord.longitude))
            }
            let normalizedPoint = CLLocationCoordinate2D(latitude: point.latitude, longitude: normalizeLongitude(point.longitude))
            return isPointInPolygonRaw(point: normalizedPoint, polygon: normalizedPolygon)
        }

        return isPointInPolygonRaw(point: point, polygon: polygon)
    }

    /**
     * Raw ray-casting algorithm without antimeridian handling.
     * Internal helper for isPointInPolygon.
     */
    private static func isPointInPolygonRaw(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        var intersections = 0
        let x = point.longitude
        let y = point.latitude

        for i in 0..<polygon.count {
            let p1 = polygon[i]
            let p2 = polygon[(i + 1) % polygon.count]

            if (((p1.latitude > y) != (p2.latitude > y)) &&
                (x < (p2.longitude - p1.longitude) * (y - p1.latitude) / (p2.latitude - p1.latitude) + p1.longitude)) {
                intersections += 1
            }
        }

        return intersections % 2 == 1
    }

    /**
     * Distance from a point to a line segment in meters.
     * Uses cosLat-adjusted flat-earth projection for accurate distance calculation.
     * Handles antimeridian-crossing segments by normalizing longitudes.
     *
     * - Parameters:
     *   - p: Point coordinate
     *   - a: Start point coordinate
     *   - b: End point coordinate
     * - Returns: Distance in meters
     */
    static func pointToSegmentDistance(
        p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        // Check if segment crosses antimeridian
        let lngDiff = abs(b.longitude - a.longitude)
        if lngDiff > 180.0 {
            // Normalize all longitudes to [0, 360] range
            let normalizedP = CLLocationCoordinate2D(latitude: p.latitude, longitude: normalizeLongitude(p.longitude))
            let normalizedA = CLLocationCoordinate2D(latitude: a.latitude, longitude: normalizeLongitude(a.longitude))
            let normalizedB = CLLocationCoordinate2D(latitude: b.latitude, longitude: normalizeLongitude(b.longitude))
            return pointToSegmentDistanceRaw(p: normalizedP, a: normalizedA, b: normalizedB)
        }

        return pointToSegmentDistanceRaw(p: p, a: a, b: b)
    }

    /**
     * Raw point-to-segment distance calculation without antimeridian handling.
     * Internal helper for pointToSegmentDistance.
     */
    private static func pointToSegmentDistanceRaw(
        p: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        let ab = haversineDistance(point1: a, point2: b)
        if ab < 0.001 { return haversineDistance(point1: p, point2: a) }

        // Flat-earth projection for segment math (valid for short segments)
        let cosLat = cos((a.latitude + b.latitude) / 2.0 * .pi / 180.0)
        let dx = (b.longitude - a.longitude) * .pi / 180.0 * cosLat * EARTH_RADIUS_METERS
        let dy = (b.latitude - a.latitude) * .pi / 180.0 * EARTH_RADIUS_METERS
        let px = (p.longitude - a.longitude) * .pi / 180.0 * cos((a.latitude + p.latitude) / 2.0 * .pi / 180.0) * EARTH_RADIUS_METERS
        let py = (p.latitude - a.latitude) * .pi / 180.0 * EARTH_RADIUS_METERS

        let abLenSq = dx * dx + dy * dy
        if abLenSq < 0.001 { return haversineDistance(point1: p, point2: a) }

        let t = max(0.0, min(1.0, (px * dx + py * dy) / abLenSq))
        let projLat = a.latitude + t * (b.latitude - a.latitude)
        let projLng = a.longitude + t * (b.longitude - a.longitude)

        return haversineDistance(
            lat1: p.latitude,
            lng1: p.longitude,
            lat2: projLat,
            lng2: projLng
        )
    }
}

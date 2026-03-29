import XCTest
import CoreLocation
@testable import PolyfenceCore

class GeoMathTests: XCTestCase {

    // MARK: - Haversine Distance Tests

    func testHaversineDistanceBetweenIdenticalPointsIsZero() {
        let p1 = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        let p2 = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

        let distance = GeoMath.haversineDistance(point1: p1, point2: p2)

        XCTAssertEqual(distance, 0.0, accuracy: 0.1, "Same point should have 0 distance")
    }

    func testHaversineDistanceLondonToParisApproximately343km() {
        // London: 51.5074°N, -0.1278°W
        // Paris: 48.8566°N, 2.3522°E
        let distance = GeoMath.haversineDistance(
            lat1: 51.5074,
            lng1: -0.1278,
            lat2: 48.8566,
            lng2: 2.3522
        )

        // Expected: ~343 km = 343000 meters
        XCTAssertGreaterThan(distance, 340000, "London to Paris should be ~343km")
        XCTAssertLessThan(distance, 345000, "London to Paris should be ~343km")
    }

    func testHaversineDistanceSymmetric() {
        let lat1 = 40.7128
        let lng1 = -74.0060
        let lat2 = 34.0522
        let lng2 = -118.2437

        let forward = GeoMath.haversineDistance(lat1: lat1, lng1: lng1, lat2: lat2, lng2: lng2)
        let backward = GeoMath.haversineDistance(lat1: lat2, lng1: lng2, lat2: lat1, lng2: lng1)

        XCTAssertEqual(forward, backward, accuracy: 1.0, "Distance should be symmetric")
    }

    func testHaversineDistanceWithNegativeCoordinates() {
        // Sydney: -33.8688°S, 151.2093°E
        // Melbourne: -37.8136°S, 144.9631°E
        let distance = GeoMath.haversineDistance(
            lat1: -33.8688,
            lng1: 151.2093,
            lat2: -37.8136,
            lng2: 144.9631
        )

        // Expected: ~714 km
        XCTAssertGreaterThan(distance, 700000, "Sydney to Melbourne should be ~714km")
        XCTAssertLessThan(distance, 750000, "Sydney to Melbourne should be ~714km")
    }

    func testHaversineDistanceAntimerianAdjacentPoints() {
        // Points on opposite sides of international date line (meridian 180)
        let distance = GeoMath.haversineDistance(
            lat1: 0.0,
            lng1: 179.9,
            lat2: 0.0,
            lng2: -179.9
        )

        // Expected: very small (~22 km)
        XCTAssertLessThan(distance, 25000, "Antimeridian points should be ~22km apart")
    }

    func testHaversineDistanceAntipodal() {
        let distance = GeoMath.haversineDistance(lat1: 0.0, lng1: 0.0, lat2: 0.0, lng2: 180.0)

        // Expected: ~20000 km = 20000000 meters
        XCTAssertGreaterThan(distance, 19900000, "Antipodal points should be ~20000km")
        XCTAssertLessThan(distance, 20100000, "Antipodal points should be ~20000km")
    }

    // MARK: - Ray-Casting Point-in-Polygon Tests

    func testRayCastingPointInsideSimpleSquareReturnsTrue() {
        let square = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),   // bottom-left
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0),   // bottom-right
            CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0),   // top-right
            CLLocationCoordinate2D(latitude: 1.0, longitude: 0.0)    // top-left
        ]
        let point = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)

        let result = GeoMath.isPointInPolygon(point: point, polygon: square)

        XCTAssertTrue(result, "Point should be inside square")
    }

    func testRayCastingPointOutsideSimpleSquareReturnsFalse() {
        let square = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 0.0)
        ]
        let point = CLLocationCoordinate2D(latitude: 2.0, longitude: 2.0)

        let result = GeoMath.isPointInPolygon(point: point, polygon: square)

        XCTAssertFalse(result, "Point should be outside square")
    }

    func testRayCastingPointInsideTriangle() {
        let triangle = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 4.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 2.0, longitude: 3.0)
        ]
        let point = CLLocationCoordinate2D(latitude: 2.0, longitude: 1.0)

        let result = GeoMath.isPointInPolygon(point: point, polygon: triangle)

        XCTAssertTrue(result, "Point should be inside triangle")
    }

    func testRayCastingEmptyPolygonReturnsFalse() {
        let emptyPolygon: [CLLocationCoordinate2D] = []
        let point = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)

        let result = GeoMath.isPointInPolygon(point: point, polygon: emptyPolygon)

        XCTAssertFalse(result, "Empty polygon should return false")
    }

    func testRayCastingPolygonWithFewerThanThreeVertices() {
        let twoPoints = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0)
        ]
        let point = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)

        let result = GeoMath.isPointInPolygon(point: point, polygon: twoPoints)

        XCTAssertFalse(result, "Degenerate polygon should return false")
    }

    func testRayCastingConcavePolygon() {
        // L-shaped concave polygon
        let concave = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 2.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 2.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 2.0)
        ]
        let inside = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)
        let outside = CLLocationCoordinate2D(latitude: 1.5, longitude: 1.5)

        let resultInside = GeoMath.isPointInPolygon(point: inside, polygon: concave)
        let resultOutside = GeoMath.isPointInPolygon(point: outside, polygon: concave)

        XCTAssertTrue(resultInside, "Point in bottom-left should be inside")
        XCTAssertFalse(resultOutside, "Point in cutout should be outside")
    }

    // MARK: - Point-to-Segment Distance Tests

    func testPointToSegmentDistancePointDirectlyOnSegmentIsZero() {
        let point = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.5)
        let segmentStart = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let segmentEnd = CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0)

        let distance = GeoMath.pointToSegmentDistance(p: point, a: segmentStart, b: segmentEnd)

        XCTAssertEqual(distance, 0.0, accuracy: 10.0, "Point on segment should have 0 distance")
    }

    func testPointToSegmentDistancePerpendicularProjection() {
        // Point offset perpendicular to a horizontal segment
        let point = CLLocationCoordinate2D(latitude: 0.1, longitude: 0.5)
        let segmentStart = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let segmentEnd = CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0)

        let distance = GeoMath.pointToSegmentDistance(p: point, a: segmentStart, b: segmentEnd)

        XCTAssertGreaterThan(distance, 0, "Perpendicular distance should be non-zero")
        XCTAssertLessThan(distance, 20000, "Perpendicular distance should be small")
    }

    func testPointToSegmentDistanceClosestToEndpoint() {
        let point = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let segmentStart = CLLocationCoordinate2D(latitude: 1.0, longitude: 0.0)
        let segmentEnd = CLLocationCoordinate2D(latitude: 2.0, longitude: 0.0)

        let distance = GeoMath.pointToSegmentDistance(p: point, a: segmentStart, b: segmentEnd)
        let expectedDistance = GeoMath.haversineDistance(point1: point, point2: segmentStart)

        XCTAssertEqual(distance, expectedDistance, accuracy: 100.0, "Should project to nearest endpoint")
    }

    func testPointToSegmentDistanceZeroLengthSegment() {
        let point = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let segment = CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0)

        let distance = GeoMath.pointToSegmentDistance(p: point, a: segment, b: segment)
        let expectedDistance = GeoMath.haversineDistance(point1: point, point2: segment)

        XCTAssertEqual(distance, expectedDistance, accuracy: 100.0, "Zero-length segment should return point-to-point distance")
    }

    func testPointToSegmentDistanceLongSegmentMultiplePoints() {
        let segStart = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let segEnd = CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0)

        // Point perpendicular at 1/4 position
        let pointQuarter = CLLocationCoordinate2D(latitude: 0.1, longitude: 0.25)
        let distQuarter = GeoMath.pointToSegmentDistance(p: pointQuarter, a: segStart, b: segEnd)

        // Point perpendicular at 3/4 position
        let pointThreeQuarter = CLLocationCoordinate2D(latitude: 0.1, longitude: 0.75)
        let distThreeQuarter = GeoMath.pointToSegmentDistance(p: pointThreeQuarter, a: segStart, b: segEnd)

        XCTAssertEqual(distQuarter, distThreeQuarter, accuracy: 100.0, "Perpendicular distances should be similar")
    }

    // MARK: - Edge Case Tests

    func testHaversineWithVerySmallDistance() {
        let lat1 = 0.0
        let lng1 = 0.0
        let lat2 = 0.000001
        let lng2 = 0.000001

        let distance = GeoMath.haversineDistance(lat1: lat1, lng1: lng1, lat2: lat2, lng2: lng2)

        XCTAssertGreaterThanOrEqual(distance, 0, "Very small distance should be non-negative")
    }

    func testPointInPolygonWithVerySmallCoordinates() {
        let polygon = [
            CLLocationCoordinate2D(latitude: 0.000001, longitude: 0.000001),
            CLLocationCoordinate2D(latitude: 0.000002, longitude: 0.000001),
            CLLocationCoordinate2D(latitude: 0.000002, longitude: 0.000002),
            CLLocationCoordinate2D(latitude: 0.000001, longitude: 0.000002)
        ]
        let point = CLLocationCoordinate2D(latitude: 0.0000015, longitude: 0.0000015)

        let result = GeoMath.isPointInPolygon(point: point, polygon: polygon)

        XCTAssertTrue(result, "Should handle tiny coordinates")
    }

    func testHaversineWithVeryLargeDistanceNearAntipodal() {
        // Near-antipodal: (0°,0°) to (0.001°,180°) ≈ half Earth circumference
        let distance = GeoMath.haversineDistance(lat1: 0.0, lng1: 0.0, lat2: 0.001, lng2: 180.0)

        XCTAssertGreaterThan(distance, 19900000, "Near-antipodal distance should be large")
    }

    func testPointToSegmentAtExtremeLatitudes() {
        let point = CLLocationCoordinate2D(latitude: 89.0, longitude: 0.0)  // Near north pole
        let segStart = CLLocationCoordinate2D(latitude: 88.0, longitude: 0.0)
        let segEnd = CLLocationCoordinate2D(latitude: 88.0, longitude: 90.0)

        let distance = GeoMath.pointToSegmentDistance(p: point, a: segStart, b: segEnd)

        XCTAssertGreaterThanOrEqual(distance, 0, "Extreme latitude should still compute")
    }

    func testIsPointInPolygonConsistentWithMultipleCalls() {
        let polygon = [
            CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 1.0, longitude: 1.0),
            CLLocationCoordinate2D(latitude: 0.0, longitude: 1.0)
        ]
        let point = CLLocationCoordinate2D(latitude: 0.5, longitude: 0.5)

        let result1 = GeoMath.isPointInPolygon(point: point, polygon: polygon)
        let result2 = GeoMath.isPointInPolygon(point: point, polygon: polygon)

        XCTAssertEqual(result1, result2, "Results should be deterministic")
    }
}

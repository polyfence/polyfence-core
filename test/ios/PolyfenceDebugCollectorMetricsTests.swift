import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * Coverage for the counters and zone figures behind `debugInfo()`.
 *
 * `PolyfenceDebugCollector.shared` is a process-wide singleton whose
 * counters accumulate for the lifetime of the test process, so every
 * assertion here is written against the delta across an action rather than
 * against an absolute value.
 *
 * `collectDebugInfo()` doubles as the barrier for the recording methods:
 * they enqueue onto the collector's serial queue and the collect path takes
 * that same queue synchronously, so anything recorded before a collect is
 * visible in its result.
 */
class PolyfenceDebugCollectorMetricsTests: XCTestCase {

    /// Held strongly for the duration of a test — the collector references
    /// the tracker's engine weakly and would otherwise report no zones.
    private var tracker: LocationTracker!

    override func setUp() {
        super.setUp()
        tracker = LocationTracker()
        tracker.clearAllZones()
    }

    override func tearDown() {
        tracker.clearAllZones()
        tracker = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func performance() -> [String: Any] {
        return PolyfenceDebugCollector.shared.collectDebugInfo()["performance"] as! [String: Any]
    }

    private func systemStatus() -> [String: Any] {
        return PolyfenceDebugCollector.shared.collectDebugInfo()["systemStatus"] as! [String: Any]
    }

    private func zones() -> [String: Any] {
        return PolyfenceDebugCollector.shared.collectDebugInfo()["zones"] as! [String: Any]
    }

    private func locationUpdateCount() -> Int {
        return performance()["totalLocationUpdates"] as! Int
    }

    /// Samples behind the mean — not every crossing is timed, so this is the
    /// count the average is over.
    private func timedCount() -> Int {
        return performance()["timedZoneDetections"] as? Int ?? 0
    }

    private func detectionCount() -> Int {
        return performance()["totalZoneDetections"] as! Int
    }

    /// Absent until a crossing has been detected, so no samples reads as 0.
    private func averageLatency() -> Double {
        return performance()["averageDetectionLatency"] as? Double ?? 0.0
    }

    private func circleZone(
        lat: Double = 40.7128,
        lng: Double = -74.0060,
        radius: Double = 100.0
    ) -> [String: Any] {
        return [
            "type": "circle",
            "center": ["latitude": lat, "longitude": lng],
            "radius": radius
        ]
    }

    private func polygonZone() -> [String: Any] {
        return [
            "type": "polygon",
            "polygon": [
                ["latitude": 0.0, "longitude": 0.0],
                ["latitude": 1.0, "longitude": 0.0],
                ["latitude": 1.0, "longitude": 1.0],
                ["latitude": 0.0, "longitude": 1.0]
            ]
        ]
    }

    // MARK: - Location updates

    func testRecordLocationUpdateAdvancesTheUpdateCount() {
        let before = locationUpdateCount()

        PolyfenceDebugCollector.shared.recordLocationUpdate(accuracy: 12.5)
        PolyfenceDebugCollector.shared.recordLocationUpdate(accuracy: 8.0)

        XCTAssertEqual(locationUpdateCount(), before + 2)
    }

    func testRecordLocationUpdatePublishesTheAccuracyAndStampsTheTime() {
        let before = (systemStatus()["lastLocationUpdate"] as! Double)

        PolyfenceDebugCollector.shared.recordLocationUpdate(accuracy: 37.25)

        let status = systemStatus()
        XCTAssertEqual(status["lastKnownAccuracy"] as! Double, 37.25, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(status["lastLocationUpdate"] as! Double, before)
    }

    func testALocationFixReachesTheCollectorThroughTheTracker() {
        let before = locationUpdateCount()

        tracker.startTracking()
        tracker.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
                    altitude: 0,
                    horizontalAccuracy: 9.0,
                    verticalAccuracy: 9.0,
                    timestamp: Date()
                )
            ]
        )
        tracker.stopTracking()

        XCTAssertEqual(locationUpdateCount(), before + 1)
        XCTAssertEqual(systemStatus()["lastKnownAccuracy"] as! Double, 9.0, accuracy: 0.0001)
    }

    // MARK: - Zone detections

    func testRecordZoneDetectionAdvancesTheDetectionCount() {
        let before = detectionCount()

        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 4.0)
        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 6.0)
        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 8.0)

        XCTAssertEqual(detectionCount(), before + 3)
    }

    func testAverageDetectionLatencyIsTheMeanOfEverySampleRecorded() {
        let countBefore = detectionCount()
        let timedCountBefore = timedCount()
        let sumBefore = averageLatency() * Double(timedCountBefore)

        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 10.0)
        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 20.0)

        let expected = (sumBefore + 30.0) / Double(timedCountBefore + 2)
        XCTAssertEqual(averageLatency(), expected, accuracy: 0.0001)
    }

    /// A degraded-GPS exit is a crossing the consumer receives, but the
    /// engine synthesises it outside a timed evaluation. It must still be
    /// counted — under-reporting real crossings is worse than a thinner
    /// latency sample — while staying out of the mean, which would otherwise
    /// be dragged toward a speed nothing achieved.
    func testAnUntimedCrossingCountsButDoesNotEnterTheAverage() {
        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 10.0)
        let countBefore = detectionCount()
        let averageBefore = averageLatency()

        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: nil)

        XCTAssertEqual(detectionCount(), countBefore + 1)
        XCTAssertEqual(averageLatency(), averageBefore, accuracy: 0.0001)
    }

    func testSubMillisecondLatencyContributesToTheAverage() {
        let countBefore = detectionCount()
        let timedCountBefore = timedCount()
        let sumBefore = averageLatency() * Double(timedCountBefore)

        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 0.4)
        PolyfenceDebugCollector.shared.recordZoneDetection(latencyMs: 0.4)

        let sumAfter = averageLatency() * Double(timedCount())
        XCTAssertEqual(sumAfter - sumBefore, 0.8, accuracy: 0.0001)
    }

    func testAZoneCrossingReachesTheCollectorThroughTheTracker() {
        let countBefore = detectionCount()
        let timedCountBefore = timedCount()
        let sumBefore = averageLatency() * Double(timedCountBefore)

        let crossed = expectation(description: "geofence event delivered")
        tracker.setGeofenceCallback { _ in crossed.fulfill() }

        tracker.startTracking()
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
                    altitude: 0,
                    horizontalAccuracy: 5.0,
                    verticalAccuracy: 5.0,
                    timestamp: Date()
                )
            ]
        )
        wait(for: [crossed], timeout: 5.0)
        tracker.stopTracking()

        XCTAssertGreaterThan(detectionCount(), countBefore)
        let sumAfter = averageLatency() * Double(timedCount())
        XCTAssertGreaterThan(sumAfter, sumBefore, "the crossing must contribute a measured latency")
    }

    // MARK: - Zone status

    func testZoneCountsComeFromTheRunningEngine() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.addZone(zoneId: "square", zoneName: "Square", zoneData: polygonZone())

        let status = zones()
        XCTAssertEqual(status["activeZones"] as! Int, 2)
        XCTAssertEqual(status["circleZones"] as! Int, 1)
        XCTAssertEqual(status["polygonZones"] as! Int, 1)
    }

    func testZoneCountsFollowRemovals() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.addZone(zoneId: "gym", zoneName: "Gym", zoneData: circleZone(lat: 40.75))
        XCTAssertEqual(zones()["activeZones"] as! Int, 2)

        tracker.removeZone(zoneId: "gym")
        XCTAssertEqual(zones()["activeZones"] as! Int, 1)

        tracker.clearAllZones()
        XCTAssertEqual(zones()["activeZones"] as! Int, 0)
    }
}

import XCTest
@testable import PolyfenceCore

class TelemetryAggregatorTests: XCTestCase {

    var aggregator: TelemetryAggregator!

    override func setUp() {
        super.setUp()
        aggregator = TelemetryAggregator()
        aggregator.resetTelemetry()
    }

    // MARK: - Activity Distribution

    func testActivityDistributionSumsToApproximatelyOne() {
        aggregator.recordActivityChange(activityType: "still")
        Thread.sleep(forTimeInterval: 0.05)
        aggregator.recordActivityChange(activityType: "walking")
        Thread.sleep(forTimeInterval: 0.05)
        aggregator.recordActivityChange(activityType: "driving")
        Thread.sleep(forTimeInterval: 0.05)
        aggregator.finalizeActivityTracking()

        let telemetry = aggregator.getSessionTelemetry()
        if let distribution = telemetry["activity_distribution"] as? [String: Double],
           !distribution.isEmpty {
            let sum = distribution.values.reduce(0, +)
            XCTAssertEqual(sum, 1.0, accuracy: 0.01,
                "Activity distribution should sum to ~1.0, got \(sum)")
        }
    }

    // MARK: - False Event Counting

    func testFalseEventCountingWith30sWindow() {
        // ENTER followed by EXIT within 30s = false event
        aggregator.recordGeofenceEvent(
            zoneId: "zone1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.5
        )
        aggregator.recordGeofenceEvent(
            zoneId: "zone1", eventType: "EXIT",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.0
        )

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["false_event_count"] as? Int, 1,
            "Should detect 1 false event")
    }

    func testSameEventTypeDoesNotCountAsFalse() {
        aggregator.recordGeofenceEvent(
            zoneId: "zone1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.5
        )
        aggregator.recordGeofenceEvent(
            zoneId: "zone1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.0
        )

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["false_event_count"] as? Int, 0)
    }

    func testDifferentZonesDoNotCountAsFalseEvents() {
        aggregator.recordGeofenceEvent(
            zoneId: "zone1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.5
        )
        aggregator.recordGeofenceEvent(
            zoneId: "zone2", eventType: "EXIT",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.0
        )

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["false_event_count"] as? Int, 0)
    }

    // MARK: - GPS Interval Histogram

    func testGpsIntervalHistogramTracksIntervals() {
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 10.0)
        Thread.sleep(forTimeInterval: 0.03)
        aggregator.recordGpsUpdate(intervalMs: 10000, accuracyM: 15.0)
        Thread.sleep(forTimeInterval: 0.03)
        aggregator.recordGpsUpdate(intervalMs: 30000, accuracyM: 20.0)
        Thread.sleep(forTimeInterval: 0.03)

        let telemetry = aggregator.getSessionTelemetry()
        if let distribution = telemetry["gps_interval_distribution"] as? [String: Double],
           !distribution.isEmpty {
            let sum = distribution.values.reduce(0, +)
            XCTAssertEqual(sum, 1.0, accuracy: 0.01,
                "GPS interval distribution should sum to ~1.0")
        }
    }

    func testAverageGpsIntervalComputedCorrectly() {
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 10.0)
        aggregator.recordGpsUpdate(intervalMs: 15000, accuracyM: 10.0)

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["avg_gps_interval_ms"] as? Int, 10000)
    }

    // MARK: - All Expected Keys

    func testGetSessionTelemetryReturnsAllExpectedKeys() {
        aggregator.setConfig(accuracyProfile: "balanced", updateStrategy: "intelligent")
        aggregator.setDeviceInfo(category: "iphone_standard", osVersion: 17)
        aggregator.setBatteryInfo(startPercent: 85.0, endPercent: 72.0, chargingDuring: false)

        aggregator.recordActivityChange(activityType: "walking")
        aggregator.recordGpsUpdate(intervalMs: 10000, accuracyM: 15.0)
        aggregator.recordGeofenceEvent(
            zoneId: "z1", eventType: "ENTER",
            distanceM: 25.0, speedMps: 1.2, accuracyM: 15.0, detectionTimeMs: 3.0
        )
        aggregator.recordDwellComplete(durationMinutes: 12.5)

        let telemetry = aggregator.getSessionTelemetry()

        let expectedKeys = [
            "detections_total", "detection_time_avg_ms", "detection_time_p95_ms",
            "gps_accuracy_avg_m", "session_duration_minutes", "error_counts",
            "ttfd_ms", "had_detection", "gps_ok_ratio", "sample_events",
            "accuracy_profile", "update_strategy", "stationary_ratio",
            "avg_gps_interval_ms", "false_event_count", "false_event_ratio",
            "avg_gps_accuracy_at_event", "avg_speed_at_event_mps",
            "boundary_events_count", "zone_count", "zone_transition_count",
            "avg_dwell_duration_minutes", "device_category", "os_version_major",
            "charging_during_session"
        ]

        for key in expectedKeys {
            XCTAssertNotNil(telemetry[key], "Missing expected key: \(key)")
        }

        XCTAssertEqual(telemetry["detections_total"] as? Int, 1)
        XCTAssertEqual(telemetry["accuracy_profile"] as? String, "balanced")
        XCTAssertEqual(telemetry["update_strategy"] as? String, "intelligent")
        XCTAssertEqual(telemetry["device_category"] as? String, "iphone_standard")
        XCTAssertEqual(telemetry["os_version_major"] as? Int, 17)
        XCTAssertEqual(telemetry["charging_during_session"] as? Bool, false)
        XCTAssertEqual(telemetry["had_detection"] as? Bool, true)
    }

    // MARK: - Reset

    func testResetTelemetryClearsState() {
        aggregator.recordActivityChange(activityType: "walking")
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 10.0)
        aggregator.recordGeofenceEvent(
            zoneId: "z1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.5, accuracyM: 15.0, detectionTimeMs: 2.5
        )
        aggregator.recordError(errorType: "gps_timeout")

        aggregator.resetTelemetry()

        let telemetry = aggregator.getSessionTelemetry()

        XCTAssertEqual(telemetry["detections_total"] as? Int, 0)
        XCTAssertEqual(telemetry["false_event_count"] as? Int, 0)
        XCTAssertEqual(telemetry["zone_transition_count"] as? Int, 0)
        XCTAssertEqual(telemetry["boundary_events_count"] as? Int, 0)
        XCTAssertEqual(telemetry["sample_events"] as? Int, 0)
        XCTAssertEqual(telemetry["had_detection"] as? Bool, false)
    }

    // MARK: - Boundary Events

    func testBoundaryEventsCountedWhenDistanceLessThan50m() {
        aggregator.recordGeofenceEvent(
            zoneId: "z1", eventType: "ENTER",
            distanceM: 30.0, speedMps: 1.0, accuracyM: 10.0, detectionTimeMs: 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId: "z2", eventType: "ENTER",
            distanceM: 100.0, speedMps: 5.0, accuracyM: 20.0, detectionTimeMs: 3.0
        )
        aggregator.recordGeofenceEvent(
            zoneId: "z3", eventType: "EXIT",
            distanceM: 10.0, speedMps: 2.0, accuracyM: 12.0, detectionTimeMs: 1.5
        )

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["boundary_events_count"] as? Int, 2)
    }

    // MARK: - False Event Ratio

    func testFalseEventRatioComputedCorrectly() {
        aggregator.recordGeofenceEvent(
            zoneId: "z1", eventType: "ENTER",
            distanceM: 10.0, speedMps: 1.0, accuracyM: 10.0, detectionTimeMs: 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId: "z1", eventType: "EXIT",
            distanceM: 10.0, speedMps: 1.0, accuracyM: 10.0, detectionTimeMs: 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId: "z2", eventType: "ENTER",
            distanceM: 100.0, speedMps: 5.0, accuracyM: 20.0, detectionTimeMs: 3.0
        )
        aggregator.recordGeofenceEvent(
            zoneId: "z3", eventType: "ENTER",
            distanceM: 200.0, speedMps: 10.0, accuracyM: 25.0, detectionTimeMs: 4.0
        )

        let telemetry = aggregator.getSessionTelemetry()
        let ratio = telemetry["false_event_ratio"] as! Double
        XCTAssertEqual(ratio, 0.25, accuracy: 0.01, "False event ratio should be 0.25 (1/4)")
    }

    // MARK: - GPS Health

    func testGpsOkRatioTracksGoodVsBadReadings() {
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 10.0)   // good
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 50.0)   // good
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 150.0)  // bad
        aggregator.recordGpsUpdate(intervalMs: 5000, accuracyM: 200.0)  // bad

        let telemetry = aggregator.getSessionTelemetry()
        let ratio = telemetry["gps_ok_ratio"] as! Double
        XCTAssertEqual(ratio, 0.5, accuracy: 0.01)
    }

    // MARK: - Dwell Duration

    func testAverageDwellMinutesComputedCorrectly() {
        aggregator.recordDwellComplete(durationMinutes: 10.0)
        aggregator.recordDwellComplete(durationMinutes: 20.0)
        aggregator.recordDwellComplete(durationMinutes: 30.0)

        let telemetry = aggregator.getSessionTelemetry()
        XCTAssertEqual(telemetry["avg_dwell_duration_minutes"] as! Double, 20.0, accuracy: 0.01)
    }
}

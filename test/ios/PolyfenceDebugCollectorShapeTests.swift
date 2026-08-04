import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * The exact set of keys `collectDebugInfo()` returns, pinned.
 *
 * Consumers read this payload through typed classes on both bridges, so a key
 * that appears or disappears without the bridges moving with it is a silent
 * break: a removed key reads as its type's default, which is indistinguishable
 * from a genuine zero. Asserting the whole set rather than individual fields
 * means a rename, an accidental deletion and a well-meaning addition all fail
 * here first.
 *
 * A field belongs in this payload only if it carries a real measurement.
 * Anything that cannot be measured on a platform is absent there rather than
 * present with a filler value — see the nil assertions below.
 */
final class PolyfenceDebugCollectorShapeTests: XCTestCase {

    private func debugInfo() -> [String: Any] {
        return PolyfenceDebugCollector.shared.collectDebugInfo()
    }

    private func keys(_ section: String) -> Set<String> {
        guard let group = debugInfo()[section] as? [String: Any] else {
            XCTFail("missing section: \(section)")
            return []
        }
        return Set(group.keys)
    }

    func testTopLevelSectionsAreStable() {
        XCTAssertEqual(
            Set(debugInfo().keys),
            ["systemStatus", "performance", "battery", "zones", "recentErrors"]
        )
    }

    func testSystemStatusKeysAreStable() {
        XCTAssertEqual(keys("systemStatus"), [
            "isLocationPermissionGranted",
            "isBackgroundLocationEnabled",
            "isBatteryOptimizationDisabled",
            "isGpsEnabled",
            "isWakeLockAcquired",
            "lastKnownAccuracy",
            "lastLocationUpdate",
            "platformVersion",
            "pluginVersion",
            "osGeofenceRegistrationHealth",
        ])
    }

    func testPerformanceKeysAreStable() {
        XCTAssertEqual(keys("performance"), [
            "uptime",
            "totalLocationUpdates",
            "totalZoneDetections",
            "averageDetectionLatency",
            "memoryUsageMB",
            "restartCount",
        ])
    }

    func testBatteryKeysAreStable() {
        XCTAssertEqual(keys("battery"), [
            "isCharging",
            "batteryLevel",
            "totalActiveTime",
        ])
    }

    func testZoneKeysAreStable() {
        XCTAssertEqual(keys("zones"), [
            "activeZones",
            "circleZones",
            "polygonZones",
        ])
    }

    /**
     * A platform that cannot measure something reports nothing for it. The
     * distinction matters to a consumer: `false` is a statement about a
     * mechanism, and these mechanisms do not exist on iOS. Android returns
     * real values for all three.
     */
    func testFieldsWithNoIosEquivalentAreNull() {
        let status = debugInfo()["systemStatus"] as? [String: Any]
        XCTAssertTrue(status?["isBatteryOptimizationDisabled"] is NSNull)
        XCTAssertTrue(status?["isWakeLockAcquired"] is NSNull)

        let performance = debugInfo()["performance"] as? [String: Any]
        XCTAssertTrue(performance?["restartCount"] is NSNull)
    }

    /**
     * The Simulator has no battery and iOS reports an unpopulated level as a
     * negative number, so the raw value scaled to a percentage yields -100.
     * Absent is the only honest answer; a substituted figure would report a
     * charge the device never had.
     */
    func testBatteryLevelIsNullRatherThanNegativeWhenUnavailable() {
        guard let battery = debugInfo()["battery"] as? [String: Any] else {
            return XCTFail("missing battery section")
        }
        if let level = battery["batteryLevel"] as? Int {
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(level, 100)
        } else {
            XCTAssertTrue(battery["batteryLevel"] is NSNull)
        }
    }
}

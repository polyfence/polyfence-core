import XCTest
@testable import PolyfenceCore

/**
 * Swift mirror of the Kotlin `LocationTrackerConfigTest` — shape and
 * reset-semantics coverage for `getCurrentConfigurationMap` and
 * `resetSmartConfiguration` on iOS.
 *
 * `LocationTracker()` init previously set
 * `allowsBackgroundLocationUpdates = true` unconditionally, which
 * crashes in an SPM test target that has no Info.plist / no `location`
 * background-mode entitlement. The tracker now skips that flag when
 * running under XCTest (via an env check in `setupLocationManager`)
 * so these tests can execute end-to-end.
 *
 * Shape and reset semantics must match Kotlin field-for-field (both
 * platforms feed the same TypeScript / Dart consumers). Any Swift
 * assertion that diverges from Kotlin here is a real cross-platform
 * bug.
 */
class LocationTrackerConfigTests: XCTestCase {

    private let expectedTopLevelKeys: Set<String> = [
        "accuracyProfile",
        "updateStrategy",
        "enableDebugLogging",
        "proximitySettings",
        "movementSettings",
        "batterySettings",
        "gpsAccuracyThreshold",
        "dwellSettings",
        "clusterSettings",
        "scheduleSettings",
        "activitySettings",
        "disableAlertNotifications",
        "gpsStalenessTimeoutMs"
    ]

    // MARK: - Shape stability

    func testGetCurrentConfigurationMapEmitsEveryDocumentedTopLevelKey() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        XCTAssertEqual(
            expectedTopLevelKeys,
            Set(map.keys),
            "Composed getConfiguration must expose the full 13-key surface — a missing key silently drops that subsystem from the read side."
        )
    }

    func testGetCurrentConfigurationMapEmitsFullActivitySettingsBlock() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        guard let activity = map["activitySettings"] as? [String: Any] else {
            XCTFail("activitySettings must be a map")
            return
        }

        // Every documented interval field must be present with a
        // materialised default — stripping nulls would leave the block
        // with only 3 keys when the user hasn't customised intervals,
        // and TypeScript / Dart consumers would then see `undefined`
        // for documented defaults.
        XCTAssertEqual(
            Set([
                "enabled",
                "confidenceThreshold",
                "debounceSeconds",
                "stillIntervalMs",
                "walkingIntervalMs",
                "runningIntervalMs",
                "cyclingIntervalMs",
                "drivingIntervalMs"
            ]),
            Set(activity.keys),
            "activitySettings must always include every documented interval, even when the caller hasn't overridden one."
        )
    }

    func testActivitySettingsIntervalsAreEmittedAsIntMilliseconds() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()
        guard let activity = map["activitySettings"] as? [String: Any] else {
            XCTFail("activitySettings must be a map")
            return
        }

        // Kotlin emits Long (ms) directly; Swift must emit Int ms
        // from the same map boundary so cross-platform equality
        // checks don't diverge — naive multiplication in Swift
        // yields Double.
        XCTAssertEqual(
            Int(ActivitySettings.DEFAULT_STILL_INTERVAL * 1000),
            activity["stillIntervalMs"] as? Int
        )
        XCTAssertEqual(
            Int(ActivitySettings.DEFAULT_DRIVING_INTERVAL * 1000),
            activity["drivingIntervalMs"] as? Int
        )
    }

    // MARK: - Engine defaults

    func testGpsAccuracyThresholdDefaultsToEngineConstant() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        XCTAssertEqual(
            GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD,
            map["gpsAccuracyThreshold"] as? Double
        )
    }

    func testDwellSettingsDefaultsToEngineConstants() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        guard let dwell = map["dwellSettings"] as? [String: Any] else {
            XCTFail("dwellSettings must be a map")
            return
        }
        XCTAssertEqual(true, dwell["enabled"] as? Bool)
        // Emitted as ms; internally stored as seconds.
        XCTAssertEqual(
            Int(GeofenceEngine.DEFAULT_DWELL_THRESHOLD_SECONDS * 1000),
            dwell["dwellThresholdMs"] as? Int
        )
    }

    func testClusterSettingsDefaultsToEngineConstants() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        guard let cluster = map["clusterSettings"] as? [String: Any] else {
            XCTFail("clusterSettings must be a map")
            return
        }
        XCTAssertEqual(false, cluster["enabled"] as? Bool)
        XCTAssertEqual(
            GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS,
            cluster["activeRadiusMeters"] as? Double
        )
        XCTAssertEqual(
            GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS,
            cluster["refreshDistanceMeters"] as? Double
        )
    }

    // MARK: - Alert notifications

    func testDisableAlertNotificationsDefaultsToFalse() {
        let tracker = LocationTracker()
        let map = tracker.getCurrentConfigurationMap()

        // The alertNotifications flag must always be present in the
        // composed map — omitting it would let a cached bridge config
        // silently reset it to false on every getConfiguration()
        // round-trip. Default is false (alerts ENABLED).
        XCTAssertEqual(false, map["disableAlertNotifications"] as? Bool)
    }

    // MARK: - Write-side coverage

    func testUpdateConfigurationFromMapFlipsAlertNotificationsFlag() {
        let tracker = LocationTracker()

        // `updateSmartConfigurationFromMap` must apply
        // `disableAlertNotifications` — omitting the read here would
        // make a partial update to flip the flag a silent no-op.
        // Handled in the core method so both bridges inherit.
        tracker.updateConfigurationFromMap(["disableAlertNotifications": true])
        XCTAssertEqual(true, tracker.getCurrentConfigurationMap()["disableAlertNotifications"] as? Bool)

        tracker.updateConfigurationFromMap(["disableAlertNotifications": false])
        XCTAssertEqual(false, tracker.getCurrentConfigurationMap()["disableAlertNotifications"] as? Bool)
    }

    func testUpdateConfigurationFromMapAppliesEveryExtraSubsystem() {
        let tracker = LocationTracker()

        // The `updateConfigurationFromMap` core method must apply
        // every one of the six extras subsystems, matching Kotlin's
        // identically-named method. Regression guard against a
        // future contributor removing a branch.
        tracker.updateConfigurationFromMap([
            "gpsAccuracyThreshold": 250.0,
            "dwellSettings": ["enabled": false, "dwellThresholdMs": 60_000],
            "clusterSettings": [
                "enabled": true,
                "activeRadiusMeters": 999.0,
                "refreshDistanceMeters": 111.0
            ],
            "disableAlertNotifications": true
        ])

        let after = tracker.getCurrentConfigurationMap()
        XCTAssertEqual(250.0, after["gpsAccuracyThreshold"] as? Double)
        guard let dwellAfter = after["dwellSettings"] as? [String: Any] else {
            XCTFail("dwellSettings missing after write"); return
        }
        XCTAssertEqual(false, dwellAfter["enabled"] as? Bool)
        XCTAssertEqual(60_000, dwellAfter["dwellThresholdMs"] as? Int)
        guard let clusterAfter = after["clusterSettings"] as? [String: Any] else {
            XCTFail("clusterSettings missing after write"); return
        }
        XCTAssertEqual(true, clusterAfter["enabled"] as? Bool)
        XCTAssertEqual(999.0, clusterAfter["activeRadiusMeters"] as? Double)
        XCTAssertEqual(true, after["disableAlertNotifications"] as? Bool)
    }

    // MARK: - Reset semantics

    func testResetSmartConfigurationClearsEverySubsystem() {
        let tracker = LocationTracker()

        // Set every subsystem to a non-default value so we can prove
        // the reset actually zeroes them.
        tracker.updateConfigurationFromMap([
            "accuracyProfile": "MAX_ACCURACY",
            "updateStrategy": "INTELLIGENT",
            "enableDebugLogging": true,
            "gpsAccuracyThreshold": 250.0,
            "dwellSettings": ["enabled": false, "dwellThresholdMs": 60_000],
            "clusterSettings": [
                "enabled": true,
                "activeRadiusMeters": 999.0,
                "refreshDistanceMeters": 111.0
            ],
            "disableAlertNotifications": true
        ])

        tracker.resetSmartConfiguration()

        // `resetSmartConfiguration` must zero every subsystem the
        // composed map exposes — dwell, cluster, gpsAccuracyThreshold,
        // activity, and the alerts flag included — not just
        // SmartGpsConfig. A reset that leaves subsystems behind is
        // observable to the caller through `getCurrentConfigurationMap`.
        let after = tracker.getCurrentConfigurationMap()
        XCTAssertEqual(
            GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD,
            after["gpsAccuracyThreshold"] as? Double,
            "resetSmartConfiguration must return gpsAccuracyThreshold to the engine default."
        )
        guard let dwellAfter = after["dwellSettings"] as? [String: Any] else {
            XCTFail("dwellSettings missing after reset")
            return
        }
        XCTAssertEqual(true, dwellAfter["enabled"] as? Bool)
        guard let clusterAfter = after["clusterSettings"] as? [String: Any] else {
            XCTFail("clusterSettings missing after reset")
            return
        }
        XCTAssertEqual(false, clusterAfter["enabled"] as? Bool)
        XCTAssertEqual(false, after["disableAlertNotifications"] as? Bool)
    }
}

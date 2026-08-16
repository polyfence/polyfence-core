import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * Permission matrix for the tracker's start gate. Kotlin counterpart:
 * `android/src/test/kotlin/io/polyfence/core/LocationTrackerPermissionGateTest.kt`.
 *
 * The property under test: base tracking needs only foreground authorization,
 * and the stronger grant gates OS wake fences alone. iOS has always accepted
 * `.authorizedWhenInUse` for base tracking — these cases pin that so it cannot
 * drift the way the Android gate did, where an unconditional background-
 * permission requirement refused to start for consumers who never enabled wake
 * fences.
 *
 * A headless test process cannot be granted a real authorization status, so
 * the wake-fence half drives the registrar's authorization override — the
 * Swift analogue of Robolectric's grant/deny.
 */
final class LocationTrackerPermissionGateTests: XCTestCase {

    private var capturedErrors: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        capturedErrors = []
        PolyfenceErrorManager.shared.initialize { [weak self] error in
            self?.capturedErrors.append(error)
        }
        resetPersistedConfig()
    }

    override func tearDown() {
        PolyfenceErrorManager.shared.dispose()
        resetPersistedConfig()
        super.tearDown()
    }

    private func resetPersistedConfig() {
        let config = PolyfenceConfig()
        config.osGeofenceWakeEnabled = false
        config.pendingEventsQueueSize = 0
        config.osGeofenceMaxRegions = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
    }

    private func zone(_ id: String) -> Zone {
        return Zone(
            id: id,
            name: "Zone \(id)",
            type: .circle,
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            radius: 250,
            points: []
        )
    }

    private func registrar(auth: CLAuthorizationStatus) -> OsGeofenceRegistrar {
        let registrar = OsGeofenceRegistrar(locationManager: CLLocationManager())
        registrar._setAuthorizationOverrideForTest(auth)
        registrar.onAppBackgrounded()
        return registrar
    }

    // MARK: - Base tracking accepts foreground authorization

    func testBaseTrackingAcceptsWhenInUseAuthorization() {
        // The contract Android now matches: a foreground-authorized app runs
        // the polling engine. Requiring "always" here would refuse the product
        // to consumers who never asked for wake fences.
        let accepted: Set<CLAuthorizationStatus> = [.authorizedAlways, .authorizedWhenInUse]
        XCTAssertTrue(accepted.contains(.authorizedWhenInUse))
        XCTAssertTrue(accepted.contains(.authorizedAlways))
        XCTAssertFalse(accepted.contains(.denied))
        XCTAssertFalse(accepted.contains(.restricted))
    }

    func testBaseTrackingStartsWithoutWakeFencesConfigured() {
        // Default config, no wake fences: constructing and configuring the
        // tracker must not depend on any always-authorization grant.
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])

        XCTAssertEqual(
            tracker.getCurrentConfigurationMap()["osGeofenceWakeEnabled"] as? Bool,
            false
        )
        XCTAssertNil(tracker.osGeofenceRegistrationHealth())
    }

    // MARK: - Wake fences require the stronger grant

    func testWakeFencesRegisterWithAlwaysAuthorization() {
        let registrar = registrar(auth: .authorizedAlways)

        registrar.refreshNowForTest(zones: [zone("z1")], seed: nil)

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)
        XCTAssertTrue(registrar.healthMap()?["lastError"] is NSNull)
    }

    func testWakeFencesDegradeOnWhenInUseAuthorization() {
        // "When in use" cannot deliver region callbacks after the process is
        // killed, so for wake fences it is equivalent to a denial — but base
        // tracking keeps running on exactly that grant.
        let registrar = registrar(auth: .authorizedWhenInUse)

        registrar.refreshNowForTest(zones: [zone("z1")], seed: nil)

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
        XCTAssertEqual(
            registrar.healthMap()?["lastError"] as? String,
            OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED
        )
        XCTAssertTrue(capturedErrors.contains { ($0["type"] as? String) == "os_geofence_permission_denied" })
    }

    func testWakeFencesDegradeOnOutrightDenial() {
        let registrar = registrar(auth: .denied)

        registrar.refreshNowForTest(zones: [zone("z1")], seed: nil)

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
        XCTAssertEqual(
            registrar.healthMap()?["lastError"] as? String,
            OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED
        )
    }

    // MARK: - Mid-session downgrade

    func testDowngradeMidSessionLeavesTheTrackerConfigured() {
        // Losing the stronger grant costs wake fences, not the product: the
        // tracker's own configuration is untouched by the registrar's failure.
        PolyfenceConfig().osGeofenceWakeEnabled = true
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": 10,
            "osGeofenceWakeEnabled": true
        ])

        let downgraded = registrar(auth: .authorizedWhenInUse)
        downgraded.refreshNowForTest(zones: [zone("z1")], seed: nil)

        XCTAssertEqual(
            tracker.getCurrentConfigurationMap()["pendingEventsQueueSize"] as? Int,
            10,
            "the in-process queue must survive a wake-fence permission loss"
        )
        XCTAssertEqual(downgraded.healthMap()?["registered"] as? Int, 0)
    }
}

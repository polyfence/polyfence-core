import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * Coverage for the OS wake-fence layer. Kotlin counterpart:
 * `android/src/test/kotlin/io/polyfence/core/OsGeofenceWakeTest.kt` — every
 * case here has a mirror there.
 *
 * The bar these cases defend:
 *  - `osGeofenceWakeEnabled = false` (the default) means nothing is registered
 *    with the OS and the in-process pipeline is byte-identical.
 *  - When on, the top-N-nearest set is selected and registered, recalculated
 *    on zone-set change and on movement.
 *  - An OS-fired transition lands in the SAME `PendingEventsStore` the tracker
 *    drains, not a second instance racing the same file.
 *  - Cap-hits and permission denial are both observable via the health field
 *    and neither crashes.
 *
 * A real `CLLocationManager` cannot be granted `authorizedAlways` from a unit
 * test, so the registrar carries `_setAuthorizationOverrideForTest` — the
 * Swift analogue of Robolectric's `grantPermissions` / `denyPermissions`.
 */
final class OsGeofenceWakeTests: XCTestCase {

    private var capturedErrors: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        capturedErrors = []
        PolyfenceErrorManager.shared.initialize { [weak self] error in
            self?.capturedErrors.append(error)
        }
        PolyfenceConfig().osGeofenceWakeEnabled = false
        PolyfenceConfig().pendingEventsQueueSize = 0
    }

    override func tearDown() {
        PolyfenceErrorManager.shared.dispose()
        PolyfenceConfig().osGeofenceWakeEnabled = false
        PolyfenceConfig().pendingEventsQueueSize = 0
        super.tearDown()
    }

    // MARK: - Fixtures

    private func engineZone(
        _ id: String,
        _ lat: Double,
        _ lng: Double,
        radius: Double = 250
    ) -> Zone {
        return Zone(
            id: id,
            name: "Zone \(id)",
            type: .circle,
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            radius: radius,
            points: []
        )
    }

    private func enginePolygonZone(
        _ id: String,
        _ lat: Double,
        _ lng: Double,
        halfSpanDeg: Double = 0.01
    ) -> Zone {
        return Zone(
            id: id,
            name: "Zone \(id)",
            type: .polygon,
            center: nil,
            radius: nil,
            points: [
                CLLocationCoordinate2D(latitude: lat - halfSpanDeg, longitude: lng - halfSpanDeg),
                CLLocationCoordinate2D(latitude: lat - halfSpanDeg, longitude: lng + halfSpanDeg),
                CLLocationCoordinate2D(latitude: lat + halfSpanDeg, longitude: lng + halfSpanDeg),
                CLLocationCoordinate2D(latitude: lat + halfSpanDeg, longitude: lng - halfSpanDeg)
            ]
        )
    }

    private func fixAt(_ lat: Double, _ lng: Double) -> CLLocation {
        return CLLocation(latitude: lat, longitude: lng)
    }

    private func authorizedRegistrar(
        topN: Int = OsGeofenceRegistrar.TOP_N_CAP
    ) -> OsGeofenceRegistrar {
        let registrar = OsGeofenceRegistrar(locationManager: CLLocationManager(), topN: topN)
        registrar._setAuthorizationOverrideForTest(.authorizedAlways)
        return registrar
    }

    private func deniedRegistrar() -> OsGeofenceRegistrar {
        let registrar = OsGeofenceRegistrar(locationManager: CLLocationManager())
        registrar._setAuthorizationOverrideForTest(.authorizedWhenInUse)
        return registrar
    }

    /// Puts a tracker in the state an OS wake fence is actually delivered in:
    /// feature opted in, queue enabled, and no live sink attached (the killed-
    /// or-detached-process case). Both gates must hold or the wake path
    /// correctly declines to queue.
    private func wakeEnabledTracker(queueSize: Int = 10) -> LocationTracker {
        PolyfenceConfig().osGeofenceWakeEnabled = true
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": queueSize,
            "osGeofenceWakeEnabled": true
        ])
        tracker.setBridgeAttached(false)
        _ = tracker.drainPendingEvents()
        return tracker
    }

    private func osRegion(_ zoneId: String, lat: Double = 51.5, lng: Double = -0.1) -> CLCircularRegion {
        return CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            radius: 250,
            identifier: OsGeofenceRegistrar.REGION_ID_PREFIX + zoneId
        )
    }

    // MARK: - Config default: off

    func testOsGeofenceWakeEnabledDefaultsToFalse() {
        PolyfenceConfig().resetToDefaults()
        XCTAssertFalse(PolyfenceConfig().osGeofenceWakeEnabled)
    }

    func testDefaultConfigExposesOsGeofenceWakeEnabledFalseOnTheReadSide() {
        let tracker = LocationTracker()
        XCTAssertEqual(
            tracker.getCurrentConfigurationMap()["osGeofenceWakeEnabled"] as? Bool,
            false
        )
    }

    func testDefaultConfigNeverActivatesTheRegistrar() {
        let tracker = LocationTracker()
        tracker.addZone(zoneId: "z1", zoneName: "Zone 1", zoneData: [
            "type": "circle",
            "center": ["latitude": 51.5, "longitude": -0.1],
            "radius": 250.0
        ])

        // No registrar instance means no OS call was even attempted, and the
        // health field stays nil so a consumer can tell opt-out from cap-hit.
        XCTAssertNil(tracker.osGeofenceRegistrationHealth())
    }

    func testInProcessPersistPathIsUnchangedWhenTheWakeFlagIsOff() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        _ = tracker.drainPendingEvents()

        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "z1",
            eventType: "ENTER",
            location: fixAt(51.5, -0.1)
        )

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
        // No `source` marker — the in-process path must stay byte-identical
        // to what it emitted before OS wake fences existed.
        XCTAssertNil(drained[0]["source"])
    }

    // MARK: - Config on: registers top-N-nearest

    func testRegistrarRegistersTheNearestZonesFirstWhenEnabled() {
        let selected = OsGeofenceRegistrar.selectTopNNearest(
            zones: [
                engineZone("far", 52.5, -0.1),
                engineZone("near", 51.5001, -0.1),
                engineZone("mid", 51.6, -0.1)
            ],
            seed: fixAt(51.5, -0.1),
            topN: OsGeofenceRegistrar.TOP_N_CAP
        )
        XCTAssertEqual(selected.map { $0.zoneId }, ["near", "mid", "far"])
    }

    func testSelectionFallsBackToInsertionOrderWhenNoFixHasLanded() {
        let selected = OsGeofenceRegistrar.selectTopNNearest(
            zones: [engineZone("a", 1.0, 1.0), engineZone("b", 2.0, 2.0)],
            seed: nil,
            topN: OsGeofenceRegistrar.TOP_N_CAP
        )
        XCTAssertEqual(selected.map { $0.zoneId }, ["a", "b"])
    }

    func testPolygonZonesRegisterAsACircularBoundingCoverAroundTheCentroid() {
        let selected = OsGeofenceRegistrar.selectTopNNearest(
            zones: [enginePolygonZone("poly", 51.5, -0.1)],
            seed: fixAt(51.5, -0.1),
            topN: OsGeofenceRegistrar.TOP_N_CAP
        )
        XCTAssertEqual(selected.count, 1)
        // Centroid of the symmetric square is the zone's nominal centre, and
        // the cover radius must reach at least the furthest vertex — a smaller
        // radius would leave a corner of the polygon outside the wake trigger.
        XCTAssertEqual(selected[0].centerLat, 51.5, accuracy: 1e-9)
        XCTAssertEqual(selected[0].centerLng, -0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(
            selected[0].radiusMeters,
            1000.0,
            "cover radius must exceed the polygon half-span"
        )
    }

    func testRegionIdentifierRoundTripsTheZoneId() {
        let selected = OsGeofenceRegistrar.selectTopNNearest(
            zones: [engineZone("z1", 51.5, -0.1)],
            seed: fixAt(51.5, -0.1),
            topN: OsGeofenceRegistrar.TOP_N_CAP
        )
        let region = selected[0].toRegion()
        XCTAssertEqual(region.identifier, OsGeofenceRegistrar.REGION_ID_PREFIX + "z1")
        XCTAssertTrue(region.notifyOnEntry)
        XCTAssertTrue(region.notifyOnExit)
    }

    func testHealthReportsRequestedEqualsRegisteredUnderTheCap() {
        let registrar = authorizedRegistrar()
        let zones = (1...5).map { engineZone("z\($0)", 51.5 + Double($0) * 0.001, -0.1) }

        registrar.refreshNowForTest(zones: zones, seed: fixAt(51.5, -0.1))

        let health = registrar.healthMap()
        XCTAssertNotNil(health)
        XCTAssertEqual(health?["requested"] as? Int, 5)
        XCTAssertEqual(health?["registered"] as? Int, 5)
        XCTAssertTrue(health?["lastError"] is NSNull)
    }

    func testHealthMapShapeMatchesTheDocumentedThreeKeyContract() {
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))

        // Three keys, always — matching the Kotlin registrar exactly. A
        // consumer branching on `lastError` must not have to distinguish
        // "key absent" on one platform from "null" on the other.
        let health = registrar.healthMap()
        XCTAssertEqual(Set(health!.keys), Set(["requested", "registered", "lastError"]))
        XCTAssertTrue(health!["lastError"] is NSNull)
    }

    // MARK: - Cap-hit

    func testCapHitHealthReportsRequestedAboveRegistered() {
        let registrar = authorizedRegistrar()
        let overCap = OsGeofenceRegistrar.TOP_N_CAP + 25
        let zones = (1...overCap).map { engineZone("z\($0)", 51.5 + Double($0) * 0.001, -0.1) }

        registrar.refreshNowForTest(zones: zones, seed: fixAt(51.5, -0.1))

        let health = registrar.healthMap()
        XCTAssertEqual(health?["requested"] as? Int, overCap)
        XCTAssertEqual(health?["registered"] as? Int, OsGeofenceRegistrar.TOP_N_CAP)
        // A cap-hit is partial coverage, not a failure — lastError stays null
        // so consumers can distinguish it from permission drift.
        XCTAssertTrue(health?["lastError"] is NSNull)
    }

    func testSelectionNeverExceedsThePlatformCap() {
        let zones = (1...500).map { engineZone("z\($0)", 51.5 + Double($0) * 0.001, -0.1) }
        let selected = OsGeofenceRegistrar.selectTopNNearest(
            zones: zones,
            seed: fixAt(51.5, -0.1),
            topN: OsGeofenceRegistrar.TOP_N_CAP
        )
        // Apple hard-caps monitored CLCircularRegions at 20 per app; exceeding
        // it makes the OS silently drop the whole request.
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(selected.count, OsGeofenceRegistrar.TOP_N_CAP)
    }

    // MARK: - Permission denial

    func testPermissionDenialEmitsAWarningOnErrorAndDoesNotCrash() {
        let registrar = deniedRegistrar()

        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))

        let error = capturedErrors.first { ($0["type"] as? String) == "os_geofence_permission_denied" }
        XCTAssertNotNil(error, "permission denial must surface via onError")
        let context = error?["context"] as? [String: Any]
        XCTAssertEqual(context?["severity"] as? String, "warning")
        XCTAssertEqual(context?["platform"] as? String, "ios")
    }

    func testPermissionDenialPopulatesTheHealthFieldWithTheDocumentedMarker() {
        let registrar = deniedRegistrar()

        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))

        let health = registrar.healthMap()
        XCTAssertNotNil(health)
        XCTAssertEqual(health?["registered"] as? Int, 0)
        XCTAssertEqual(health?["lastError"] as? String, "background_location_denied")
    }

    func testWhenInUseOnlyIsTreatedAsDeniedForWakeFences() {
        // "When in use" cannot deliver region callbacks after process death,
        // which is the only thing wake fences are for, so it must degrade
        // exactly like an outright denial rather than half-working.
        let registrar = deniedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["lastError"] as? String, "background_location_denied")
    }

    func testPermissionDenialLeavesThePendingQueueIntactAndDrainable() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        _ = tracker.drainPendingEvents()
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "z1",
            eventType: "ENTER",
            location: fixAt(51.5, -0.1)
        )

        deniedRegistrar().refreshNowForTest(
            zones: [engineZone("z1", 51.5, -0.1)],
            seed: fixAt(51.5, -0.1)
        )

        // The degraded path must not corrupt or clear what was already queued.
        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
    }

    // MARK: - OS-fired events reach the shared store

    func testOsFiredTransitionLandsInThePendingEventsStore() {
        let tracker = wakeEnabledTracker()

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "z1")
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
        XCTAssertEqual(
            drained[0]["source"] as? String,
            LocationTracker.EVENT_SOURCE_OS_GEOFENCE
        )
    }

    func testOsFiredExitTransitionLandsInThePendingEventsStore() {
        let tracker = wakeEnabledTracker()

        tracker.locationManager(CLLocationManager(), didExitRegion: osRegion("z9"))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "z9")
        XCTAssertEqual(drained[0]["eventType"] as? String, "EXIT")
    }

    func testMultipleTriggeringFencesEnqueueOneEventEach() {
        let tracker = wakeEnabledTracker()

        let manager = CLLocationManager()
        tracker.locationManager(manager, didEnterRegion: osRegion("a"))
        tracker.locationManager(manager, didEnterRegion: osRegion("b"))
        tracker.locationManager(manager, didEnterRegion: osRegion("c"))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.compactMap { $0["zoneId"] as? String }, ["a", "b", "c"])
    }

    func testOsFiredEventsAreMembershipAppliedByTheSharedDrainPath() {
        let tracker = wakeEnabledTracker()
        tracker.clearAllZones()
        tracker.addZone(zoneId: "z1", zoneName: "Zone 1", zoneData: [
            "type": "circle",
            "center": ["latitude": 51.5, "longitude": -0.1],
            "radius": 250.0
        ])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))
        _ = tracker.drainPendingEvents()

        // drainAndApply must have written the post-drain truth into zoneStates,
        // so the next reconcile sees no mismatch and fires no RECOVERY event.
        XCTAssertEqual(tracker.getCurrentZoneStates()["z1"], true)
        tracker.clearAllZones()
    }

    func testOsFiredTransitionCarriesTheZoneNameWhenTheEngineKnowsIt() {
        let tracker = wakeEnabledTracker()
        tracker.clearAllZones()
        tracker.addZone(zoneId: "z1", zoneName: "Congestion Zone", zoneData: [
            "type": "circle",
            "center": ["latitude": 51.5, "longitude": -0.1],
            "radius": 250.0
        ])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.first?["zoneName"] as? String, "Congestion Zone")
        tracker.clearAllZones()
    }

    func testQueueDisabledMeansAnOsFiredTransitionIsDroppedNotQueued() {
        let tracker = wakeEnabledTracker(queueSize: 0)

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    func testRegionsWeDidNotRegisterAreIgnored() {
        let tracker = wakeEnabledTracker()

        // An application-side region monitored on the same shared manager must
        // not be mistaken for one of ours and enqueued as a zone crossing.
        let foreign = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            radius: 250,
            identifier: "app.own.region"
        )
        tracker.locationManager(CLLocationManager(), didEnterRegion: foreign)

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    // MARK: - No double-reporting

    func testOsFiredTransitionIsSkippedWhileLiveDeliveryIsPossible() {
        PolyfenceConfig().osGeofenceWakeEnabled = true
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": 10,
            "osGeofenceWakeEnabled": true
        ])
        _ = tracker.drainPendingEvents()

        let delegate = LiveDelegate()
        tracker.coreDelegate = delegate
        tracker.setBridgeAttached(true)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "warmup",
            eventType: "ENTER",
            location: fixAt(51.5, -0.1)
        )
        _ = tracker.drainPendingEvents()

        // The in-process engine already reports this crossing to a live sink.
        // Queueing the OS copy too would hand the consumer one physical
        // crossing twice on the next drain.
        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    func testOsFiredTransitionIsSkippedWhenTheFlagIsOff() {
        PolyfenceConfig().osGeofenceWakeEnabled = false
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.setBridgeAttached(false)
        _ = tracker.drainPendingEvents()

        // iOS keeps monitored regions across launches, so a consumer who once
        // enabled the flag can still be woken by that session's fences. With
        // the flag off those wakes must not reach the queue.
        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    /// Minimal live sink — `canDeliverLive()` requires a non-nil delegate, so
    /// the dedup gate cannot be exercised without one.
    private final class LiveDelegate: PolyfenceCoreDelegate {
        func onGeofenceEvent(_ eventData: [String: Any]) {}
        func onLocationUpdate(_ locationData: [String: Any]) {}
        func onPerformanceEvent(_ performanceData: [String: Any]) {}
        func onError(_ errorData: [String: Any]) {}
        func isTrackingEnabled() -> Bool { return true }
    }

    // MARK: - Re-registration triggers

    func testMovementAnchorAdvancesEvenWhenRegistrationIsRefused() {
        let registrar = deniedRegistrar()

        // A refused attempt must still move the anchor. Leaving it nil makes
        // every later fix look like "moved far enough", producing one retry
        // and one onError per GPS fix for as long as the grant is missing.
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        capturedErrors = []

        registrar.onLocationUpdate(fixAt(51.5001, -0.1))

        XCTAssertTrue(
            capturedErrors.filter { ($0["type"] as? String) == "os_geofence_permission_denied" }.isEmpty,
            "a sub-threshold fix must not trigger another registration attempt"
        )
    }

    func testRepeatedDenialsAreRateLimitedOnTheErrorChannel() {
        let registrar = deniedRegistrar()

        for _ in 0..<10 {
            registrar.refreshNowForTest(
                zones: [engineZone("z1", 51.5, -0.1)],
                seed: fixAt(51.5, -0.1)
            )
        }

        // Ten attempts, one report — an un-throttled channel would evict every
        // genuine entry from the consumer's bounded error history.
        let denials = capturedErrors.filter { ($0["type"] as? String) == "os_geofence_permission_denied" }
        XCTAssertEqual(denials.count, 1)
    }

    func testDenialHealthReportsTotalZoneCountNotCandidateCount() {
        let registrar = deniedRegistrar()
        let zones = (1...45).map { engineZone("z\($0)", 51.5 + Double($0) * 0.001, -0.1) }

        registrar.refreshNowForTest(zones: zones, seed: fixAt(51.5, -0.1))

        // `requested` must mean the same thing on every path. Reporting the
        // post-cap candidate count here would make a denial read as a cap hit.
        XCTAssertEqual(registrar.healthMap()?["requested"] as? Int, 45)
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
    }

    func testZoneSetChangeReachesTheOsWithTheUpdatedSetAfterDebounce() {
        let registrar = authorizedRegistrar()

        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)

        registrar.refreshNowForTest(
            zones: [engineZone("z1", 51.5, -0.1), engineZone("z2", 51.51, -0.1)],
            seed: fixAt(51.5, -0.1)
        )
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 2)
        XCTAssertEqual(registrar.healthMap()?["requested"] as? Int, 2)
    }

    func testEmptyZoneSetClearsRegistrationAndReportsZero() {
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))

        registrar.refreshNowForTest(zones: [], seed: fixAt(51.5, -0.1))

        XCTAssertEqual(registrar.healthMap()?["requested"] as? Int, 0)
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
    }

    func testShutdownClearsHealthAndStopsAcceptingRefreshes() {
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertNotNil(registrar.healthMap())

        registrar.shutdown()

        XCTAssertNil(registrar.healthMap())
        registrar.requestRefresh()
        XCTAssertNil(registrar.healthMap())
    }

    // MARK: - Cross-platform constant parity

    func testDebounceWindowMatchesTheAndroidRegistrar() {
        // Both platforms coalesce zone-set churn over the same window; a
        // divergence here would make the two SDKs burn OS quota differently
        // under identical consumer code.
        XCTAssertEqual(OsGeofenceRegistrar.DEBOUNCE_MS, 200)
        XCTAssertEqual(OsGeofenceRegistrar.MOVEMENT_RECALC_METERS, 1000)
    }
}

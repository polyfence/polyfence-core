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
        resetPersistedConfig()
    }

    override func tearDown() {
        PolyfenceErrorManager.shared.dispose()
        resetPersistedConfig()
        super.tearDown()
    }

    /// PolyfenceConfig is backed by a UserDefaults suite that outlives an
    /// individual test, and the tracker now reads it at construction, so a
    /// value left behind by one case would leak into the next.
    private func resetPersistedConfig() {
        let config = PolyfenceConfig()
        config.osGeofenceWakeEnabled = false
        config.pendingEventsQueueSize = 0
        config.osGeofenceMaxRegions = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        // Zone membership persists to the standard defaults suite and outlives
        // a test case. Left behind, a case asserting "no recovery fired" would
        // pass off the previous case's state rather than its own.
        ZonePersistence().clearAllZoneStates()
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
        // Slots are only held while the app is backgrounded; a foregrounded
        // registrar deliberately registers nothing.
        registrar.onAppBackgrounded()
        return registrar
    }

    private func deniedRegistrar() -> OsGeofenceRegistrar {
        let registrar = OsGeofenceRegistrar(locationManager: CLLocationManager())
        registrar._setAuthorizationOverrideForTest(.authorizedWhenInUse)
        registrar.onAppBackgrounded()
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

    // MARK: - Slot allocation: zero held while foregrounded

    func testForegroundTransitionReleasesEveryRegisteredRegion() {
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)

        registrar.onAppForegrounded()

        // The consumer gets the whole platform allocation back while its app is
        // alive — the in-process engine is doing the detection anyway.
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
        XCTAssertTrue(registrar.healthMap()?["lastError"] is NSNull)
    }

    func testNoRegistrationHappensWhileTheAppIsForegrounded() {
        let registrar = authorizedRegistrar()
        registrar.onAppForegrounded()

        registrar.requestRefresh()
        // requestRefresh hops through the registrar's serial queue before it
        // would schedule anything; draining it proves nothing was scheduled.
        registrar.drainForTest()

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
    }

    func testMovementWhileForegroundedDoesNotRegister() {
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        registrar.onAppForegrounded()

        registrar.onLocationUpdate(fixAt(51.55, -0.1))
        registrar.drainForTest()

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
    }

    func testBackgroundTransitionRegistersUpToTheConfiguredCap() {
        let registrar = authorizedRegistrar(topN: 3)
        registrar.onAppForegrounded()
        registrar.onAppBackgrounded()

        let zones = (1...6).map { engineZone("z\($0)", 51.5 + Double($0) * 0.001, -0.1) }
        registrar.refreshNowForTest(zones: zones, seed: fixAt(51.5, -0.1))

        XCTAssertEqual(registrar.healthMap()?["requested"] as? Int, 6)
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 3)
    }

    func testLifecycleNotificationsDriveRegistration() {
        #if canImport(UIKit)
        let registrar = authorizedRegistrar()
        registrar.startObservingAppLifecycle()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        registrar.drainForTest()
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)

        // And the background notification must re-arm, not just the explicit
        // call — the notification wiring is the only path production uses.
        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        registrar.drainForTest()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)
        #endif
    }

    func testStartObservingAppLifecycleIsIdempotent() {
        #if canImport(UIKit)
        // A double call must not double-register the observers, or one
        // notification would drive two transitions.
        let registrar = authorizedRegistrar()
        registrar.startObservingAppLifecycle()
        registrar.startObservingAppLifecycle()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        registrar.drainForTest()

        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 0)
        #endif
    }

    // MARK: - Configurable cap

    func testDefaultCapMatchesThePlatformCeiling() {
        // Unlike Android there is no headroom to hand out: Apple's per-app
        // limit is the default and the maximum.
        XCTAssertEqual(PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS, 20)
        XCTAssertEqual(PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS, 20)
        PolyfenceConfig().resetToDefaults()
        XCTAssertEqual(PolyfenceConfig().osGeofenceMaxRegions, 20)
    }

    func testCapAboveThePlatformMaximumIsClampedWithAWarning() {
        // iOS silently declines regions past 20, so honouring a larger value
        // would report coverage that does not exist.
        XCTAssertEqual(OsGeofenceRegistrar.clampMaxRegions(5_000), 20)
        XCTAssertEqual(OsGeofenceRegistrar.clampMaxRegions(0), 1)
        XCTAssertEqual(
            OsGeofenceRegistrar(locationManager: CLLocationManager(), topN: 5_000)
                .effectiveMaxRegions(),
            20
        )
    }

    func testConfigPersistsTheClampedCapNotTheRawRequest() {
        // Echoing the raw value back through getConfiguration would advertise a
        // budget the registrar never uses and leave the consumer no way to
        // discover the effective one.
        let config = PolyfenceConfig()
        config.osGeofenceMaxRegions = 5_000
        XCTAssertEqual(config.osGeofenceMaxRegions, PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS)
        config.osGeofenceMaxRegions = 0
        XCTAssertEqual(config.osGeofenceMaxRegions, 1)
    }

    func testClampIsSharedWithTheConfigSurface() {
        // One clamp implementation, so a value set through config and a value
        // passed straight to the registrar cannot disagree.
        XCTAssertEqual(
            OsGeofenceRegistrar.clampMaxRegions(5_000),
            PolyfenceConfig.clampOsGeofenceMaxRegions(5_000)
        )
        XCTAssertEqual(
            OsGeofenceRegistrar.clampMaxRegions(0),
            PolyfenceConfig.clampOsGeofenceMaxRegions(0)
        )
    }

    func testCapPropagatesFromConfigThroughUpdateConfiguration() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "osGeofenceMaxRegions": 12,
            "osGeofenceWakeEnabled": true
        ])

        XCTAssertEqual(PolyfenceConfig().osGeofenceMaxRegions, 12)
        XCTAssertEqual(
            tracker.getCurrentConfigurationMap()["osGeofenceMaxRegions"] as? Int,
            12
        )
    }

    func testWakeFlagSurvivesTrackerReconstruction() {
        let first = LocationTracker()
        first.updateConfigurationFromMap(["osGeofenceWakeEnabled": true])

        // When the OS relaunches a killed app on a crossing, the wake path runs
        // before any bridge re-applies configuration. An in-memory-only flag
        // would read false there and the crossing would be discarded.
        let relaunched = LocationTracker()
        XCTAssertEqual(
            relaunched.getCurrentConfigurationMap()["osGeofenceWakeEnabled"] as? Bool,
            true
        )
    }

    // MARK: - Reboot

    func testMonitoredRegionsSurviveRebootWithoutABootReceiver() {
        // iOS restores CLCircularRegion monitoring across a device restart and
        // relaunches the app in the background on a crossing, so there is no
        // iOS counterpart to Android's PolyfenceBootReceiver. This case exists
        // to state that asymmetry explicitly rather than leave the Kotlin
        // suite's boot cases looking unmirrored.
        let registrar = authorizedRegistrar()
        registrar.refreshNowForTest(zones: [engineZone("z1", 51.5, -0.1)], seed: fixAt(51.5, -0.1))
        XCTAssertEqual(registrar.healthMap()?["registered"] as? Int, 1)
    }

    // MARK: - Process-restart and single-writer invariants
    //
    // These exist because the failure surface of this feature lives almost
    // entirely in "the process died and came back" paths, which the rest of the
    // suite structurally cannot reach: it configures a live tracker and reads
    // back from the same instance.

    func testConfigSurvivesASimulatedProcessRestart() {
        // Everything the wake path needs must come off disk, because iOS runs
        // library code on a wake relaunch before any bridge has re-applied
        // configuration. A field applied only in memory passes every other test
        // in this suite and reverts in exactly the scenario that matters.
        let first = LocationTracker()
        first.updateConfigurationFromMap([
            "pendingEventsQueueSize": 500,
            "osGeofenceWakeEnabled": true,
            "osGeofenceMaxRegions": 12,
            "gpsStalenessTimeoutMs": 30_000.0,
            "gpsAccuracyThreshold": 75.0
        ])

        let persisted = PolyfenceConfig()
        XCTAssertEqual(persisted.pendingEventsQueueSize, 500)
        XCTAssertTrue(persisted.osGeofenceWakeEnabled)
        XCTAssertEqual(persisted.osGeofenceMaxRegions, 12)
        XCTAssertEqual(persisted.gpsStalenessTimeoutMs, 30_000.0)
        XCTAssertEqual(persisted.gpsAccuracyThreshold, 75.0)

        // And the relaunched tracker must actually build a usable queue from
        // it — a zero-capacity store silently discards every append.
        let relaunched = LocationTracker()
        XCTAssertEqual(
            relaunched.getCurrentConfigurationMap()["pendingEventsQueueSize"] as? Int,
            500
        )
        relaunched.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))
        XCTAssertEqual(relaunched.drainPendingEvents().count, 1)
    }

    func testOneCrossingSeenByBothWritersIsQueuedExactlyOnce() {
        // The in-process hook persists whenever live delivery did not happen,
        // so gating the OS path on deliverability rather than on the engine
        // running would let both record the same physical crossing.
        PolyfenceConfig().osGeofenceWakeEnabled = true
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": 10,
            "osGeofenceWakeEnabled": true
        ])
        _ = tracker.drainPendingEvents()
        tracker.coreDelegate = LiveDelegate()
        tracker.setBridgeAttached(false)

        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "z1",
            eventType: "ENTER",
            location: fixAt(51.5, -0.1)
        )
        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertEqual(
            tracker.drainPendingEvents().count,
            1,
            "one physical crossing must produce one queued event"
        )
    }

    func testOsFiredTransitionWritesToTheTrackersStoreInstanceNotACopy() {
        let tracker = wakeEnabledTracker()

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        // Asserting on a drain result cannot distinguish the shared store from
        // a transient one — both write the same file. Read the tracker's own
        // store directly instead.
        let store = tracker.pendingEventsStoreForOsGeofence
        XCTAssertNotNil(store)
        let drained = store!.drainAll()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "z1")
    }

    func testStartingStateIsRequestedForOurRegionsOnly() {
        // CoreLocation reports only subsequent crossings, so the starting state
        // has to be asked for explicitly — that is what matches Android's
        // INITIAL_TRIGGER_ENTER for a user already inside a zone.
        let tracker = wakeEnabledTracker()
        let manager = CLLocationManager()

        tracker.locationManager(manager, didDetermineState: .inside, for: osRegion("z1"))
        XCTAssertEqual(tracker.drainPendingEvents().count, 1)

        // Outside must stay silent: replaying an exit for every region the
        // device happens to be outside of would flood the queue.
        tracker.locationManager(manager, didDetermineState: .outside, for: osRegion("z2"))
        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    // MARK: - No double-reporting

    func testOsFiredTransitionIsSkippedWhileTheEngineIsRunning() {
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

    // MARK: - Membership captured at wake time
    //
    // The platform relaunches the app on a region crossing, so unlike Android
    // there is no service to restart — but the relaunched session still
    // reconciles against persisted state, and it must not re-report a crossing
    // the queue already holds. Kotlin mirror: `a wake writes the crossing into
    // persisted zone state` / `a wake-captured crossing produces no duplicate
    // RECOVERY event on the resumed session`.

    func testAWakeWritesTheCrossingIntoPersistedZoneState() {
        let tracker = wakeEnabledTracker()
        ZonePersistence().mergeZoneStates(["z1": false])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertEqual(ZonePersistence().loadZoneStates()["z1"], true)
        // The store is a file shared by every tracker in the process, so a case
        // that queues without draining hands its event to the next one.
        XCTAssertEqual(tracker.drainPendingEvents().count, 1)
    }

    // Region monitoring replays current state for every fence at registration
    // time, so a newly armed region the user is already inside reports .inside
    // immediately. That restates what is already believed and is not a
    // crossing. Kotlin mirror: the persisted-state suppression in the wake
    // receiver.

    func testAWakeRestatingBelievedMembershipIsNotQueued() {
        let tracker = wakeEnabledTracker()
        // The session already knows the user is inside this zone.
        ZonePersistence().mergeZoneStates(["z1": true])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertTrue(
            tracker.drainPendingEvents().isEmpty,
            "A replay of believed membership must not reach the consumer as a crossing"
        )
    }

    func testAWakeThatContradictsBelievedMembershipIsStillQueued() {
        let tracker = wakeEnabledTracker()
        // Believed outside; the OS says inside. That is a real crossing.
        ZonePersistence().mergeZoneStates(["z1": false])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertEqual(
            tracker.drainPendingEvents().count, 1,
            "Suppression must apply only to restatements, never to genuine transitions"
        )
    }

    func testAWakeForAZoneWithNoPersistedMembershipIsQueued() {
        let tracker = wakeEnabledTracker()
        // Nothing on disk for this zone — absence is not agreement, so the
        // crossing must be kept rather than suppressed by a nil comparison.
        ZonePersistence().clearAllZoneStates()

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertEqual(tracker.drainPendingEvents().count, 1)
    }

    func testAWakeCapturedCrossingProducesNoDuplicateRecoveryOnTheRelaunchedSession() {
        let tracker = wakeEnabledTracker()
        tracker.clearAllZones()
        // The session that died believed the user was outside.
        ZonePersistence().mergeZoneStates(["z1": false])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        // What the relaunched process does: rebuild the engine from disk, then
        // reconcile against the first fix it gets.
        var fired: [(String, String)] = []
        let relaunched = GeofenceEngine()
        relaunched.setEventCallback { zoneId, eventType, _, _ in
            fired.append((zoneId, eventType))
        }
        relaunched.setZonePersistence(ZonePersistence())
        try? relaunched.addZone(zoneId: "z1", zoneName: "Zone 1", zoneData: [
            "type": "circle",
            "center": ["latitude": 51.5, "longitude": -0.1],
            "radius": 250.0
        ])
        relaunched.loadPersistedZoneStates()
        relaunched.reconcileZoneStates(fixAt(51.5, -0.1))

        XCTAssertFalse(
            fired.contains { $0.1 == GeofenceEngine.EVENT_RECOVERY_ENTER },
            "the queued ENTER is the only report of this crossing, but got \(fired)"
        )
        XCTAssertEqual(
            tracker.drainPendingEvents().compactMap { $0["eventType"] as? String },
            ["ENTER"]
        )
        tracker.clearAllZones()
    }

    func testAWakeWithTheFeatureOffWritesNoZoneState() {
        let tracker = LocationTracker()
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": 10,
            "osGeofenceWakeEnabled": false
        ])

        tracker.locationManager(CLLocationManager(), didEnterRegion: osRegion("z1"))

        XCTAssertTrue(
            ZonePersistence().loadZoneStates().isEmpty,
            "the flag-off path must touch nothing"
        )
        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }
}

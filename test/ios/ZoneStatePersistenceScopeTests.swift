import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * iOS mirror of `ZoneStatePersistenceScopeTest` (Kotlin).
 *
 * The engine's in-memory `zoneStates` covers registered zones plus whatever a
 * drained batch touched — it is never authoritative over the whole persisted
 * set. These tests pin the resulting property: every write the engine makes to
 * stored zone membership is scoped to the zones it actually knows about, so a
 * partially-populated map cannot erase the rest.
 */
final class ZoneStatePersistenceScopeTests: XCTestCase {

    private var persistence: ZonePersistence!
    private var storeDir: URL!
    private var emittedEvents: [(zoneId: String, eventType: String)] = []

    override func setUp() {
        super.setUp()
        persistence = ZonePersistence()
        clearPersistedZones()
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        storeDir = baseDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        try? FileManager.default.removeItem(at: storeDir)
        let config = PolyfenceConfig()
        config.pendingEventsQueueSize = 0
        config.pendingEventsAutoDrainEnabled = true
        LocationTracker._testResetEventListenerSignal()
        emittedEvents.removeAll()
    }

    override func tearDown() {
        clearPersistedZones()
        persistence = nil
        try? FileManager.default.removeItem(at: storeDir)
        storeDir = nil
        let config = PolyfenceConfig()
        config.pendingEventsQueueSize = 0
        config.pendingEventsAutoDrainEnabled = true
        LocationTracker._testResetEventListenerSignal()
        emittedEvents.removeAll()
        super.tearDown()
    }

    /// Zone membership lives in `UserDefaults.standard`, which outlives an
    /// individual test. Left in place, a previous case's persisted state is
    /// what the assertions read and they pass without this case having
    /// written anything.
    private func clearPersistedZones() {
        persistence.clearAllZoneStates()
        persistence.clearAllZones()
        // Both clears are async barriers on the persistence queue; a sync read
        // behind them is what guarantees they have landed.
        _ = persistence.hasPersistedZoneStates()
    }

    // MARK: - Helpers

    private func circleAt(lat: Double, lng: Double) -> [String: Any] {
        return [
            "type": "circle",
            "center": ["latitude": lat, "longitude": lng],
            "radius": 100.0
        ]
    }

    private func locationAt(lat: Double, lng: Double) -> CLLocation {
        return CLLocation(latitude: lat, longitude: lng)
    }

    private func drainedEvent(zoneId: String, eventType: String) -> [String: Any] {
        return [
            "zoneId": zoneId,
            "eventType": eventType,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
    }

    /// An engine wired to the shared persistence, holding only the zones named.
    /// `zoneStates` is therefore sparse relative to storage — the shape a drain
    /// that lands before zone restoration produces.
    private func engineHolding(_ zoneIds: [String]) -> GeofenceEngine {
        let engine = GeofenceEngine()
        engine.setZonePersistence(persistence)
        engine.setEventCallback { [weak self] zoneId, eventType, _, _ in
            self?.emittedEvents.append((zoneId: zoneId, eventType: eventType))
        }
        for (index, zoneId) in zoneIds.enumerated() {
            try? engine.addZone(
                zoneId: zoneId,
                zoneName: "Zone \(zoneId)",
                zoneData: circleAt(lat: 50.0 + Double(index), lng: 0.0)
            )
        }
        return engine
    }

    /// Reads through the same `ZonePersistence` instance the engine writes
    /// through, so the sync read is ordered behind that instance's queued
    /// barrier write.
    private func persistedStates() -> [String: Bool] {
        return persistence.loadZoneStates()
    }

    // MARK: - Applying a drained batch

    func testApplyingDrainedBatchPreservesMembershipForZonesOutsideIt() {
        persistence.saveZoneStates(
            ["zone-a": false, "zone-b": true, "zone-c": true, "zone-d": false]
        )

        // Only zone-a is registered, so zoneStates holds one entry against four
        // on disk — a drain that lands before restoreZonesFromStorage.
        let engine = engineHolding(["zone-a"])
        _ = engine.applyDrainedEventsToState([drainedEvent(zoneId: "zone-a", eventType: "ENTER")])

        XCTAssertEqual(
            persistedStates(),
            ["zone-a": true, "zone-b": true, "zone-c": true, "zone-d": false],
            "membership for zones outside the drained batch must survive"
        )
    }

    func testApplyingDrainedBatchWritesMembershipForZonesItTouches() {
        persistence.saveZoneStates(["zone-a": true, "zone-b": false, "zone-c": true])

        let engine = engineHolding(["zone-a", "zone-b", "zone-c"])
        engine.loadPersistedZoneStates()
        _ = engine.applyDrainedEventsToState([
            drainedEvent(zoneId: "zone-a", eventType: "EXIT"),
            drainedEvent(zoneId: "zone-b", eventType: "ENTER"),
            drainedEvent(zoneId: "zone-b", eventType: "DWELL")
        ])

        let persisted = persistedStates()
        XCTAssertEqual(persisted["zone-a"], false, "last event per zone wins")
        XCTAssertEqual(persisted["zone-b"], true, "DWELL implies inside")
        XCTAssertEqual(persisted["zone-c"], true, "untouched zone keeps its stored value")
    }

    // MARK: - The two reconcile persist sites

    func testColdStartBaselinePreservesMembershipForZonesTheEngineDoesNotHold() {
        // A zone whose stored record fails to parse on restore leaves its state
        // entry behind with no matching registration, so reconcile persists from
        // a map that does not cover it.
        persistence.saveZoneStates(["zone-unrestored": true])

        let engine = engineHolding(["zone-a"])
        engine.reconcileZoneStates(locationAt(lat: 50.0, lng: 0.0))

        let persisted = persistedStates()
        XCTAssertEqual(persisted["zone-a"], true, "baseline for the held zone is written")
        XCTAssertEqual(
            persisted["zone-unrestored"], true,
            "a zone the engine never registered keeps its stored membership"
        )
    }

    func testReconcilingAMismatchPreservesMembershipForZonesTheEngineDoesNotHold() {
        persistence.saveZoneStates(["zone-unrestored": true])

        let engine = engineHolding(["zone-a"])
        engine._testForceStateRecoveredFromPersistence(true)
        engine.reconcileZoneStates(locationAt(lat: 50.0, lng: 0.0))

        XCTAssertNotNil(
            emittedEvents.first {
                $0.zoneId == "zone-a" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
            },
            "the held zone still recovers its missed transition"
        )
        XCTAssertEqual(
            persistedStates()["zone-unrestored"], true,
            "a zone the engine never registered keeps its stored membership"
        )
    }

    // MARK: - Drain-then-reconcile ordering across a restore

    func testDrainedEnterAppliedBeforeRestorationSurvivesItAndProducesNoRecoveryEnter() {
        persistence.saveZoneStates(["zone-a": false, "zone-b": true])

        // Drain lands first, with only zone-a in the engine.
        let draining = engineHolding(["zone-a"])
        _ = draining.applyDrainedEventsToState([drainedEvent(zoneId: "zone-a", eventType: "ENTER")])

        // Restoration then brings the full zone set up in a fresh engine and
        // reloads membership from storage, exactly as restoreZonesFromStorage does.
        let restored = engineHolding(["zone-a", "zone-b"])
        restored.loadPersistedZoneStates()
        restored.reconcileZoneStates(locationAt(lat: 50.0, lng: 0.0))

        XCTAssertNil(
            emittedEvents.first {
                $0.zoneId == "zone-a" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
            },
            "the drained ENTER already reported the crossing — reconcile must not repeat it"
        )
        // zone-b was stored INSIDE and the fix places the device outside it.
        // Reconcile can only see that genuine mismatch if the drain left
        // zone-b's stored membership alone.
        XCTAssertNotNil(
            emittedEvents.first {
                $0.zoneId == "zone-b" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_EXIT
            },
            "zone-b's genuine transition must still be recovered after the drain"
        )
    }

    // MARK: - The manual drain entry point

    func testManualDrainBeforeZoneRestorationDoesNotEraseStoredMembership() {
        persistence.saveZoneStates(["zone-a": false, "zone-b": true, "zone-c": true])

        // Seed the durable queue before the tracker exists so the drain has a
        // batch to apply. The tracker's own store reads the same log file.
        let seeder = PendingEventsStore(queueSize: 10)
        _ = seeder.append(drainedEvent(zoneId: "zone-a", eventType: "ENTER"))
        seeder.shutdown()

        // The initialiser wires persistence into the engine and builds the
        // store; restoreZonesFromStorage only runs once tracking starts, so a
        // bridge that drains here hits a live tracker with no zones registered.
        let tracker = LocationTracker()
        XCTAssertEqual(tracker.geofenceEngineForOsGeofence.getZoneCount(), 0)

        let drained = tracker.drainPendingEvents()

        XCTAssertEqual(drained.count, 1, "the batch is still returned to the caller")
        XCTAssertEqual(drained.first?["zoneId"] as? String, "zone-a")
        // The tracker persists through its own ZonePersistence instance, whose
        // barrier write is not ordered against this suite's reader.
        waitForPersistedStates(["zone-a": true, "zone-b": true, "zone-c": true])
    }

    /// Polls until stored membership matches, so a write queued on another
    /// `ZonePersistence` instance's barrier has time to land.
    private func waitForPersistedStates(
        _ expected: [String: Bool],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(2.0)
        var latest = persistedStates()
        while latest != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            latest = persistedStates()
        }
        XCTAssertEqual(latest, expected, file: file, line: line)
    }
}

import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * iOS mirror of `PendingEventsAutoDrainTest` (Kotlin). Coverage for automatic
 * delivery of the durable pending-events queue.
 *
 * The load-bearing property is the one `testNoDeliveryWhileOnlyTheBridgeSinkIsAttached`
 * asserts: a bridge attaching its platform-channel sink is NOT a listener, and
 * replaying into that window puts the events somewhere nobody is subscribed.
 *
 * Delegate callbacks are dispatched on main by the tracker, so every delivery
 * assertion runs the main queue before reading the collector.
 */
final class PendingEventsAutoDrainTests: XCTestCase {

    private var tracker: LocationTracker!
    private var storeDir: URL!
    private var collector: CollectingDelegate!

    /// Stands in for a bridge's delivery sink; records what core hands over.
    private final class CollectingDelegate: NSObject, PolyfenceCoreDelegate {
        var received: [[String: Any]] = []
        func onGeofenceEvent(_ eventData: [String: Any]) { received.append(eventData) }
        func onLocationUpdate(_ locationData: [String: Any]) {}
        func onPerformanceEvent(_ performanceData: [String: Any]) {}
        func onError(_ errorData: [String: Any]) {}
        func isTrackingEnabled() -> Bool { return true }
    }

    override func setUp() {
        super.setUp()
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        storeDir = baseDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        try? FileManager.default.removeItem(at: storeDir)
        // The staged signal and the config suite are process-wide and outlive an
        // individual test, so a value left behind by another one would decide
        // this one's outcome.
        LocationTracker._testResetEventListenerSignal()
        let config = PolyfenceConfig()
        config.pendingEventsQueueSize = 0
        config.pendingEventsAutoDrainEnabled = true
        clearPersistedZones()
        collector = CollectingDelegate()
        tracker = LocationTracker()
    }

    /// Zone membership on iOS lives in `UserDefaults.standard`, which outlives
    /// an individual test. Left in place, a previous case's persisted INSIDE
    /// state is reloaded by `restoreZonesFromStorage` and the reconcile
    /// assertions pass without the replay having applied anything.
    private func clearPersistedZones() {
        let persistence = ZonePersistence()
        persistence.clearAllZoneStates()
        persistence.clearAllZones()
        // Both clears are async barriers on the persistence queue; a sync read
        // behind them is what guarantees they have landed before the tracker
        // reads the same store.
        _ = persistence.hasPersistedZoneStates()
    }

    override func tearDown() {
        tracker = nil
        collector = nil
        try? FileManager.default.removeItem(at: storeDir)
        storeDir = nil
        LocationTracker._testResetEventListenerSignal()
        let config = PolyfenceConfig()
        config.pendingEventsQueueSize = 0
        config.pendingEventsAutoDrainEnabled = true
        clearPersistedZones()
        super.tearDown()
    }

    // MARK: - Helpers

    private func locationAt(lat: Double, lng: Double) -> CLLocation {
        return CLLocation(latitude: lat, longitude: lng)
    }

    private func circleAt(lat: Double, lng: Double) -> [String: Any] {
        return [
            "type": "circle",
            "center": ["latitude": lat, "longitude": lng],
            "radius": 100.0
        ]
    }

    /// Delegate callbacks are dispatched on main; drain the queue so the
    /// collector reflects everything the tracker has handed over.
    private func settleMainQueue() {
        let done = expectation(description: "main queue settled")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2.0)
    }

    /// Queue events without a live listener, then put the tracker in the state a
    /// consumer resumes into: zones restored, sink attached, delegate
    /// registered, nothing subscribed yet.
    private func queueEventsAndResume(_ events: [(String, String)]) {
        LocationTracker.setEventListenerActive(false)
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        for (zoneId, eventType) in events {
            tracker._testInvokeHandleGeofenceEvent(
                zoneId: zoneId,
                eventType: eventType,
                location: locationAt(lat: 51.5, lng: -0.1)
            )
        }
        tracker._testRestoreZonesFromStorage()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)
    }

    // MARK: - 1. delivery on first listener

    func testQueuedEventsReachTheNormalCallbackAndTheQueueEmpties() {
        queueEventsAndResume([("zone-a", "ENTER"), ("zone-b", "EXIT")])

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertEqual(collector.received.count, 2)
        XCTAssertEqual(collector.received[0]["zoneId"] as? String, "zone-a")
        XCTAssertEqual(collector.received[0]["eventType"] as? String, "ENTER")
        XCTAssertEqual(collector.received[1]["zoneId"] as? String, "zone-b")
        XCTAssertEqual(collector.received[1]["eventType"] as? String, "EXIT")
        XCTAssertTrue(tracker.drainPendingEvents().isEmpty,
                      "Queue must be empty after an automatic replay")
    }

    func testReplayedEventsCarryTheLateDeliveryProvenanceFields() {
        queueEventsAndResume([("zone-a", "ENTER")])

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertEqual(collector.received.count, 1)
        let event = collector.received[0]
        XCTAssertEqual(event["deliveredLate"] as? Bool, true)
        let capturedTs = (event["capturedTs"] as? NSNumber)?.int64Value
        let timestamp = (event["timestamp"] as? NSNumber)?.int64Value
        XCTAssertEqual(capturedTs, timestamp,
                       "capturedTs must be the crossing's own timestamp, not the replay moment")
        let queued = (event["queuedDurationMs"] as? NSNumber)?.int64Value ?? -1
        XCTAssertGreaterThanOrEqual(queued, 0, "queuedDurationMs must not be negative")
    }

    // MARK: - 2. delivery must not happen before a subscriber exists

    func testNoDeliveryWhileOnlyTheBridgeSinkIsAttached() {
        // Reproduces the bridge's initialize() sequence: the plugin declares that
        // it owns the listener signal, wires its sink, and registers the delegate
        // — all before any consumer has subscribed. Replaying anywhere in that
        // window emits into a stream nobody is reading.
        queueEventsAndResume([("zone-a", "ENTER"), ("zone-b", "EXIT")])
        settleMainQueue()

        XCTAssertTrue(collector.received.isEmpty,
                      "Nothing may be delivered before a listener is signalled — "
                      + "attaching the sink and registering the delegate is what initialize() does")

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertEqual(collector.received.count, 2,
                       "Both queued events must arrive once a listener is genuinely live")
    }

    func testRegisteringADelegateReplaysForADirectConsumer() {
        // A direct-Swift consumer has no listener lifecycle to hook, so setting
        // the delegate IS its subscription moment. This is the same assignment
        // the previous test proves must NOT replay — the difference is that a
        // bridge has declared ownership of the signal there and has not here.
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "zone-a",
            eventType: "ENTER",
            location: locationAt(lat: 51.5, lng: -0.1)
        )
        tracker._testRestoreZonesFromStorage()

        tracker.coreDelegate = collector
        settleMainQueue()

        XCTAssertEqual(collector.received.count, 1)
        XCTAssertEqual(collector.received[0]["zoneId"] as? String, "zone-a")
        XCTAssertEqual(collector.received[0]["deliveredLate"] as? Bool, true)
    }

    // MARK: - 3. opt-out

    func testAutoDrainDisabledDeliversNothingAndLeavesTheQueue() {
        LocationTracker.setEventListenerActive(false)
        tracker.updateConfigurationFromMap([
            "pendingEventsQueueSize": 10,
            "pendingEventsAutoDrainEnabled": false
        ])
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "zone-a",
            eventType: "ENTER",
            location: locationAt(lat: 51.5, lng: -0.1)
        )
        tracker._testRestoreZonesFromStorage()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertTrue(collector.received.isEmpty, "Opt-out must suppress automatic delivery")

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1, "The queue must survive intact for the manual drain")
        XCTAssertEqual(drained[0]["zoneId"] as? String, "zone-a")
    }

    // MARK: - 4. empty queue

    func testEmptyQueueOnListenerAttachDeliversNothingAndDoesNotTouchDisk() {
        LocationTracker.setEventListenerActive(false)
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker._testRestoreZonesFromStorage()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertTrue(collector.received.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("queue.jsonl").path),
            "An attach with nothing queued must not create the log file"
        )
    }

    // MARK: - 5. repeat subscription

    func testASecondListenerSignalDoesNotReplayTheBatchAgain() {
        queueEventsAndResume([("zone-a", "ENTER")])

        tracker.setEventListenerActive(true)
        settleMainQueue()
        XCTAssertEqual(collector.received.count, 1)

        tracker.setEventListenerActive(true)
        settleMainQueue()
        XCTAssertEqual(collector.received.count, 1,
                       "A second subscriber must not re-receive the first one's batch")

        // A genuine resubscribe is a fresh edge, but there is nothing left to
        // replay — and the store answers that without touching disk.
        tracker.setEventListenerActive(false)
        tracker.setEventListenerActive(true)
        settleMainQueue()
        XCTAssertEqual(collector.received.count, 1)
    }

    // MARK: - 6. config survives a process restart

    func testAutoDrainOptOutSurvivesASimulatedProcessRestart() {
        tracker.updateConfigurationFromMap(["pendingEventsAutoDrainEnabled": false])

        // Discard the tracker and build a fresh one — the shape a killed and
        // relaunched process takes. Anything held only in memory reads as its
        // compile-time default here, so the readback below is what proves the
        // flag reached UserDefaults.
        tracker = nil
        tracker = LocationTracker()

        XCTAssertFalse(PolyfenceConfig().pendingEventsAutoDrainEnabled)
        XCTAssertEqual(
            tracker.getCurrentConfigurationMap()["pendingEventsAutoDrainEnabled"] as? Bool,
            false
        )
    }

    func testAutoDrainDefaultsToOnWhenNothingWasEverWritten() {
        PolyfenceConfig().resetToDefaults()
        XCTAssertTrue(PolyfenceConfig().pendingEventsAutoDrainEnabled)
        XCTAssertEqual(
            LocationTracker().getCurrentConfigurationMap()["pendingEventsAutoDrainEnabled"] as? Bool,
            true
        )
    }

    // MARK: - 7. drain-then-reconcile ordering

    func testReplayedEnterResolvingTheMismatchSuppressesRecoveryEnter() {
        let engine = tracker.geofenceEngineForOsGeofence
        try? engine.addZone(zoneId: "zone-a", zoneName: "Zone A", zoneData: circleAt(lat: 50.0, lng: 0.0))

        LocationTracker.setEventListenerActive(false)
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "zone-a",
            eventType: "ENTER",
            location: locationAt(lat: 50.0, lng: 0.0)
        )

        tracker._testRestoreZonesFromStorage()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)
        settleMainQueue()
        XCTAssertEqual(collector.received.count, 1)
        XCTAssertEqual(collector.received[0]["eventType"] as? String, "ENTER")
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], true)

        // The reconcile that runs off the first fix after restore now sees the
        // post-replay truth: still inside, state already inside, no mismatch.
        engine._testForceStateRecoveredFromPersistence(true)
        engine.reconcileZoneStates(locationAt(lat: 50.0, lng: 0.0))
        settleMainQueue()

        let recovery = collector.received.first {
            let type = $0["eventType"] as? String
            return type == GeofenceEngine.EVENT_RECOVERY_ENTER || type == GeofenceEngine.EVENT_RECOVERY_EXIT
        }
        XCTAssertNil(recovery,
                     "A replayed ENTER already told the consumer about this crossing — "
                     + "reconcile must not also report it as a recovery")
    }

    // MARK: - 8. queue off

    func testListenerSignalIsInertWhenQueueSizeIsZero() {
        LocationTracker.setEventListenerActive(false)
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "zone-a",
            eventType: "ENTER",
            location: locationAt(lat: 51.5, lng: -0.1)
        )
        tracker._testRestoreZonesFromStorage()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)
        settleMainQueue()

        XCTAssertTrue(collector.received.isEmpty)
        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    // MARK: - staged signal

    func testAListenerSignalledBeforeTheTrackerExistsReplaysOnceItStarts() {
        LocationTracker.setEventListenerActive(false)
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(
            zoneId: "zone-a",
            eventType: "ENTER",
            location: locationAt(lat: 51.5, lng: -0.1)
        )

        // Signal arrives while the old tracker is going away, then a fresh one
        // is constructed — RN's bridge-reload shape.
        tracker = nil
        LocationTracker.setEventListenerActive(true)
        tracker = LocationTracker()
        tracker.coreDelegate = collector
        tracker.setBridgeAttached(true)
        settleMainQueue()

        XCTAssertTrue(collector.received.isEmpty,
                      "A staged signal must not replay before zones are restored")

        tracker._testRestoreZonesFromStorage()
        settleMainQueue()

        XCTAssertEqual(collector.received.count, 1)
        XCTAssertEqual(collector.received[0]["zoneId"] as? String, "zone-a")
    }
}

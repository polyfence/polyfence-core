import XCTest
import CoreLocation
@testable import PolyfenceCore

/// iOS mirror of DrainThenReconcileTest — direct GeofenceEngine coverage of
/// the direction-doc §9 drain-then-reconcile ordering rule.
final class DrainThenReconcileTests: XCTestCase {

    private var engine: GeofenceEngine!
    private var emittedEvents: [(zoneId: String, eventType: String, location: CLLocation)] = []

    override func setUp() {
        super.setUp()
        engine = GeofenceEngine()
        emittedEvents.removeAll()
        engine.setEventCallback { [weak self] zoneId, eventType, location, _ in
            self?.emittedEvents.append((zoneId: zoneId, eventType: eventType, location: location))
        }
        try? engine.addZone(zoneId: "zone-a", zoneName: "Zone A", zoneData: circleAt(lat: 50.0, lng: 0.0))
        try? engine.addZone(zoneId: "zone-b", zoneName: "Zone B", zoneData: circleAt(lat: 51.0, lng: 0.0))
    }

    override func tearDown() {
        engine = nil
        emittedEvents.removeAll()
        super.tearDown()
    }

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

    /// Force the engine into the mismatch-recovery branch via the
    /// _testForceStateRecoveredFromPersistence seam declared on
    /// GeofenceEngine. The seam is `internal` and prefixed underscore so it
    /// stays out of the public API but is reachable through
    /// `@testable import PolyfenceCore`.
    private func forceRecoveredFromPersistence() {
        engine._testForceStateRecoveredFromPersistence(true)
    }

    // MARK: - applyDrainedEventsToState primitive coverage

    func testApplyDrainedEventsToStateEmptyIsNoOp() {
        let baseline = engine.getCurrentZoneStates()
        let touched = engine.applyDrainedEventsToState([])
        XCTAssertTrue(touched.isEmpty)
        XCTAssertEqual(baseline, engine.getCurrentZoneStates())
    }

    func testApplyDrainedEventsToStateMapsEventTypesCorrectly() {
        let events = [
            drainedEvent(zoneId: "zone-a", eventType: "ENTER"),
            drainedEvent(zoneId: "zone-b", eventType: "EXIT")
        ]
        let touched = engine.applyDrainedEventsToState(events)
        XCTAssertEqual(touched, ["zone-a", "zone-b"])
        let states = engine.getCurrentZoneStates()
        XCTAssertEqual(states["zone-a"], true)
        XCTAssertEqual(states["zone-b"], false)
    }

    func testApplyDrainedEventsToStateSkipsMembershipNeutralTypes() {
        let events = [
            drainedEvent(zoneId: "zone-a", eventType: "SIGNAL_LOST"),
            drainedEvent(zoneId: "zone-a", eventType: "SIGNAL_RESTORED")
        ]
        let touched = engine.applyDrainedEventsToState(events)
        XCTAssertTrue(touched.isEmpty)
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], false)
    }

    func testApplyDrainedEventsToStateTreatsDwellAsInside() {
        let touched = engine.applyDrainedEventsToState([drainedEvent(zoneId: "zone-a", eventType: "DWELL")])
        XCTAssertEqual(touched, ["zone-a"])
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], true)
    }

    // MARK: - drain application on state consistency

    func testDrainCompleteVisitLeavesStateConsistent() {
        // Complete visit ENTER + EXIT for zone-a while dead. After apply,
        // zoneStates["zone-a"] must be false (final state after exit).
        let events = [
            drainedEvent(zoneId: "zone-a", eventType: "ENTER"),
            drainedEvent(zoneId: "zone-a", eventType: "EXIT")
        ]
        let touched = engine.applyDrainedEventsToState(events)
        XCTAssertEqual(touched, ["zone-a"])
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], false)
    }

    func testDrainStillInsideLeavesStateInside() {
        // User entered zone-a while dead and is still inside. After apply,
        // zoneStates["zone-a"] must be true so a subsequent reconcile sees
        // persisted=inside / actual=inside → no mismatch → no RECOVERY_ENTER.
        let events = [drainedEvent(zoneId: "zone-a", eventType: "ENTER")]
        _ = engine.applyDrainedEventsToState(events)
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], true)
    }

    // MARK: - drain-then-reconcile ordering coverage
    //
    // The direction-doc §9 invariant is met by applyDrainedEventsToState
    // running BEFORE reconcile: reconcile sees the post-drain truth and its
    // normal mismatch check produces the right output. No skip-set — an
    // absolute skip would incorrectly suppress the eviction/re-enter case
    // (drain returned a complete visit ending outside, but user is actually
    // inside → recovery MUST fire).

    func testReconcileFiresRecoveryEnterOnMismatch() {
        forceRecoveredFromPersistence()
        let insideZoneA = locationAt(lat: 50.0, lng: 0.0)
        engine.reconcileZoneStates(insideZoneA)

        let zoneARecovery = emittedEvents.first {
            $0.zoneId == "zone-a" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        XCTAssertNotNil(zoneARecovery, "zone-a should fire RECOVERY_ENTER on genuine mismatch")
    }

    func testDrainCompleteVisitReconcileNoDoubleReport() {
        let events = [
            drainedEvent(zoneId: "zone-a", eventType: "ENTER"),
            drainedEvent(zoneId: "zone-a", eventType: "EXIT")
        ]
        let touched = engine.applyDrainedEventsToState(events)
        XCTAssertEqual(touched, ["zone-a"])
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], false)

        forceRecoveredFromPersistence()
        let outsideBoth = locationAt(lat: 52.0, lng: 0.0)
        engine.reconcileZoneStates(outsideBoth)

        let zoneARecovery = emittedEvents.first {
            $0.zoneId == "zone-a" &&
                ($0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER ||
                 $0.eventType == GeofenceEngine.EVENT_RECOVERY_EXIT)
        }
        XCTAssertNil(zoneARecovery, "zone-a must NOT double-report — drain already delivered the enter/exit")
    }

    func testDrainCompleteVisitUserReenteredReconcileMustFireRecoveryEnter() {
        // Phase 1 §5.5 edge case (iOS mirror). Drain contains a complete
        // visit ending OUTSIDE, but the user re-entered after the drop-evicted
        // ENTER. Reconcile MUST fire RECOVERY_ENTER — apply-only invariant.
        let events = [
            drainedEvent(zoneId: "zone-a", eventType: "ENTER"),
            drainedEvent(zoneId: "zone-a", eventType: "EXIT")
        ]
        _ = engine.applyDrainedEventsToState(events)
        XCTAssertEqual(engine.getCurrentZoneStates()["zone-a"], false)

        forceRecoveredFromPersistence()
        let insideZoneA = locationAt(lat: 50.0, lng: 0.0)
        engine.reconcileZoneStates(insideZoneA)

        let zoneARecovery = emittedEvents.first {
            $0.zoneId == "zone-a" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        XCTAssertNotNil(zoneARecovery, "Reconcile MUST fire RECOVERY_ENTER for zone-a — drain's complete visit ended outside but user is now inside (missed re-entry due to queue eviction)")
    }

    func testDrainStillInsideReconcileNoDuplicateRecoveryEnter() {
        _ = engine.applyDrainedEventsToState([drainedEvent(zoneId: "zone-a", eventType: "ENTER")])
        forceRecoveredFromPersistence()

        let insideZoneA = locationAt(lat: 50.0, lng: 0.0)
        engine.reconcileZoneStates(insideZoneA)

        let zoneARecovery = emittedEvents.first {
            $0.zoneId == "zone-a" && $0.eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        XCTAssertNil(zoneARecovery, "No duplicate RECOVERY_ENTER for zone-a — drain-applied state matches actual")
    }
}

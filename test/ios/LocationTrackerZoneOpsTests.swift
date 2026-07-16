import XCTest
@testable import PolyfenceCore

/**
 * Read-after-write coverage for `LocationTracker.addZone` /
 * `removeZone` / `clearAllZones` on iOS.
 *
 * Bug-021 was that the outer `geofenceQueue.async { ... }` wrapper on
 * these methods dispatched the engine mutation onto a background
 * queue and returned before it ran. An immediately-following
 * `getCurrentZoneStates()` — which the bridge's own `sendStatus`
 * call makes right after every zone op — could still see the old
 * state. Wrapper was dropped: the engine's own `syncQueue.sync`
 * already serialises writes against `getCurrentZoneStates` reads.
 * These tests verify the write is observable end-to-end with zero
 * sleep or queue-drain.
 */
class LocationTrackerZoneOpsTests: XCTestCase {

    private var tracker: LocationTracker!

    override func setUp() {
        super.setUp()
        tracker = LocationTracker()
        // Reset to an empty baseline — engine state carries across
        // tests through the process-wide tracker instance we build
        // per test method (LocationTracker() creates a fresh engine).
        tracker.clearAllZones()
    }

    override func tearDown() {
        tracker.clearAllZones()
        tracker = nil
        super.tearDown()
    }

    private func circleZone(
        lat: Double = 40.7128,
        lng: Double = -74.0060,
        radius: Double = 100.0
    ) -> [String: Any] {
        return [
            "type": "circle",
            "center": [
                "latitude": lat,
                "longitude": lng
            ],
            "radius": radius
        ]
    }

    // MARK: - addZone: read-after-write

    func testAddZoneMakesTheNewZoneObservableOnImmediateRead() {
        XCTAssertEqual(0, tracker.getCurrentZoneStates().count)

        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())

        let states = tracker.getCurrentZoneStates()
        XCTAssertTrue(states.keys.contains("office"), "expected office in \(states)")
        XCTAssertEqual(false, states["office"]) // initial state: outside
    }

    func testAddingMultipleZonesInSequenceMakesThemAllObservableOnImmediateRead() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.addZone(zoneId: "gym", zoneName: "Gym", zoneData: circleZone(lat: 40.7500))
        tracker.addZone(zoneId: "home", zoneName: "Home", zoneData: circleZone(lat: 40.8000))

        let states = tracker.getCurrentZoneStates()
        XCTAssertEqual(3, states.count)
        XCTAssertTrue(states.keys.contains("office"))
        XCTAssertTrue(states.keys.contains("gym"))
        XCTAssertTrue(states.keys.contains("home"))
    }

    func testAddZoneRejectsInvalidZoneDataAndDoesNotPersist() {
        // Malformed circle: unrecognised type. ZoneData.fromMap throws,
        // the catch branch dispatches through PolyfenceErrorManager, and
        // the zone must NOT land in getCurrentZoneStates().
        let invalidZone: [String: Any] = [
            "type": "trapezoid",
            "center": ["latitude": 40.0, "longitude": -74.0],
            "radius": 100.0
        ]

        tracker.addZone(zoneId: "bad-zone", zoneName: "Bad", zoneData: invalidZone)

        let states = tracker.getCurrentZoneStates()
        XCTAssertFalse(states.keys.contains("bad-zone"), "bad-zone must not be in \(states)")
        XCTAssertEqual(0, states.count)
    }

    // MARK: - removeZone: read-after-write

    func testRemoveZoneMakesTheRemovalObservableOnImmediateRead() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.addZone(zoneId: "gym", zoneName: "Gym", zoneData: circleZone(lat: 40.7500))
        XCTAssertEqual(2, tracker.getCurrentZoneStates().count)

        tracker.removeZone(zoneId: "office")

        let states = tracker.getCurrentZoneStates()
        XCTAssertEqual(1, states.count)
        XCTAssertFalse(states.keys.contains("office"), "office should be gone from \(states)")
        XCTAssertTrue(states.keys.contains("gym"))
    }

    func testRemoveZoneOnAnUnknownZoneIdIsASafeNoOp() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())

        tracker.removeZone(zoneId: "no-such-zone")

        XCTAssertEqual(1, tracker.getCurrentZoneStates().count)
        XCTAssertTrue(tracker.getCurrentZoneStates().keys.contains("office"))
    }

    // MARK: - clearAllZones: read-after-write

    func testClearAllZonesMakesTheWipeObservableOnImmediateRead() {
        tracker.addZone(zoneId: "office", zoneName: "Office", zoneData: circleZone())
        tracker.addZone(zoneId: "gym", zoneName: "Gym", zoneData: circleZone(lat: 40.7500))
        tracker.addZone(zoneId: "home", zoneName: "Home", zoneData: circleZone(lat: 40.8000))
        XCTAssertEqual(3, tracker.getCurrentZoneStates().count)

        tracker.clearAllZones()

        XCTAssertEqual(0, tracker.getCurrentZoneStates().count)
    }
}

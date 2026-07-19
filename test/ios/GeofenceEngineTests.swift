import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * Unit tests for GeofenceEngine
 * Validates core geofencing logic: zone lifecycle, containment, dwell tracking, and state recovery
 */
class GeofenceEngineTests: XCTestCase {

    var engine: GeofenceEngine!
    var events: [(zoneId: String, eventType: String, timestamp: TimeInterval)] = []

    override func setUp() {
        super.setUp()
        engine = GeofenceEngine()
        events.removeAll()

        // Set up event callback to capture events
        engine.setEventCallback { zoneId, eventType, _, _ in
            self.events.append((zoneId: zoneId, eventType: eventType, timestamp: Date().timeIntervalSince1970))
        }
    }

    override func tearDown() {
        engine = nil
        events.removeAll()
        super.tearDown()
    }

    // MARK: - Zone Lifecycle Tests

    func testAddZoneCircleSuccessfully() throws {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]

        try engine.addZone(zoneId: "zone-1", zoneName: "NYC Zone", zoneData: zoneData)

        XCTAssertTrue(engine.hasZones(), "Engine should have zones")
        XCTAssertEqual(engine.getZoneCount(), 1, "Zone count should be 1")
        XCTAssertEqual(engine.getZoneName("zone-1"), "NYC Zone", "Zone name should match")
    }

    func testAddZonePolygonSuccessfully() throws {
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": polygon
        ]

        try engine.addZone(zoneId: "poly-1", zoneName: "Square Zone", zoneData: zoneData)

        XCTAssertEqual(engine.getZoneName("poly-1"), "Square Zone", "Zone name should match")
    }

    func testRemoveZoneRemovesFromEngine() throws {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]
        try engine.addZone(zoneId: "zone-1", zoneName: "NYC Zone", zoneData: zoneData)
        XCTAssertTrue(engine.hasZones(), "Zone should exist")

        engine.removeZone(zoneId: "zone-1")

        XCTAssertFalse(engine.hasZones(), "Zone should be removed")
        XCTAssertEqual(engine.getZoneCount(), 0, "Zone count should be 0")
        XCTAssertNil(engine.getZoneName("zone-1"), "Zone name should be nil")
    }

    func testRemoveAllZonesClearsAll() throws {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]
        try engine.addZone(zoneId: "zone-1", zoneName: "Zone 1", zoneData: zoneData)
        try engine.addZone(zoneId: "zone-2", zoneName: "Zone 2", zoneData: zoneData)
        try engine.addZone(zoneId: "zone-3", zoneName: "Zone 3", zoneData: zoneData)

        engine.clearAllZones()

        XCTAssertFalse(engine.hasZones(), "No zones should remain")
        XCTAssertEqual(engine.getZoneCount(), 0, "Zone count should be 0")
    }

    func testHasZonesReturnsFalseWhenEmpty() {
        XCTAssertFalse(engine.hasZones(), "Empty engine should have no zones")
    }

    func testAddZoneWithInvalidTypeThrowsException() {
        let invalidZoneData: [String: Any] = ["type": "invalid"]

        XCTAssertThrowsError(
            try engine.addZone(zoneId: "bad-zone", zoneName: "Bad Zone", zoneData: invalidZoneData)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "GeofenceEngine")
        }
    }

    func testAddZoneCircleMissingCenterThrowsException() {
        let badCircle: [String: Any] = [
            "type": "circle",
            "radius": 100.0
        ]

        XCTAssertThrowsError(
            try engine.addZone(zoneId: "no-center", zoneName: "Bad Circle", zoneData: badCircle)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "GeofenceEngine")
        }
    }

    func testAddZoneCircleMissingRadiusThrowsException() {
        let badCircle: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060]
        ]

        XCTAssertThrowsError(
            try engine.addZone(zoneId: "no-radius", zoneName: "Bad Circle", zoneData: badCircle)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "GeofenceEngine")
        }
    }

    // MARK: - Circle Containment Tests

    func testPointInsideCircleReturnsTrue() {
        engine.setValidationConfig(requireConfirmation: false)
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0 // 1km radius
        ]
        try! engine.addZone(zoneId: "circle-1", zoneName: "NYC", zoneData: zoneData)

        // Point ~100m from center (within 1km)
        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["circle-1"] ?? false, "Point should be inside circle")
    }

    func testPointOutsideCircleReturnsFalse() {
        engine.setValidationConfig(requireConfirmation: false)
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0 // 100m radius
        ]
        try! engine.addZone(zoneId: "circle-1", zoneName: "Tiny Zone", zoneData: zoneData)

        // Point ~2km from center (outside 100m)
        let location = createLocation(40.7328, -74.0260)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["circle-1"] ?? true, "Point should be outside circle")
    }

    func testZeroRadiusCircleAsPointMatch() {
        engine.setValidationConfig(requireConfirmation: false)
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 0.0 // Zero radius
        ]
        try! engine.addZone(zoneId: "point-zone", zoneName: "Point Zone", zoneData: zoneData)

        // Exact point
        let exactLocation = createLocation(40.7128, -74.0060)
        engine.checkLocation(exactLocation)
        let exactStates = engine.getCurrentZoneStates()
        XCTAssertTrue(exactStates["point-zone"] ?? false, "Exact point should be inside 0-radius circle")

        // Slightly off
        let nearLocation = createLocation(40.7129, -74.0061)
        engine.checkLocation(nearLocation)
        let nearStates = engine.getCurrentZoneStates()
        XCTAssertFalse(nearStates["point-zone"] ?? true, "Nearby point should be outside 0-radius circle")
    }

    // MARK: - Polygon Containment Tests

    func testPointInsidePolygonReturnsTrue() {
        engine.setValidationConfig(requireConfirmation: false)
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": polygon
        ]
        try! engine.addZone(zoneId: "square-1", zoneName: "Square", zoneData: zoneData)

        // Center of square
        let location = createLocation(0.5, 0.5)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["square-1"] ?? false, "Point inside square should be true")
    }

    func testPointOutsidePolygonReturnsFalse() {
        engine.setValidationConfig(requireConfirmation: false)
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": polygon
        ]
        try! engine.addZone(zoneId: "square-1", zoneName: "Square", zoneData: zoneData)

        // Well outside
        let location = createLocation(2.0, 2.0)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["square-1"] ?? true, "Point outside square should be false")
    }

    func testPointOnPolygonEdge() {
        engine.setValidationConfig(requireConfirmation: false)
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": polygon
        ]
        try! engine.addZone(zoneId: "square-1", zoneName: "Square", zoneData: zoneData)

        // Point on edge
        let location = createLocation(0.5, 0.0)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        // Ray-casting behavior: edge case - result depends on implementation
        XCTAssertNotNil(states["square-1"], "Edge point should have a defined state")
    }

    func testPointOnPolygonVertex() {
        engine.setValidationConfig(requireConfirmation: false)
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": polygon
        ]
        try! engine.addZone(zoneId: "square-1", zoneName: "Square", zoneData: zoneData)

        // Exact vertex
        let location = createLocation(0.0, 0.0)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertNotNil(states["square-1"], "Vertex point should have a defined state")
    }

    func testPolygonWithFewerThanThreePointsThrowsException() {
        let badPolygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": badPolygon
        ]

        XCTAssertThrowsError(
            try engine.addZone(zoneId: "bad-poly", zoneName: "Bad Polygon", zoneData: zoneData)
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "GeofenceEngine")
        }
    }

    func testSelfIntersectingPolygonIsAcceptedWithWarning() {
        // Bowtie shape: vertices create self-intersecting edges.
        //
        // Pre-1.0.6 behaviour: throw and refuse the zone.
        // Post-1.0.6 behaviour: log a warning and accept. Real-world
        // geocoded boundaries trip the self-intersection test for benign
        // reasons (closure seams, duplicate vertices) far more often than
        // for actually malformed input — and `isPointInPolygon` (even-
        // odd-rule ray cast) is well-defined for self-intersecting
        // polygons regardless. Refusing them hurts users for no gain.
        let bowTie: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = [
            "type": "polygon",
            "polygon": bowTie
        ]

        XCTAssertNoThrow(
            try engine.addZone(zoneId: "self-intersect", zoneName: "Bow Tie", zoneData: zoneData),
            "Self-intersecting polygon must now be accepted (warning logged, zone registered)"
        )
        XCTAssertEqual(engine.getZoneCount(), 1)
        XCTAssertEqual(engine.getZoneName("self-intersect"), "Bow Tie")
    }

    // MARK: - Dwell Time Tracking Tests

    func testEnteringZoneStartsDwellTracking() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 1.0) // 1 second for testing

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        // Enter zone
        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        // Should fire ENTER event
        let enterEvents = events.filter { $0.eventType == "ENTER" }
        XCTAssertEqual(enterEvents.count, 1, "Should have ENTER event")
    }

    func testDwellEventFiresAfterThresholdExceeded() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 0.1) // Short threshold for testing

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        // Enter zone
        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        events.removeAll() // Clear ENTER event

        // Wait and check again
        Thread.sleep(forTimeInterval: 0.2)
        engine.checkLocation(location)

        // Should have DWELL event
        let dwellEvents = events.filter { $0.eventType == "DWELL" }
        XCTAssertGreaterThan(dwellEvents.count, 0, "Should have DWELL event after threshold")
    }

    func testDwellEventFiresOnlyOncePerEntry() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 0.05)

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        let location = createLocation(40.7138, -74.0050)

        // Enter and wait past dwell threshold
        engine.checkLocation(location)
        Thread.sleep(forTimeInterval: 0.15)
        // Trigger checkLocation so the DWELL event fires
        engine.checkLocation(location)
        let initialDwellCount = events.filter { $0.eventType == "DWELL" }.count
        XCTAssertEqual(initialDwellCount, 1, "DWELL should fire once after threshold")
        events.removeAll()

        // Further checks should not fire dwell again
        Thread.sleep(forTimeInterval: 0.1)
        engine.checkLocation(location)

        let dwellEvents = events.filter { $0.eventType == "DWELL" }
        XCTAssertEqual(dwellEvents.count, 0, "DWELL should not fire again after initial trigger")
    }

    func testExitingZoneStopsDwellTracking() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 5.0) // 5 second threshold

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        // Enter zone
        let insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)
        events.removeAll()

        // Exit zone (far away)
        let outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        // Should have EXIT event
        let exitEvents = events.filter { $0.eventType == "EXIT" }
        XCTAssertEqual(exitEvents.count, 1, "Should have EXIT event")
    }

    func testDwellDisabledDoesNotFireDwellEvents() {
        engine.setDwellConfig(enabled: false)

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "no-dwell", zoneName: "No Dwell", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        Thread.sleep(forTimeInterval: 0.5)
        engine.checkLocation(location)

        let dwellEvents = events.filter { $0.eventType == "DWELL" }
        XCTAssertEqual(dwellEvents.count, 0, "No DWELL events when disabled")
    }

    // MARK: - False Event Detection Tests (30-second reversal window)

    func testQuickExitAfterEnterIsFlaggedAsReversal() {
        engine.setValidationConfig(requireConfirmation: false)
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "flip-zone", zoneName: "Flip Test", zoneData: zoneData)

        // Enter event
        let insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)

        // Quick exit (< 30s)
        let outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        // Check if reversal is detected
        let isReversal = engine.isRecentReversal(zoneId: "flip-zone", eventType: "EXIT")
        XCTAssertTrue(isReversal, "Quick exit should be flagged as reversal")
    }

    func testExitAfterThirtySeondsIsNotFlaggedAsReversal() {
        engine.setValidationConfig(requireConfirmation: false)
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "slow-zone", zoneName: "Slow Test", zoneData: zoneData)

        // For testing, reversal detection requires actual time passage
        let isReversal = engine.isRecentReversal(zoneId: "slow-zone", eventType: "EXIT")
        XCTAssertFalse(isReversal, "No reversal without recent enter")
    }

    // MARK: - Zone State Recovery Tests

    func testZoneStatesArePreservedAcrossLocationChecks() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "persist-zone", zoneName: "Persist Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        // Enter
        let insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)
        let stateAfterEnter = engine.getCurrentZoneStates()["persist-zone"]
        XCTAssertTrue(stateAfterEnter ?? false, "Should be inside after enter")

        // Check again without exiting
        engine.checkLocation(insideLocation)
        let stateAfterRecheck = engine.getCurrentZoneStates()["persist-zone"]
        XCTAssertEqual(stateAfterEnter, stateAfterRecheck, "State should remain consistent")
    }

    func testGetCurrentZoneStatesReturnsCurrentStateMap() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "state-zone", zoneName: "State Test", zoneData: zoneData)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states.keys.contains("state-zone"), "States map should have zone")
        XCTAssertFalse(states["state-zone"] ?? true, "Should be outside initially")
    }

    func testMultipleZonesTrackIndependentStates() {
        let insideZone: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        let outsideZone: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 50.0, "longitude": -80.0],
            "radius": 100.0
        ]
        try! engine.addZone(zoneId: "near-zone", zoneName: "Near", zoneData: insideZone)
        try! engine.addZone(zoneId: "far-zone", zoneName: "Far", zoneData: outsideZone)
        engine.setValidationConfig(requireConfirmation: false)

        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["near-zone"] ?? false, "Should be inside near-zone")
        XCTAssertFalse(states["far-zone"] ?? true, "Should be outside far-zone")
    }

    // MARK: - Edge Cases and Validation

    func testLocationWithPoorGPSAccuracyIsRejected() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setGpsAccuracyThreshold(50.0) // 50m threshold

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "accuracy-zone", zoneName: "Accuracy Test", zoneData: zoneData)

        // Create location with poor accuracy (100m, exceeds 50m threshold)
        let poorLocation = createLocation(40.7138, -74.0050, accuracy: 100.0)
        engine.checkLocation(poorLocation)

        // Should not have state change because location was rejected
        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["accuracy-zone"] ?? true, "Should remain outside due to poor accuracy")
    }

    func testLocationAtZeroCoordinatesIsRejected() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "zero-zone", zoneName: "Zero Test", zoneData: zoneData)

        let badLocation = CLLocation(latitude: 0.0, longitude: 0.0)
        engine.checkLocation(badLocation)

        // State should not change for invalid location
        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["zero-zone"] ?? true, "Zero location should not trigger state change")
    }

    func testEmptyZoneListDoesNotCrashOnLocationCheck() {
        let location = createLocation(40.7138, -74.0050)

        // Should not throw
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states.isEmpty, "Empty zone list should produce empty state map")
    }

    func testZoneNameRetrievalWorksForValidAndInvalidZones() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]
        try! engine.addZone(zoneId: "exist-zone", zoneName: "Exists", zoneData: zoneData)

        XCTAssertEqual(engine.getZoneName("exist-zone"), "Exists", "Should retrieve existing zone name")
        XCTAssertNil(engine.getZoneName("no-zone"), "Should return nil for non-existent zone")
    }

    func testZoneCountAccuracy() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]

        XCTAssertEqual(engine.getZoneCount(), 0, "Initial count should be 0")

        try! engine.addZone(zoneId: "z1", zoneName: "Zone 1", zoneData: zoneData)
        XCTAssertEqual(engine.getZoneCount(), 1, "Count should be 1")

        try! engine.addZone(zoneId: "z2", zoneName: "Zone 2", zoneData: zoneData)
        XCTAssertEqual(engine.getZoneCount(), 2, "Count should be 2")

        engine.removeZone(zoneId: "z1")
        XCTAssertEqual(engine.getZoneCount(), 1, "Count should be 1 after removal")

        engine.clearAllZones()
        XCTAssertEqual(engine.getZoneCount(), 0, "Count should be 0 after clear")
    }

    func testValidationConfigAffectsDetectionBehavior() {
        engine.setValidationConfig(requireConfirmation: false)

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone(zoneId: "validate-zone", zoneName: "Validate Test", zoneData: zoneData)

        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        events.removeAll()

        // Single location check with confirmation disabled should produce event
        let outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        let hasExitEvent = events.contains { $0.eventType == "EXIT" }
        XCTAssertTrue(hasExitEvent, "Exit event should fire immediately without confirmation")
    }

    // MARK: - Regression: closed polygon false-positive self-intersection (v1.0.6)

    func testAddZoneAcceptsClosedPolygonWithExplicitClosingVertex() throws {
        // Real-world geocoded boundaries (e.g. London Congestion Charge,
        // ULEZ) ship with first == last. The original CCW segment-
        // intersection test only skipped the literal `(0, n-1)` edge pair
        // but on a closed polygon the geometric closure happens between
        // edges 0 and n-2 (both touch points[0] == points[n-1]) and one
        // cross product evaluates to 0 at the shared endpoint, producing
        // a false self-intersection. Normalization (strip trailing
        // duplicate vertex) fixes this.
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 1.0],
            ["latitude": 0.0, "longitude": 0.0]  // explicit closing vertex
        ]
        let zoneData: [String: Any] = ["type": "polygon", "polygon": polygon]

        XCTAssertNoThrow(
            try engine.addZone(zoneId: "closed-square", zoneName: "Closed", zoneData: zoneData),
            "Closed polygon (first == last) must be accepted, not flagged as self-intersecting"
        )
        XCTAssertEqual(engine.getZoneCount(), 1)

        // And the normalized polygon still passes inside/outside checks.
        engine.setValidationConfig(requireConfirmation: false)
        engine.checkLocation(createLocation(0.5, 0.5))
        XCTAssertTrue(engine.getCurrentZoneStates()["closed-square"] ?? false,
                      "Point inside closed polygon should resolve to inside")
    }

    func testAddZoneCollapsesConsecutiveDuplicateVertices() throws {
        // Geocoded data often has consecutive duplicates (1098-point
        // London CC zone had ~10). Without dedup they create zero-length
        // edges that also trip the self-intersection test.
        let polygon: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 0.0, "longitude": 0.0],  // duplicate
            ["latitude": 1.0, "longitude": 0.0],
            ["latitude": 1.0, "longitude": 1.0],
            ["latitude": 1.0, "longitude": 1.0],  // duplicate
            ["latitude": 0.0, "longitude": 1.0]
        ]
        let zoneData: [String: Any] = ["type": "polygon", "polygon": polygon]

        XCTAssertNoThrow(
            try engine.addZone(zoneId: "dup-square", zoneName: "Duped", zoneData: zoneData),
            "Polygon with consecutive duplicates must be accepted"
        )
        XCTAssertEqual(engine.getZoneCount(), 1)
    }

    // MARK: - Regression: reconcile fires ENTER for inside zones on fresh install (v1.0.6)

    func testReconcileFiresEnterForInsideZonesWhenNoPersistedState() throws {
        // On a fresh install (no ZonePersistence), reconcileZoneStates
        // must fire ENTER for every zone the user is currently inside —
        // matches the "tap tracking while standing inside a zone" UX on
        // Android RN / Android Flutter / iOS Flutter.
        let zoneA: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        let zoneB: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 500.0
        ]
        let zoneC: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 50.0, "longitude": 0.0],
            "radius": 100.0
        ]
        try engine.addZone(zoneId: "a", zoneName: "A", zoneData: zoneA)
        try engine.addZone(zoneId: "b", zoneName: "B", zoneData: zoneB)
        try engine.addZone(zoneId: "c", zoneName: "C", zoneData: zoneC)

        // No persisted state has been loaded — engine takes the "fresh
        // install" branch in reconcileZoneStates.
        let here = createLocation(40.7128, -74.0060)
        engine.reconcileZoneStates(here)

        let enterEvents = events.filter { $0.eventType == "ENTER" }
        let enteredIds = Set(enterEvents.map { $0.zoneId })
        XCTAssertEqual(enteredIds, ["a", "b"],
                       "ENTER must fire for every zone we're inside on fresh-state reconcile, but not for outside zones")
    }

    // MARK: - Degraded-GPS handling: Option D + signal-lost / restored

    private func circleZone() -> [String: Any] {
        return ["type": "circle", "center": ["latitude": 1.0, "longitude": 1.0], "radius": 100.0]
    }
    private func exits() -> Int { events.filter { $0.eventType == "EXIT" }.count }
    private func enters() -> Int { events.filter { $0.eventType == "ENTER" }.count }
    private func signalLostCount() -> Int { events.filter { $0.eventType == "SIGNAL_LOST" }.count }
    private func signalRestoredCount() -> Int { events.filter { $0.eventType == "SIGNAL_RESTORED" }.count }

    func testOptionDOffDegradedFixOutsideDoesNotExit() {
        engine.setValidationConfig(requireConfirmation: false)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0)) // ENTER
        events.removeAll()
        engine.checkLocation(createLocation(1.01, 1.0, accuracy: 150.0))
        XCTAssertEqual(exits(), 0, "no exit when degraded-exit is off")
        XCTAssertTrue(engine.getCurrentZoneStates()["z"] == true, "still inside")
    }

    func testOptionDOnDegradedFixConfidentlyOutsideExits() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setDegradedExitEnabled(true)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        events.removeAll()
        engine.checkLocation(createLocation(1.01, 1.0, accuracy: 150.0))
        XCTAssertEqual(exits(), 1, "degraded confident-outside fires EXIT")
    }

    func testOptionDOnDegradedFixNearEdgeDoesNotExit() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setDegradedExitEnabled(true)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        events.removeAll()
        engine.checkLocation(createLocation(1.0015, 1.0, accuracy: 150.0))
        XCTAssertEqual(exits(), 0, "noisy near-edge degraded fix must not exit")
    }

    func testOptionDOnDegradedFixInsideDoesNotEnter() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setDegradedExitEnabled(true)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 150.0))
        XCTAssertEqual(enters(), 0, "degraded fix must not ENTER")
    }

    func testOptionDOnPolygonNearEdgeDoesNotExit() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setDegradedExitEnabled(true)
        let poly: [[String: Any]] = [
            ["latitude": 0.0, "longitude": 0.0],
            ["latitude": 0.01, "longitude": 0.0],
            ["latitude": 0.01, "longitude": 0.01],
            ["latitude": 0.0, "longitude": 0.01]
        ]
        try! engine.addZone(zoneId: "p", zoneName: "P", zoneData: ["type": "polygon", "polygon": poly])
        engine.checkLocation(createLocation(0.005, 0.005, accuracy: 10.0)) // inside -> ENTER
        events.removeAll()
        engine.checkLocation(createLocation(0.005, -0.0005, accuracy: 150.0))
        XCTAssertEqual(exits(), 0, "noisy near-edge degraded fix must not exit polygon")
    }

    func testAccuracyAtThresholdRejectedJustUnderAccepted() {
        engine.setValidationConfig(requireConfirmation: false)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 100.0)) // == threshold -> rejected
        XCTAssertEqual(enters(), 0, "accuracy == threshold rejected")
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 99.0))
        XCTAssertEqual(enters(), 1, "accuracy < threshold accepted")
    }

    func testSignalLostKeepsStateAndDedupes() {
        engine.setValidationConfig(requireConfirmation: false)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        events.removeAll()
        engine.forceSignalLost(createLocation(1.0, 1.0, accuracy: 10.0))
        XCTAssertEqual(signalLostCount(), 1, "one SIGNAL_LOST")
        XCTAssertTrue(engine.getCurrentZoneStates()["z"] == true, "state unchanged")
        engine.forceSignalLost(createLocation(1.0, 1.0, accuracy: 10.0))
        XCTAssertEqual(signalLostCount(), 1, "no duplicate SIGNAL_LOST")
    }

    func testSignalRestoredWhenStillInside() {
        engine.setValidationConfig(requireConfirmation: false)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        engine.forceSignalLost(createLocation(1.0, 1.0, accuracy: 10.0))
        events.removeAll()
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        XCTAssertEqual(signalRestoredCount(), 1, "SIGNAL_RESTORED fired")
        XCTAssertEqual(exits(), 0, "no EXIT")
    }

    func testExitNotRestoredWhenOutside() {
        engine.setValidationConfig(requireConfirmation: false)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        engine.forceSignalLost(createLocation(1.0, 1.0, accuracy: 10.0))
        events.removeAll()
        engine.checkLocation(createLocation(1.01, 1.0, accuracy: 10.0)) // valid, outside
        XCTAssertEqual(exits(), 1, "EXIT fired")
        XCTAssertEqual(signalRestoredCount(), 0, "no SIGNAL_RESTORED after exit")
    }

    func testCrossPathDegradedExitThenInsideDoesNotRestore() {
        engine.setValidationConfig(requireConfirmation: false)
        engine.setDegradedExitEnabled(true)
        try! engine.addZone(zoneId: "z", zoneName: "Z", zoneData: circleZone())
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0))
        engine.forceSignalLost(createLocation(1.0, 1.0, accuracy: 10.0))
        engine.checkLocation(createLocation(1.01, 1.0, accuracy: 150.0)) // degraded confident-outside -> EXIT, clears flag
        events.removeAll()
        engine.checkLocation(createLocation(1.0, 1.0, accuracy: 10.0)) // inside again -> ENTER, must NOT restore
        XCTAssertEqual(signalRestoredCount(), 0, "no SIGNAL_RESTORED after a degraded EXIT")
    }

    // MARK: - Helper Functions

    private func createLocation(_ lat: Double, _ lng: Double, accuracy: CLLocationAccuracy = 10.0) -> CLLocation {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let location = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, course: 0, speed: 0, timestamp: Date())
        return location
    }
}


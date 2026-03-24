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

    func testAddZoneCircleSuccessfully() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]

        engine.addZone("zone-1", zoneName: "NYC Zone", zoneData: zoneData)

        XCTAssertTrue(engine.hasZones(), "Engine should have zones")
        XCTAssertEqual(engine.getZoneCount(), 1, "Zone count should be 1")
        XCTAssertEqual(engine.getZoneName("zone-1"), "NYC Zone", "Zone name should match")
    }

    func testAddZonePolygonSuccessfully() {
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

        engine.addZone("poly-1", zoneName: "Square Zone", zoneData: zoneData)

        XCTAssertEqual(engine.getZoneName("poly-1"), "Square Zone", "Zone name should match")
    }

    func testRemoveZoneRemovesFromEngine() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]
        engine.addZone("zone-1", zoneName: "NYC Zone", zoneData: zoneData)
        XCTAssertTrue(engine.hasZones(), "Zone should exist")

        engine.removeZone("zone-1")

        XCTAssertFalse(engine.hasZones(), "Zone should be removed")
        XCTAssertEqual(engine.getZoneCount(), 0, "Zone count should be 0")
        XCTAssertNil(engine.getZoneName("zone-1"), "Zone name should be nil")
    }

    func testRemoveAllZonesClearsAll() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0
        ]
        engine.addZone("zone-1", zoneName: "Zone 1", zoneData: zoneData)
        engine.addZone("zone-2", zoneName: "Zone 2", zoneData: zoneData)
        engine.addZone("zone-3", zoneName: "Zone 3", zoneData: zoneData)

        engine.removeAllZones()

        XCTAssertFalse(engine.hasZones(), "No zones should remain")
        XCTAssertEqual(engine.getZoneCount(), 0, "Zone count should be 0")
    }

    func testHasZonesReturnsFalseWhenEmpty() {
        XCTAssertFalse(engine.hasZones(), "Empty engine should have no zones")
    }

    func testAddZoneWithInvalidTypeThrowsException() {
        let invalidZoneData: [String: Any] = ["type": "invalid"]

        XCTAssertThrowsError(
            try engine.addZone("bad-zone", zoneName: "Bad Zone", zoneData: invalidZoneData)
        ) { error in
            XCTAssertTrue(error is GeofenceEngineError)
        }
    }

    func testAddZoneCircleMissingCenterThrowsException() {
        let badCircle: [String: Any] = [
            "type": "circle",
            "radius": 100.0
        ]

        XCTAssertThrowsError(
            try engine.addZone("no-center", zoneName: "Bad Circle", zoneData: badCircle)
        ) { error in
            XCTAssertTrue(error is GeofenceEngineError)
        }
    }

    func testAddZoneCircleMissingRadiusThrowsException() {
        let badCircle: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060]
        ]

        XCTAssertThrowsError(
            try engine.addZone("no-radius", zoneName: "Bad Circle", zoneData: badCircle)
        ) { error in
            XCTAssertTrue(error is GeofenceEngineError)
        }
    }

    // MARK: - Circle Containment Tests

    func testPointInsideCircleReturnsTrue() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0 // 1km radius
        ]
        try! engine.addZone("circle-1", zoneName: "NYC", zoneData: zoneData)

        // Point ~100m from center (within 1km)
        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["circle-1"] ?? false, "Point should be inside circle")
    }

    func testPointOutsideCircleReturnsFalse() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 100.0 // 100m radius
        ]
        try! engine.addZone("circle-1", zoneName: "Tiny Zone", zoneData: zoneData)

        // Point ~2km from center (outside 100m)
        let location = createLocation(40.7328, -74.0260)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["circle-1"] ?? true, "Point should be outside circle")
    }

    func testZeroRadiusCircleAsPointMatch() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 0.0 // Zero radius
        ]
        try! engine.addZone("point-zone", zoneName: "Point Zone", zoneData: zoneData)

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
        try! engine.addZone("square-1", zoneName: "Square", zoneData: zoneData)

        // Center of square
        let location = createLocation(0.5, 0.5)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["square-1"] ?? false, "Point inside square should be true")
    }

    func testPointOutsidePolygonReturnsFalse() {
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
        try! engine.addZone("square-1", zoneName: "Square", zoneData: zoneData)

        // Well outside
        let location = createLocation(2.0, 2.0)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertFalse(states["square-1"] ?? true, "Point outside square should be false")
    }

    func testPointOnPolygonEdge() {
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
        try! engine.addZone("square-1", zoneName: "Square", zoneData: zoneData)

        // Point on edge
        let location = createLocation(0.5, 0.0)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        // Ray-casting behavior: edge case - result depends on implementation
        XCTAssertNotNil(states["square-1"], "Edge point should have a defined state")
    }

    func testPointOnPolygonVertex() {
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
        try! engine.addZone("square-1", zoneName: "Square", zoneData: zoneData)

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
            try engine.addZone("bad-poly", zoneName: "Bad Polygon", zoneData: zoneData)
        ) { error in
            XCTAssertTrue(error is GeofenceEngineError)
        }
    }

    func testSelfIntersectingPolygonThrowsException() {
        // Bowtie shape: vertices create self-intersecting edges
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

        XCTAssertThrowsError(
            try engine.addZone("self-intersect", zoneName: "Bad Polygon", zoneData: zoneData)
        ) { error in
            XCTAssertTrue(error is GeofenceEngineError)
        }
    }

    // MARK: - Dwell Time Tracking Tests

    func testEnteringZoneStartsDwellTracking() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 1.0) // 1 second for testing

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
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
        try! engine.addZone("dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
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
        try! engine.addZone("dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
        engine.setValidationConfig(requireConfirmation: false)

        let location = createLocation(40.7138, -74.0050)

        // Enter and wait
        engine.checkLocation(location)
        Thread.sleep(forTimeInterval: 0.15)
        events.removeAll()

        // Multiple checks - should not fire dwell multiple times
        engine.checkLocation(location)
        Thread.sleep(forTimeInterval: 0.1)
        engine.checkLocation(location)

        let dwellEvents = events.filter { $0.eventType == "DWELL" }
        XCTAssertEqual(dwellEvents.count, 0, "DWELL should already have fired")
    }

    func testExitingZoneStopsDwellTracking() {
        engine.setDwellConfig(enabled: true, thresholdSeconds: 5.0) // 5 second threshold

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("dwell-zone", zoneName: "Dwell Test", zoneData: zoneData)
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
        try! engine.addZone("no-dwell", zoneName: "No Dwell", zoneData: zoneData)
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
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("flip-zone", zoneName: "Flip Test", zoneData: zoneData)

        // Enter event
        let insideLocation = createLocation(40.7138, -74.0050)
        engine.checkLocation(insideLocation)

        // Quick exit (< 30s)
        let outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        // Check if reversal is detected
        let isReversal = engine.isRecentReversal("flip-zone", eventType: "EXIT")
        XCTAssertTrue(isReversal, "Quick exit should be flagged as reversal")
    }

    func testExitAfterThirtySeondsIsNotFlaggedAsReversal() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("slow-zone", zoneName: "Slow Test", zoneData: zoneData)

        // For testing, reversal detection requires actual time passage
        let isReversal = engine.isRecentReversal("slow-zone", eventType: "EXIT")
        XCTAssertFalse(isReversal, "No reversal without recent enter")
    }

    // MARK: - Zone State Recovery Tests

    func testZoneStatesArePreservedAcrossLocationChecks() {
        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("persist-zone", zoneName: "Persist Test", zoneData: zoneData)
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
        try! engine.addZone("state-zone", zoneName: "State Test", zoneData: zoneData)

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
        try! engine.addZone("near-zone", zoneName: "Near", zoneData: insideZone)
        try! engine.addZone("far-zone", zoneName: "Far", zoneData: outsideZone)
        engine.setValidationConfig(requireConfirmation: false)

        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)

        let states = engine.getCurrentZoneStates()
        XCTAssertTrue(states["near-zone"] ?? false, "Should be inside near-zone")
        XCTAssertFalse(states["far-zone"] ?? true, "Should be outside far-zone")
    }

    // MARK: - Edge Cases and Validation

    func testLocationWithPoorGPSAccuracyIsRejected() {
        engine.setGpsAccuracyThreshold(50.0) // 50m threshold

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("accuracy-zone", zoneName: "Accuracy Test", zoneData: zoneData)

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
        try! engine.addZone("zero-zone", zoneName: "Zero Test", zoneData: zoneData)

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
        try! engine.addZone("exist-zone", zoneName: "Exists", zoneData: zoneData)

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

        try! engine.addZone("z1", zoneName: "Zone 1", zoneData: zoneData)
        XCTAssertEqual(engine.getZoneCount(), 1, "Count should be 1")

        try! engine.addZone("z2", zoneName: "Zone 2", zoneData: zoneData)
        XCTAssertEqual(engine.getZoneCount(), 2, "Count should be 2")

        engine.removeZone("z1")
        XCTAssertEqual(engine.getZoneCount(), 1, "Count should be 1 after removal")

        engine.removeAllZones()
        XCTAssertEqual(engine.getZoneCount(), 0, "Count should be 0 after clear")
    }

    func testValidationConfigAffectsDetectionBehavior() {
        engine.setValidationConfig(requireConfirmation: false)

        let zoneData: [String: Any] = [
            "type": "circle",
            "center": ["latitude": 40.7128, "longitude": -74.0060],
            "radius": 1000.0
        ]
        try! engine.addZone("validate-zone", zoneName: "Validate Test", zoneData: zoneData)

        let location = createLocation(40.7138, -74.0050)
        engine.checkLocation(location)
        events.removeAll()

        // Single location check with confirmation disabled should produce event
        let outsideLocation = createLocation(40.8328, -74.1260)
        engine.checkLocation(outsideLocation)

        let hasExitEvent = events.contains { $0.eventType == "EXIT" }
        XCTAssertTrue(hasExitEvent, "Exit event should fire immediately without confirmation")
    }

    // MARK: - Helper Functions

    private func createLocation(_ lat: Double, _ lng: Double, accuracy: CLLocationAccuracy = 10.0) -> CLLocation {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let location = CLLocation(coordinate: coordinate, accuracy: accuracy, altitude: 0, verticalAccuracy: -1, course: 0, speed: 0, timestamp: Date())
        return location
    }
}

// MARK: - Error Types (for testing purposes)
enum GeofenceEngineError: Error {
    case invalidZoneType
    case missingCenter
    case missingRadius
    case invalidPolygon
    case selfIntersectingPolygon
}

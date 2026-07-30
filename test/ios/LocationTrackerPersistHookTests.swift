import XCTest
import CoreLocation
@testable import PolyfenceCore

/**
 * iOS mirror of `LocationTrackerPersistHookTest` (Kotlin). Verifies that a
 * fired geofence event lands in `PendingEventsStore` exactly when
 * `pendingEventsQueueSize > 0` AND the delegate is either missing or
 * `bridgeAttached` is false — the XOR contract that makes the durable queue
 * useful. Uses the `_testInvokeHandleGeofenceEvent` seam to drive the
 * persist-hook without a real CLLocationManager fix.
 *
 * Delegate-throw auto-flip coverage is Android-only: Swift try/catch cannot
 * catch the Objective-C exceptions that would flow from e.g. a FlutterEventSink
 * invoked on the wrong queue, so iOS bridges own responsibility for calling
 * setBridgeAttached(false) from their own teardown callbacks. That contract
 * is documented in LocationTracker.swift handleGeofenceEvent.
 */
final class LocationTrackerPersistHookTests: XCTestCase {

    private var tracker: LocationTracker!
    private var storeDir: URL!

    override func setUp() {
        super.setUp()
        // iOS PendingEventsStore uses .applicationSupportDirectory + backup
        // exclusion; clear it between tests so a previous run's queued events
        // don't leak into the next test's expectations.
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        storeDir = baseDir.appendingPathComponent("polyfence-pending-events", isDirectory: true)
        try? FileManager.default.removeItem(at: storeDir)
        tracker = LocationTracker()
    }

    override func tearDown() {
        tracker = nil
        try? FileManager.default.removeItem(at: storeDir)
        storeDir = nil
        super.tearDown()
    }

    private func locationAt(lat: Double, lng: Double) -> CLLocation {
        return CLLocation(latitude: lat, longitude: lng)
    }

    /// A no-op delegate stub — represents the "bridge is registered" case. The
    /// persist-hook checks `coreDelegate == nil || !bridgeAttached`; without
    /// a stub, `coreDelegate == nil` always short-circuits to persist and the
    /// bridge-attached signal cannot be isolated.
    private final class NoopDelegate: NSObject, PolyfenceCoreDelegate {
        func onGeofenceEvent(_ eventData: [String: Any]) {}
        func onLocationUpdate(_ locationData: [String: Any]) {}
        func onPerformanceEvent(_ performanceData: [String: Any]) {}
        func onError(_ errorData: [String: Any]) {}
        func isTrackingEnabled() -> Bool { return true }
    }

    func testEventPersistsWhenQueueEnabledAndNoDelegate() {
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = nil

        tracker._testInvokeHandleGeofenceEvent(zoneId: "zone-a", eventType: "ENTER", location: locationAt(lat: 50.0, lng: 0.0))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "zone-a")
        XCTAssertEqual(drained[0]["eventType"] as? String, "ENTER")
    }

    func testEventPersistsWhenDelegateSetButBridgeNotAttached() {
        let delegate = NoopDelegate()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = delegate
        tracker.setBridgeAttached(false)

        tracker._testInvokeHandleGeofenceEvent(zoneId: "zone-a", eventType: "EXIT", location: locationAt(lat: 50.0, lng: 0.0))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "zone-a")
    }

    func testEventDoesNotPersistWhenDelegateSetAndBridgeAttachedLiveDelivery() {
        // XOR contract: live delivery MUST NOT also persist. This is the P0
        // regression test — before the iOS XOR fix, this scenario would
        // append to the store AND fire the delegate, producing a duplicate
        // on the next drain.
        let delegate = NoopDelegate()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = delegate
        tracker.setBridgeAttached(true)

        tracker._testInvokeHandleGeofenceEvent(zoneId: "zone-a", eventType: "ENTER", location: locationAt(lat: 50.0, lng: 0.0))

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty,
                      "Store must be empty — live delivery was possible so persist must not fire")
    }

    func testEventDoesNotPersistWhenQueueSizeIsZero() {
        // pendingEventsQueueSize left at its default 0.
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)

        tracker._testInvokeHandleGeofenceEvent(zoneId: "zone-a", eventType: "ENTER", location: locationAt(lat: 50.0, lng: 0.0))

        XCTAssertTrue(tracker.drainPendingEvents().isEmpty)
    }

    func testGeofenceCallbackFiresIndependentlyOfDelegateAndBridge() {
        // A callback-only consumer (setGeofenceCallback with no coreDelegate)
        // is an in-process direct-Swift subscriber — no bridge boundary, no
        // drop scenario. The callback MUST fire regardless of the delegate /
        // bridgeAttached state. An earlier iteration of the persist-hook XOR
        // accidentally gated geofenceCallback alongside the delegate call, so
        // callback-only consumers saw silent drops. Test locks in that the
        // callback path is orthogonal to the delegate/persist XOR.
        var received: [[String: Any]] = []
        let expectation = self.expectation(description: "geofence callback fires")
        tracker.setGeofenceCallback { event in
            received.append(event)
            expectation.fulfill()
        }
        tracker.coreDelegate = nil
        tracker.setBridgeAttached(false)

        tracker._testInvokeHandleGeofenceEvent(zoneId: "zone-a", eventType: "ENTER", location: locationAt(lat: 50.0, lng: 0.0))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0]["zoneId"] as? String, "zone-a")
    }

    func testBridgeAttachedToggleTakesEffectBetweenFires() {
        let delegate = NoopDelegate()
        tracker.updateConfigurationFromMap(["pendingEventsQueueSize": 10])
        tracker.coreDelegate = delegate

        tracker.setBridgeAttached(true)
        tracker._testInvokeHandleGeofenceEvent(zoneId: "live-1", eventType: "ENTER", location: locationAt(lat: 50.0, lng: 0.0))
        XCTAssertTrue(tracker.drainPendingEvents().isEmpty, "First fire: bridge attached, live-delivered, no persist")

        tracker.setBridgeAttached(false)
        tracker._testInvokeHandleGeofenceEvent(zoneId: "queued-1", eventType: "EXIT", location: locationAt(lat: 50.0, lng: 0.0))

        let drained = tracker.drainPendingEvents()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0]["zoneId"] as? String, "queued-1")
    }
}

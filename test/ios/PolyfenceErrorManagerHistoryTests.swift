import XCTest
@testable import PolyfenceCore

/**
 * Regression coverage for BUG-016: PolyfenceErrorManager.reportError
 * must persist the error to PolyfenceDebugCollector's history in
 * addition to invoking the real-time onError callback. Pre-fix the
 * two systems were separate and errorHistory() always returned []
 * regardless of how many errors had fired.
 *
 * PolyfenceDebugCollector.shared is a process-wide singleton with no
 * public reset, so each test uses a unique error `type` and asserts
 * by filtering on that type — cumulative state on the shared array
 * can't confuse assertions.
 *
 * Mirror of the Android PolyfenceErrorManagerHistoryTest.
 */
class PolyfenceErrorManagerHistoryTests: XCTestCase {

    override func tearDown() {
        PolyfenceErrorManager.shared.dispose()
        super.tearDown()
    }

    func testReportErrorPersistsToHistoryEvenWithoutASubscriber() {
        // Deliberately do NOT initialise a callback. Pre-fix the error
        // vanished entirely in this case — no callback + no history
        // write. Post-fix, the history captures it.
        let marker = "bug016_no_subscriber_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        PolyfenceErrorManager.shared.reportError(
            type: marker,
            message: "Battery optimization bypass required",
            context: ["platform": "ios"]
        )

        let history = PolyfenceDebugCollector.shared.getErrorHistory(timeRangeMs: nil, errorTypes: [marker])
        XCTAssertEqual(history.count, 1, "errorHistory must capture the reported error")
        XCTAssertEqual(history[0]["type"] as? String, marker)
        XCTAssertEqual(history[0]["message"] as? String, "Battery optimization bypass required")
    }

    func testReportErrorPersistsAlongsideTheSubscriberCallback() {
        // Both paths fire — the real-time callback stays intact and the
        // history captures the error.
        let marker = "bug016_with_subscriber_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        var received: [[String: Any]] = []
        PolyfenceErrorManager.shared.initialize { errorData in
            received.append(errorData)
        }

        PolyfenceErrorManager.shared.reportError(
            type: marker,
            message: "GPS signal timeout",
            context: ["platform": "ios"]
        )

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0]["type"] as? String, marker)

        let history = PolyfenceDebugCollector.shared.getErrorHistory(timeRangeMs: nil, errorTypes: [marker])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["type"] as? String, marker)
    }

    func testHistoryPreservesCorrelationIdAcrossTheCallbackAndHistoryEntry() {
        // Parity nit from the peer review: history entry must carry
        // the same correlationId the callback sees, so consumers can
        // correlate a persisted row with a live onError event.
        let marker = "bug016_correlation_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        var callbackCorrelationId: String?
        PolyfenceErrorManager.shared.initialize { errorData in
            callbackCorrelationId = errorData["correlationId"] as? String
        }

        PolyfenceErrorManager.shared.reportError(
            type: marker,
            message: "test",
            context: [:]
        )

        let history = PolyfenceDebugCollector.shared.getErrorHistory(timeRangeMs: nil, errorTypes: [marker])
        XCTAssertEqual(history.count, 1)
        XCTAssertNotNil(callbackCorrelationId)
        XCTAssertEqual(history[0]["correlationId"] as? String, callbackCorrelationId)
    }

    func testHistoryIsPersistedBeforeTheCallbackRuns() {
        // Tannu's nit on PR #46 — Android version tests "callback
        // throws". Swift closures with a `Void` return type can't
        // `throw`, but the underlying concern (a subscriber crashing
        // mid-callback losing the history-write) still applies:
        // any trap / precondition-failure would kill the process
        // between the callback and the history-write in the OLD
        // ordering. The fix is the same: record BEFORE invoke.
        //
        // Since XCTest can't easily assert on a process-crash, we
        // assert the observable order instead: by the time the
        // callback fires, the history entry must already be present.
        let marker = "bug016_order_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        var historyEntriesAtCallbackTime = 0
        PolyfenceErrorManager.shared.initialize { _ in
            historyEntriesAtCallbackTime = PolyfenceDebugCollector.shared
                .getErrorHistory(timeRangeMs: nil, errorTypes: [marker]).count
        }

        PolyfenceErrorManager.shared.reportError(
            type: marker,
            message: "ordering probe",
            context: [:]
        )

        XCTAssertEqual(
            historyEntriesAtCallbackTime,
            1,
            "history entry must be written BEFORE the callback fires so a crashing callback doesn't lose it"
        )
    }

    func testErrorHistoryFiltersByType() {
        let gpsMarker = "bug016_gps_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        let batteryMarker = "bug016_battery_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        PolyfenceErrorManager.shared.reportError(type: gpsMarker, message: "gps 1")
        PolyfenceErrorManager.shared.reportError(type: batteryMarker, message: "batt 1")
        PolyfenceErrorManager.shared.reportError(type: gpsMarker, message: "gps 2")

        let onlyGps = PolyfenceDebugCollector.shared.getErrorHistory(timeRangeMs: nil, errorTypes: [gpsMarker])
        XCTAssertEqual(onlyGps.count, 2)
        XCTAssertTrue(onlyGps.allSatisfy { ($0["type"] as? String) == gpsMarker })

        let onlyBattery = PolyfenceDebugCollector.shared.getErrorHistory(timeRangeMs: nil, errorTypes: [batteryMarker])
        XCTAssertEqual(onlyBattery.count, 1)
        XCTAssertEqual(onlyBattery[0]["message"] as? String, "batt 1")
    }

    func testErrorHistoryTimeRangeFilterMatchesFreshEntries() {
        // The filter reads the stored `timestamp` through
        // `(NSNumber)?.doubleValue`. `PolyfenceErrorManager` writes it as
        // `Int64` inside a `[String: Any]` map, and a direct
        // `as? Double` bridge on that Int64 fails at runtime — every
        // entry then falls to the default of 0 and gets dropped from a
        // non-nil `timeRangeMs` window.
        let marker = "timerange_regression_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        PolyfenceErrorManager.shared.reportError(type: marker, message: "fresh")

        // 1-hour window covers the just-written entry.
        let history = PolyfenceDebugCollector.shared.getErrorHistory(
            timeRangeMs: 60 * 60 * 1000,
            errorTypes: [marker]
        )
        XCTAssertEqual(history.count, 1, "timeRangeMs filter must not drop entries stored as Int64 timestamps")
        XCTAssertEqual(history[0]["message"] as? String, "fresh")
        // Timestamp is readable via the same NSNumber bridge the filter
        // uses — pins the cast path rather than only the count.
        XCTAssertGreaterThan((history[0]["timestamp"] as? NSNumber)?.doubleValue ?? 0, 0)
    }

    func testErrorHistoryTimeRangeFilterExcludesEntriesOutsideWindow() {
        // Negative case pairs with the fresh-entries test: a 1ms window
        // must exclude entries that landed even a few ms earlier. This
        // proves the filter actually filters, not merely that it stops
        // rejecting everything — a reader that returned all entries
        // unconditionally would satisfy the positive test but fail here.
        let marker = "timerange_exclude_\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        PolyfenceErrorManager.shared.reportError(type: marker, message: "stale")
        // Sleep just past the 1ms window so the entry is outside cutoff.
        Thread.sleep(forTimeInterval: 0.010)
        let history = PolyfenceDebugCollector.shared.getErrorHistory(
            timeRangeMs: 1,
            errorTypes: [marker]
        )
        XCTAssertEqual(history.count, 0, "timeRangeMs window must exclude entries older than the cutoff")
    }
}

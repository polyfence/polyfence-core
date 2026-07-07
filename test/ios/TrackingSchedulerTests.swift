import XCTest
@testable import PolyfenceCore

/**
 * Swift mirror of the Kotlin `TrackingSchedulerTest` — coverage for
 * the getConfigMap ↔ updateConfig round-trip. Guards against
 * shape-drift and the configQueue snapshot pattern silently
 * inverting on the iOS side.
 *
 * `TrackingScheduler.shared` is a process-wide singleton with no
 * public reset method, so every test starts by clearing the config
 * (`updateConfig(nil)`) and reads the resulting state to establish a
 * known baseline.
 */
class TrackingSchedulerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset to the empty default so no test's leftover schedule
        // leaks into another. updateConfig(nil) drops all windows,
        // clears enabled, restores startImmediatelyIfInWindow to true.
        TrackingScheduler.shared.updateConfig(nil)
    }

    override func tearDown() {
        TrackingScheduler.shared.updateConfig(nil)
        super.tearDown()
    }

    // MARK: - getConfigMap default shape

    func testDefaultGetConfigMapReturnsStableThreeKeyShapeWithEmptyWindows() {
        let map = TrackingScheduler.shared.getConfigMap()

        XCTAssertEqual(
            Set(["enabled", "startImmediatelyIfInWindow", "timeWindows"]),
            Set(map.keys),
            "getConfigMap must expose the same three top-level keys the bridge accepts on write."
        )
        XCTAssertEqual(false, map["enabled"] as? Bool)
        XCTAssertEqual(true, map["startImmediatelyIfInWindow"] as? Bool)
        XCTAssertEqual(0, (map["timeWindows"] as? [Any])?.count)
    }

    // MARK: - Round-trip

    func testUpdateConfigWithFullTimeWindowRoundTripsThroughGetConfigMap() {
        let input: [String: Any] = [
            "enabled": true,
            "startImmediatelyIfInWindow": false,
            "timeWindows": [
                [
                    "startTime": ["hour": 9, "minute": 0],
                    "endTime": ["hour": 17, "minute": 30],
                    "daysOfWeek": [1, 2, 3, 4, 5]
                ]
            ]
        ]
        TrackingScheduler.shared.updateConfig(input)

        let output = TrackingScheduler.shared.getConfigMap()
        XCTAssertEqual(true, output["enabled"] as? Bool)
        XCTAssertEqual(false, output["startImmediatelyIfInWindow"] as? Bool)

        guard let windows = output["timeWindows"] as? [[String: Any]] else {
            XCTFail("timeWindows must survive as an array"); return
        }
        XCTAssertEqual(1, windows.count)

        let window = windows[0]
        // Swift parity guard for the TimeOfDay shape: the window MUST
        // expose startTime.hour / endTime.hour as nested maps, not a
        // flattened {startHour, startMinute, ...}. The TypeScript /
        // Dart TimeWindow interfaces on the bridges are pinned to
        // the nested shape.
        guard let startTime = window["startTime"] as? [String: Any] else {
            XCTFail("startTime must be a nested map"); return
        }
        XCTAssertEqual(9, startTime["hour"] as? Int)
        XCTAssertEqual(0, startTime["minute"] as? Int)

        guard let endTime = window["endTime"] as? [String: Any] else {
            XCTFail("endTime must be a nested map"); return
        }
        XCTAssertEqual(17, endTime["hour"] as? Int)
        XCTAssertEqual(30, endTime["minute"] as? Int)

        XCTAssertEqual([1, 2, 3, 4, 5], window["daysOfWeek"] as? [Int])
    }

    func testUpdateConfigWithNilResetsToDefaultShape() {
        // Seed with a real window first so we can prove the reset
        // actually clears it — a common bridge path calls
        // updateConfig(nil) as part of resetConfiguration().
        TrackingScheduler.shared.updateConfig([
            "enabled": true,
            "startImmediatelyIfInWindow": false,
            "timeWindows": [
                [
                    "startTime": ["hour": 8, "minute": 15],
                    "endTime": ["hour": 12, "minute": 45],
                    "daysOfWeek": [6, 7]
                ]
            ]
        ])
        XCTAssertEqual(true, TrackingScheduler.shared.getConfigMap()["enabled"] as? Bool)

        TrackingScheduler.shared.updateConfig(nil)

        let map = TrackingScheduler.shared.getConfigMap()
        XCTAssertEqual(false, map["enabled"] as? Bool)
        XCTAssertEqual(true, map["startImmediatelyIfInWindow"] as? Bool)
        XCTAssertEqual(0, (map["timeWindows"] as? [Any])?.count)
    }

    func testUpdateConfigWithMultipleWindowsPreservesThemAllInOrder() {
        let input: [String: Any] = [
            "enabled": true,
            "startImmediatelyIfInWindow": true,
            "timeWindows": [
                [
                    "startTime": ["hour": 6, "minute": 0],
                    "endTime": ["hour": 10, "minute": 0],
                    "daysOfWeek": [1, 3, 5]
                ],
                [
                    "startTime": ["hour": 18, "minute": 0],
                    "endTime": ["hour": 22, "minute": 0],
                    "daysOfWeek": [2, 4]
                ]
            ]
        ]
        TrackingScheduler.shared.updateConfig(input)

        guard let windows = TrackingScheduler.shared.getConfigMap()["timeWindows"] as? [[String: Any]] else {
            XCTFail("timeWindows missing"); return
        }
        XCTAssertEqual(2, windows.count)

        guard let firstStart = windows[0]["startTime"] as? [String: Any] else {
            XCTFail("first startTime missing"); return
        }
        XCTAssertEqual(6, firstStart["hour"] as? Int)

        guard let secondEnd = windows[1]["endTime"] as? [String: Any] else {
            XCTFail("second endTime missing"); return
        }
        XCTAssertEqual(22, secondEnd["hour"] as? Int)
    }

    func testUpdateConfigOmittingDaysOfWeekRoundTripsAsEmptyList() {
        // The bridge contract is that `daysOfWeek: []` means "every
        // day of the week". An emitted nil would be ambiguous —
        // TypeScript / Dart consumers can't distinguish "unset" from
        // "empty means all days". Stability guard mirrored from the
        // Kotlin TrackingSchedulerTest equivalent.
        let input: [String: Any] = [
            "enabled": true,
            "startImmediatelyIfInWindow": true,
            "timeWindows": [
                [
                    "startTime": ["hour": 0, "minute": 0],
                    "endTime": ["hour": 23, "minute": 59]
                    // daysOfWeek omitted — TimeWindow.fromMap defaults to []
                ]
            ]
        ]
        TrackingScheduler.shared.updateConfig(input)

        guard let windows = TrackingScheduler.shared.getConfigMap()["timeWindows"] as? [[String: Any]] else {
            XCTFail("timeWindows missing"); return
        }
        XCTAssertEqual([], windows[0]["daysOfWeek"] as? [Int])
    }
}

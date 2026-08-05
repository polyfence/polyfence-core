import XCTest
@testable import PolyfenceCore

/**
 * The score is only meaningful if every dimension it reports on was actually
 * measured. Its inputs arrive by name from the debug collector, and a name
 * that does not match resolves to zero — which for latency and error count is
 * the *best* possible reading. A silently-missing input therefore inflates the
 * result rather than depressing it, which is the failure direction nobody
 * notices.
 *
 * `testLatencyIsReadUnderTheNameTheCollectorPublishes` is the regression guard
 * for that: it fails if the key the tracker looks up ever drifts from the key
 * the collector emits.
 */
final class HealthScoreCalculatorTests: XCTestCase {

    private func score(
        gps: Double = 1.0,
        latencyMs: Double? = 0.0,
        errors: Int = 0,
        falseEvents: Double? = 0.0
    ) -> HealthScore {
        return HealthScoreCalculator.calculate(
            gpsGoodRatio: gps,
            avgDetectionLatencyMs: latencyMs,
            errorCountRecent: errors,
            falseEventRatio: falseEvents,
            isTracking: true,
            activeZoneCount: 5
        )
    }

    func testAPerfectDeviceScoresFull() {
        XCTAssertEqual(score().score, 100)
        XCTAssertNil(score().topIssue)
    }

    func testAFullyDegradedDeviceScoresZero() {
        let result = score(gps: 0.0, latencyMs: 9_000, errors: 50, falseEvents: 0.9)
        XCTAssertEqual(result.score, 0)
        XCTAssertNotNil(result.topIssue)
    }

    func testEachDimensionCarriesAQuarterOfTheScore() {
        // One dimension at zero, three perfect: the score loses exactly a
        // quarter. This is what pins the rescale — a fifth dimension silently
        // returning to the sum would change every number here.
        XCTAssertEqual(score(gps: 0.0).score, 75)
        XCTAssertEqual(score(latencyMs: 9_000).score, 75)
        XCTAssertEqual(score(errors: 50).score, 75)
        XCTAssertEqual(score(falseEvents: 0.9).score, 75)
    }

    func testAnUnmeasuredDimensionIsExcludedRatherThanScoredPerfect() {
        // No crossing detected yet: latency has no samples. Excluding it
        // leaves three dimensions, so a device perfect on those still reads
        // 100 — but a device *bad* on them cannot hide behind a free 25.
        XCTAssertEqual(score(latencyMs: nil).score, 100)
        XCTAssertEqual(score(gps: 0.0, latencyMs: nil).score, 67)
    }

    func testAnUnsampledFalseEventRatioSitsOutButGpsDoesNot() {
        // A false-event ratio with no detections behind it reads as the best
        // possible accuracy, so it sits out. GPS does not: this score is only
        // computed minutes into a session, by which point no fixes is a
        // failure rather than a device still warming up.
        XCTAssertEqual(score(falseEvents: nil).score, 100)
        XCTAssertEqual(score(gps: 0.0, falseEvents: nil).score, 67)
    }

    func testTheRescaleRoundsHalvesUp() {
        // Dimension totals that land on .5 once rescaled. Pinned because the
        // two platforms round through different standard-library calls and
        // must agree.
        XCTAssertEqual(score(gps: 0.5, latencyMs: 9_000, errors: 50, falseEvents: 0.9).score, 13)
        XCTAssertEqual(score(gps: 1.0, latencyMs: 400, errors: 4, falseEvents: 0.3).score, 63)
    }

    func testNotTrackingScoresZeroRegardlessOfEverythingElse() {
        let result = HealthScoreCalculator.calculate(
            gpsGoodRatio: 1.0,
            avgDetectionLatencyMs: 0.0,
            errorCountRecent: 0,
            falseEventRatio: 0.0,
            isTracking: false,
            activeZoneCount: 5
        )
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.topIssue, "Tracking is not active")
    }

    func testTopIssueNamesTheWorstDimensionNotMerelyAFailingOne() {
        // GPS is merely poor (loses 10 of 20); latency is at its floor
        // (loses 20). The worst one is the one worth telling a developer.
        let result = score(gps: 0.5, latencyMs: 9_000)
        XCTAssertEqual(result.topIssue?.contains("Detection latency"), true)
    }

    func testLatencyIsReadUnderTheNameTheCollectorPublishes() {
        let performance = PolyfenceDebugCollector.shared
            .collectDebugInfo()["performance"] as? [String: Any]
        // Presence, not value: the entry is null until a crossing has been
        // detected, and null is exactly what tells the score to leave the
        // dimension out rather than award it full marks.
        XCTAssertTrue(
            performance?.keys.contains("averageDetectionLatency") == true,
            "the tracker reads this key to score latency; a rename here scores a dimension nobody measured"
        )
    }
}

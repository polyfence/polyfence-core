import XCTest
@testable import PolyfenceCore

/**
 * Coverage that a consumer's confirmation settings actually reach the engine.
 *
 * `setupGeofenceEngine` previously passed literal `false, 1`, so on iOS a single
 * GPS fix inside a zone fired ENTER while Android — which reads the same two
 * values from config — required two. A consumer setting `requireConfirmation`
 * changed nothing on iOS, and the platforms disagreed about the same journey.
 *
 * These assert the wiring, not the confirmation algorithm itself: that lives in
 * `GeofenceEngineTests`. What matters here is that the values the tracker hands
 * the engine are the consumer's, and that they match Kotlin's defaults when the
 * consumer sets nothing.
 */
class ValidationConfigWiringTests: XCTestCase {

    private let requireKey = "require_confirmation"
    private let pointsKey = "confidence_points"

    /// `PolyfenceConfig` persists into its own named suite, not
    /// `UserDefaults.standard` — writing to the wrong store here would exercise
    /// the nil-config fallback and let these pass without the wiring existing.
    private let configDefaults = UserDefaults(suiteName: "polyfence_config")!

    override func setUp() {
        super.setUp()
        clearValidationDefaults()
    }

    override func tearDown() {
        clearValidationDefaults()
        super.tearDown()
    }

    /// Validation settings persist in the config suite, which outlives a
    /// test case — a leftover value would let one of these pass for the wrong
    /// reason, so both ends of every case start from a known baseline.
    private func clearValidationDefaults() {
        configDefaults.removeObject(forKey: requireKey)
        configDefaults.removeObject(forKey: pointsKey)
    }

    func testTrackerForwardsConsumerConfirmationSettingsToTheEngine() {
        configDefaults.set(true, forKey: requireKey)
        configDefaults.set(3, forKey: pointsKey)

        let tracker = LocationTracker()
        let applied = tracker.geofenceEngineForOsGeofence._testValidationConfig()

        XCTAssertTrue(
            applied.requireConfirmation,
            "A consumer asking for confirmation must get it — this was hardcoded false"
        )
        XCTAssertEqual(
            applied.confirmationPoints, 3,
            "The consumer's point count must survive to the engine — this was hardcoded 1"
        )
    }

    func testConfirmationCanStillBeTurnedOffByTheConsumer() {
        configDefaults.set(false, forKey: requireKey)
        configDefaults.set(1, forKey: pointsKey)

        let tracker = LocationTracker()
        let applied = tracker.geofenceEngineForOsGeofence._testValidationConfig()

        XCTAssertFalse(applied.requireConfirmation)
        XCTAssertEqual(applied.confirmationPoints, 1)
    }

    func testDefaultsMatchAndroidWhenTheConsumerSetsNothing() {
        let tracker = LocationTracker()
        let applied = tracker.geofenceEngineForOsGeofence._testValidationConfig()

        XCTAssertTrue(
            applied.requireConfirmation,
            "Kotlin defaults requireConfirmation to true; iOS must not diverge"
        )
        XCTAssertEqual(
            applied.confirmationPoints, PolyfenceConfig.DEFAULT_CONFIDENCE_POINTS,
            "Both platforms default to two-point confirmation"
        )
    }
}

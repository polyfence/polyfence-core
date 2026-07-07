package io.polyfence.core

import io.polyfence.core.configuration.ActivitySettings
import io.polyfence.core.configuration.SmartGpsConfig
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Shape and default-value coverage for `getCurrentConfigurationMap`
 * and `buildDefaultConfigurationMap`. `getConfiguration()` must
 * return the full 12-key `PolyfenceConfiguration` shape — including
 * the five settings (`gpsAccuracyThreshold`, `dwellSettings`,
 * `clusterSettings`, `scheduleSettings`, `activitySettings`) that
 * live outside `SmartGpsConfig` — so bridges can cache and re-apply
 * the full configuration surface. Bridges use
 * `buildDefaultConfigurationMap` as the payload for
 * `resetConfiguration()`; a reset must walk through every subsystem,
 * not only the six keys `SmartGpsConfig` defines.
 *
 * The tests are pure-Kotlin unit tests (no Robolectric / Context
 * required for the code paths they exercise) — the fixtures cover
 * (a) the buildDefaultConfigurationMap companion helper and
 * (b) the null-context fallback branch of getCurrentConfigurationMap.
 */
class LocationTrackerConfigTest {

    /**
     * Reset the process-wide companion static state that
     * `LocationTracker.getCurrentConfigurationMap(null)` reads. This
     * class shares statics with `LocationTrackerUpdateConfigTest`
     * (Robolectric-hosted) — a case that asserts scheduler state in
     * the null-context fallback would flake when a prior test left
     * `trackingScheduler` populated. Reset the alerts flag AND null
     * out the scheduler via reflection so every case starts from a
     * known baseline.
     */
    @Before
    fun resetCompanionStaticsBeforeEachTest() {
        LocationTracker.setAlertNotificationsEnabled(true)

        // `trackingScheduler` is private to the LocationTracker
        // companion; nothing public zeros it. Reach past visibility
        // rather than expose test-only API on the production class.
        val companionInstance = LocationTracker::class.java
            .getDeclaredField("Companion")
            .apply { isAccessible = true }
            .get(null)
        LocationTracker::class.java
            .getDeclaredField("trackingScheduler")
            .apply { isAccessible = true }
            .set(companionInstance, null)
    }

    private val expectedTopLevelKeys = setOf(
        "accuracyProfile",
        "updateStrategy",
        "enableDebugLogging",
        "proximitySettings",
        "movementSettings",
        "batterySettings",
        "gpsAccuracyThreshold",
        "dwellSettings",
        "clusterSettings",
        "scheduleSettings",
        "activitySettings",
        "disableAlertNotifications"
    )

    // -------- buildDefaultConfigurationMap --------

    @Test
    fun `buildDefaultConfigurationMap emits every top-level key that PolyfenceConfiguration documents`() {
        val map = LocationTracker.buildDefaultConfigurationMap()

        assertEquals(
            "resetConfiguration must send a payload covering every subsystem — " +
                "any missing key silently skips the corresponding reset branch " +
                "in updateConfigurationFromMap.",
            expectedTopLevelKeys,
            map.keys
        )
    }

    @Test
    fun `buildDefaultConfigurationMap uses the same defaults as SmartGpsConfig`() {
        val map = LocationTracker.buildDefaultConfigurationMap()
        val defaults = SmartGpsConfig()

        assertEquals(defaults.accuracyProfile.name, map["accuracyProfile"])
        assertEquals(defaults.updateStrategy.name, map["updateStrategy"])
        assertEquals(defaults.enableDebugLogging, map["enableDebugLogging"])
    }

    @Test
    fun `buildDefaultConfigurationMap emits engine defaults for gpsAccuracyThreshold, dwell, and cluster`() {
        val map = LocationTracker.buildDefaultConfigurationMap()

        assertEquals(
            GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD.toDouble(),
            map["gpsAccuracyThreshold"]
        )

        @Suppress("UNCHECKED_CAST")
        val dwell = map["dwellSettings"] as Map<String, Any>
        assertEquals(true, dwell["enabled"])
        assertEquals(GeofenceEngine.DEFAULT_DWELL_THRESHOLD_MS, dwell["dwellThresholdMs"])

        @Suppress("UNCHECKED_CAST")
        val cluster = map["clusterSettings"] as Map<String, Any>
        assertEquals(false, cluster["enabled"])
        assertEquals(
            GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS,
            cluster["activeRadiusMeters"]
        )
        assertEquals(
            GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS,
            cluster["refreshDistanceMeters"]
        )
    }

    @Test
    fun `buildDefaultConfigurationMap emits a schedule with no time windows`() {
        val map = LocationTracker.buildDefaultConfigurationMap()

        @Suppress("UNCHECKED_CAST")
        val schedule = map["scheduleSettings"] as Map<String, Any>
        assertEquals(false, schedule["enabled"])
        assertEquals(true, schedule["startImmediatelyIfInWindow"])
        assertEquals(emptyList<Any>(), schedule["timeWindows"])
    }

    @Test
    fun `buildDefaultConfigurationMap emits the full 8-key activitySettings block with defaults`() {
        val map = LocationTracker.buildDefaultConfigurationMap()

        @Suppress("UNCHECKED_CAST")
        val activity = map["activitySettings"] as Map<String, Any>
        // The activitySettings block must always include every
        // documented interval field with a materialised default —
        // stripping nulls leaves the block with a sparse shape that
        // TypeScript / Dart consumers can still read but the composed
        // accessor no longer promises shape stability for.
        assertEquals(
            setOf(
                "enabled",
                "confidenceThreshold",
                "debounceSeconds",
                "stillIntervalMs",
                "walkingIntervalMs",
                "runningIntervalMs",
                "cyclingIntervalMs",
                "drivingIntervalMs"
            ),
            activity.keys
        )
        assertEquals(false, activity["enabled"])
        assertEquals(75, activity["confidenceThreshold"])
        assertEquals(30, activity["debounceSeconds"])
        assertEquals(ActivitySettings.DEFAULT_STILL_INTERVAL_MS, activity["stillIntervalMs"])
        assertEquals(ActivitySettings.DEFAULT_WALKING_INTERVAL_MS, activity["walkingIntervalMs"])
        assertEquals(ActivitySettings.DEFAULT_RUNNING_INTERVAL_MS, activity["runningIntervalMs"])
        assertEquals(ActivitySettings.DEFAULT_CYCLING_INTERVAL_MS, activity["cyclingIntervalMs"])
        assertEquals(ActivitySettings.DEFAULT_DRIVING_INTERVAL_MS, activity["drivingIntervalMs"])
    }

    @Test
    fun `buildDefaultConfigurationMap defaults disableAlertNotifications to false`() {
        val map = LocationTracker.buildDefaultConfigurationMap()

        // `disableAlertNotifications = false` is the same as
        // "alert notifications enabled" — the SDK's shipping
        // default. If this ever flips, docs and telemetry need to
        // update too.
        assertEquals(false, map["disableAlertNotifications"])
    }

    @Test
    fun `getCurrentConfigurationMap reflects setAlertNotificationsEnabled flips (READ side only)`() {
        // Covers only the READ side: given the companion setter is
        // called (as `updateConfigurationFromMap` does at its
        // `disableAlertNotifications` branch, and as `initialize()`
        // does), the composed getConfiguration map reflects it. The
        // WRITE path (`updateConfigurationFromMap` actually invoking
        // the setter) is a private instance method requiring a
        // `Context` — not exercisable in a pure JVM unit test without
        // Robolectric. That coverage lives in the integration / device
        // test; a proxy here would give false confidence.
        // Baseline: alerts default to ENABLED, so the map's
        // `disableAlertNotifications` should be false.
        val baselineMap = LocationTracker.getCurrentConfigurationMap(null)
        assertEquals(false, baselineMap["disableAlertNotifications"])

        // Flip: disable alerts. Spelling the intent out with a literal
        // rather than relying on the reader inverting a captured
        // "originalFlag" value.
        LocationTracker.setAlertNotificationsEnabled(false)

        val disabledMap = LocationTracker.getCurrentConfigurationMap(null)
        assertEquals(true, disabledMap["disableAlertNotifications"])

        // Restore state — the companion is process-wide static, so
        // leaving alerts disabled would leak into other test cases
        // in the same run.
        LocationTracker.setAlertNotificationsEnabled(true)
    }

    // -------- getCurrentConfigurationMap null-context fallback --------

    @Test
    fun `getCurrentConfigurationMap with null context still returns the full 12-key shape`() {
        // With a null context and no running service, the composed
        // accessor should fall back to engine + scheduler defaults
        // and never omit a key. Shape stability is the whole point
        // of returning `disableAlertNotifications = false` when
        // nobody has flipped the flag yet.
        val map = LocationTracker.getCurrentConfigurationMap(null)

        assertEquals(expectedTopLevelKeys, map.keys)
    }

    @Test
    fun `getCurrentConfigurationMap null-context schedule falls back to an empty windows list, not a runtime error`() {
        // An early call to getConfiguration before setScheduleConfig
        // has ever been invoked must not NPE on a null trackingScheduler.
        // The null-context branch returns a safe empty shape.
        val map = LocationTracker.getCurrentConfigurationMap(null)

        @Suppress("UNCHECKED_CAST")
        val schedule = map["scheduleSettings"] as Map<String, Any>
        assertEquals(false, schedule["enabled"])
        assertEquals(true, schedule["startImmediatelyIfInWindow"])
        assertEquals(emptyList<Any>(), schedule["timeWindows"])
    }

    @Test
    fun `getCurrentConfigurationMap null-context returns Double gpsAccuracyThreshold for cross-platform parity`() {
        // The engine internally stores Float; the composed accessor
        // widens to Double at the map boundary so React Native and
        // Flutter bridges receive the same numeric type Swift emits.
        val map = LocationTracker.getCurrentConfigurationMap(null)

        assertTrue(
            "gpsAccuracyThreshold must marshal as Double for RN/Flutter parity",
            map["gpsAccuracyThreshold"] is Double
        )
    }
}

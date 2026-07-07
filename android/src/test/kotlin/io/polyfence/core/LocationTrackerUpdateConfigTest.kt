package io.polyfence.core

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * End-to-end write-path coverage for the composed
 * `LocationTracker.updateConfigurationFromMap`. Runs under Robolectric
 * so the LocationTracker Service can actually be constructed with a
 * Context — pure-JVM unit tests can't exercise the private instance
 * method that receives the Intent handler's map.
 *
 * **Scope covered here:** `disableAlertNotifications` writes flip the
 * companion flag, omissions preserve state, ill-typed values fall
 * through, and the `buildDefaultConfigurationMap` reset payload
 * restores the default.
 *
 * **NOT covered here:** end-to-end round-trip assertions for dwell /
 * cluster / schedule / activity write paths. Those flow through
 * GeofenceEngine / TrackingScheduler / activitySettings mutations
 * that this file doesn't yet verify — shape stability for those keys
 * is covered by the pure-JVM `LocationTrackerConfigTest`, but the
 * write→read integration path still deserves its own Robolectric
 * group.
 *
 * The tests build the Service via [Robolectric.buildService], call
 * the lifecycle callback (`onCreate`), and use reflection to invoke
 * the private `updateConfigurationFromMap`. That's the minimum
 * ceremony to exercise the exact code path the Intent handler runs —
 * anything less would be a proxy.
 */
@RunWith(RobolectricTestRunner::class)
class LocationTrackerUpdateConfigTest {

    private lateinit var tracker: LocationTracker

    @Before
    fun setUp() {
        // Reset the alerts flag between tests — the companion is
        // process-wide so a previous test's flip would leak.
        LocationTracker.setAlertNotificationsEnabled(true)

        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
    }

    /**
     * Reflection helper — updateConfigurationFromMap is private on the
     * instance; we deliberately reach past that visibility here. The
     * alternative (publicising it for tests) would leak test concerns
     * into the production API surface.
     */
    private fun invokeUpdateConfigurationFromMap(configMap: Map<String, Any>) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "updateConfigurationFromMap",
            Map::class.java
        )
        method.isAccessible = true
        method.invoke(tracker, configMap)
    }

    // -------- disableAlertNotifications write-side coverage --------

    @Test
    fun `updateConfigurationFromMap flips alertNotificationsEnabled when disableAlertNotifications is true`() {
        // Guard: default is alerts ENABLED (disableAlertNotifications=false).
        val before = LocationTracker.getCurrentConfigurationMap(null)
        assertEquals(false, before["disableAlertNotifications"])

        invokeUpdateConfigurationFromMap(mapOf("disableAlertNotifications" to true))

        val after = LocationTracker.getCurrentConfigurationMap(null)
        assertEquals(
            true,
            after["disableAlertNotifications"],
            /* message intentionally omitted — the assert diff is enough */
        )
    }

    @Test
    fun `updateConfigurationFromMap flips alertNotificationsEnabled back to enabled when disableAlertNotifications is false`() {
        // Start from alerts disabled.
        LocationTracker.setAlertNotificationsEnabled(false)
        assertEquals(true, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])

        invokeUpdateConfigurationFromMap(mapOf("disableAlertNotifications" to false))

        assertEquals(false, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])
    }

    @Test
    fun `updateConfigurationFromMap omitting disableAlertNotifications leaves the flag unchanged`() {
        // Set a non-default state so we can prove the omission preserves it.
        LocationTracker.setAlertNotificationsEnabled(false)
        assertEquals(true, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])

        // Update something else entirely — no disableAlertNotifications
        // key present.
        invokeUpdateConfigurationFromMap(mapOf("enableDebugLogging" to true))

        // The write path must only apply the flag when the caller
        // sent it; omitting the key must never mutate the current
        // state.
        assertEquals(true, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])
    }

    @Test
    fun `updateConfigurationFromMap ignores a non-Boolean value for disableAlertNotifications`() {
        // Set a non-default state so we can prove ill-typed input
        // doesn't clobber it.
        LocationTracker.setAlertNotificationsEnabled(false)

        // Pass a string instead of a boolean — the `as? Boolean` cast
        // falls through and no write happens. Consistent with how
        // every other extras key handles wrong types.
        invokeUpdateConfigurationFromMap(mapOf("disableAlertNotifications" to "true"))

        assertEquals(true, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])
    }

    // -------- full reset round-trip via buildDefaultConfigurationMap --------

    @Test
    fun `buildDefaultConfigurationMap applied via updateConfigurationFromMap restores alertNotificationsEnabled`() {
        // Set alerts off, then apply the reset payload and verify the
        // flag was flipped back on. This is the exact flow that
        // resetConfiguration() runs on the bridges.
        LocationTracker.setAlertNotificationsEnabled(false)
        assertEquals(true, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])

        invokeUpdateConfigurationFromMap(LocationTracker.buildDefaultConfigurationMap())

        assertEquals(false, LocationTracker.getCurrentConfigurationMap(null)["disableAlertNotifications"])
    }
}

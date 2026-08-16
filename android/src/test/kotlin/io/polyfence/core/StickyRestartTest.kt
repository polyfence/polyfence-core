package io.polyfence.core

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * Coverage for the platform restarting this service after the process died.
 *
 * `START_STICKY` redelivers a **null** intent, so the action dispatch that
 * every other entry point relies on matches nothing. Left unhandled, the
 * restart produced a foreground service showing a tracking notification while
 * tracking nothing — no GPS request, no zones, no reconcile. The failure is
 * silent and self-concealing: every downstream check reads the service as
 * healthy, including the OS-wake receiver's already-running gate, so a wake
 * defers to an engine that is inert.
 *
 * This is the ordinary case on a phone under memory pressure, not an edge one,
 * and it happens on every process death rather than only a geofence-triggered
 * wake.
 *
 * Resumption is conditional on the consumer's recorded instruction, so a
 * deliberate `stopTracking()` survives a restart rather than being undone by
 * it.
 */
@RunWith(RobolectricTestRunner::class)
class StickyRestartTest {

    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        // The restart path checks the same permission gate startTracking does;
        // without these it declines for the right reason but the wrong one for
        // what these cases are asserting.
        shadowOf(ApplicationProvider.getApplicationContext<Application>()).grantPermissions(
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.ACCESS_COARSE_LOCATION
        )
        clearTrackingIntent()
    }

    @After
    fun tearDown() {
        clearTrackingIntent()
    }

    private fun clearTrackingIntent() {
        context.getSharedPreferences(
            LocationTracker.TRACKING_PREFS_NAME,
            Context.MODE_PRIVATE
        ).edit().clear().commit()
    }

    private fun setTrackingIntended(intended: Boolean) {
        context.getSharedPreferences(
            LocationTracker.TRACKING_PREFS_NAME,
            Context.MODE_PRIVATE
        ).edit().putBoolean(LocationTracker.TRACKING_ACTIVE_KEY, intended).commit()
    }

    /** Drives the null-intent restart the platform performs, and reports whether tracking came back. */
    private fun restartAfterProcessDeath(): Boolean {
        val controller = Robolectric.buildService(LocationTracker::class.java).create()
        controller.get().onStartCommand(null, 0, 1)
        return LocationTracker.isRunning
    }

    @Test
    fun `a restart resumes tracking when the consumer had it on`() {
        setTrackingIntended(true)

        assertTrue(
            "A service restarted after process death must resume tracking, not sit "
                + "in the foreground doing nothing",
            restartAfterProcessDeath()
        )
    }

    @Test
    fun `a restart does not resume tracking the consumer had switched off`() {
        setTrackingIntended(false)

        assertFalse(
            "A deliberate stopTracking must survive a restart",
            restartAfterProcessDeath()
        )
    }

    @Test
    fun `a restart on a fresh install does not start tracking`() {
        // No recorded instruction at all — the absent case must read as "off",
        // not as "resume".
        clearTrackingIntent()

        assertFalse(restartAfterProcessDeath())
    }
}

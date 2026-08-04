package io.polyfence.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * The exact set of keys `debugInfo()` returns, pinned.
 *
 * Consumers read this payload through typed classes on both bridges, so a key
 * that appears or disappears without the bridges moving with it is a silent
 * break: a removed key reads as its type's default, which is
 * indistinguishable from a genuine zero. Asserting the whole set rather than
 * individual fields means a rename, an accidental deletion and a well-meaning
 * addition all fail here first.
 *
 * A field belongs in this payload only if it carries a real measurement.
 * Fields iOS reports as null are present here with real values wherever
 * Android can measure them — that asymmetry is deliberate, and the iOS
 * counterpart of this test pins it from the other side.
 */
@RunWith(RobolectricTestRunner::class)
class PolyfenceDebugCollectorShapeTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun debugInfo(): Map<String, Any> {
        var result: Map<String, Any>? = null
        var failure: Throwable? = null
        val worker = Thread {
            try {
                result = PolyfenceDebugCollector.collectDebugInfo(context)
            } catch (e: Throwable) {
                failure = e
            }
        }
        worker.start()
        worker.join()
        failure?.let { throw it }
        return result!!
    }

    @Suppress("UNCHECKED_CAST")
    private fun keys(section: String): Set<String> =
        (debugInfo()[section] as Map<String, Any?>).keys

    @Test
    fun `top level sections are stable`() {
        assertEquals(
            setOf("systemStatus", "performance", "battery", "zones", "recentErrors"),
            debugInfo().keys
        )
    }

    @Test
    fun `system status keys are stable`() {
        assertEquals(
            setOf(
                "isLocationPermissionGranted",
                "isBackgroundLocationEnabled",
                "isBatteryOptimizationDisabled",
                "isGpsEnabled",
                "isWakeLockAcquired",
                "lastKnownAccuracy",
                "lastLocationUpdate",
                "platformVersion",
                "pluginVersion",
                "osGeofenceRegistrationHealth"
            ),
            keys("systemStatus")
        )
    }

    @Test
    fun `performance keys are stable`() {
        assertEquals(
            setOf(
                "uptime",
                "totalLocationUpdates",
                "totalZoneDetections",
                "averageDetectionLatency",
                "memoryUsageMB",
                "restartCount"
            ),
            keys("performance")
        )
    }

    @Test
    fun `battery keys are stable`() {
        assertEquals(
            setOf("isCharging", "batteryLevel", "totalActiveTime"),
            keys("battery")
        )
    }

    @Test
    fun `zone keys are stable`() {
        assertEquals(
            setOf("activeZones", "circleZones", "polygonZones"),
            keys("zones")
        )
    }

    /**
     * The counterpart of the iOS assertion that these are null. Android can
     * measure them, so a null here would mean the measurement broke rather
     * than that the platform lacks the concept.
     */
    @Test
    fun `fields with no ios equivalent carry real values on android`() {
        val status = debugInfo()["systemStatus"] as Map<*, *>
        assertTrue(status["isBatteryOptimizationDisabled"] is Boolean)

        val performance = debugInfo()["performance"] as Map<*, *>
        assertTrue(performance["restartCount"] is Int)
    }

    /**
     * Wake-lock state is a property of the running service. With no service
     * there is nothing that could be holding a lock, and `false` would be a
     * claim about a lock that does not exist — so the honest answer is
     * nothing at all. Once the service is up the answer is a real reading
     * taken from the lock itself.
     */
    @Test
    fun `wake lock state is absent without a service and real with one`() {
        val withoutService = debugInfo()["systemStatus"] as Map<*, *>
        assertNull(withoutService["isWakeLockAcquired"])

        val controller = Robolectric.buildService(LocationTracker::class.java).create()
        try {
            val withService = debugInfo()["systemStatus"] as Map<*, *>
            assertTrue(withService["isWakeLockAcquired"] is Boolean)
        } finally {
            controller.destroy()
        }
    }
}

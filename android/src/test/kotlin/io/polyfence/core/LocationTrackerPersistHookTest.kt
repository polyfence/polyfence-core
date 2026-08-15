package io.polyfence.core

import android.content.Context
import android.location.Location
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * Integration coverage for the persist-hook inside `LocationTracker.handleGeofenceEvent`.
 * Verifies that a fired geofence event lands in `PendingEventsStore` exactly when
 * `pendingEventsQueueSize > 0` AND the delegate is either missing or `bridgeAttached`
 * is false — the coordination contract that makes the durable queue useful.
 *
 * Runs under Robolectric so `LocationTracker` can be constructed with a real Context.
 * The private `handleGeofenceEvent` is reached via reflection — same pattern as
 * `LocationTrackerUpdateConfigTest`. Store field is `internal` so drain is exercised
 * through the public companion helper.
 */
@RunWith(RobolectricTestRunner::class)
class LocationTrackerPersistHookTest {

    private lateinit var context: Context
    private lateinit var tracker: LocationTracker
    private lateinit var storeDir: File

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        storeDir = File(context.noBackupFilesDir, "pending_events")
        storeDir.deleteRecursively()
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
    }

    @After
    fun tearDown() {
        storeDir.deleteRecursively()
    }

    // Both helpers below reach past private visibility via reflection to exercise
    // the exact code path the running Service invokes. The alternatives —
    // widening these methods to internal / public, or driving them through the
    // full Intent + fused-location callback chain — would either leak test
    // concerns into the production API or add far more setup than the seam
    // being covered. Matches the pattern in LocationTrackerUpdateConfigTest.

    private fun invokeUpdateConfigurationFromMap(configMap: Map<String, Any>) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "updateConfigurationFromMap",
            Map::class.java
        )
        method.isAccessible = true
        method.invoke(tracker, configMap)
    }

    private fun invokeHandleGeofenceEvent(zoneId: String, eventType: String) {
        val location = Location("test").apply {
            latitude = 51.5
            longitude = -0.1
        }
        val method = LocationTracker::class.java.getDeclaredMethod(
            "handleGeofenceEvent",
            String::class.java,
            String::class.java,
            Location::class.java,
            Double::class.javaPrimitiveType
        )
        method.isAccessible = true
        method.invoke(tracker, zoneId, eventType, location, 5.0)
    }

    /**
     * A no-op delegate stub — represents the "bridge is registered" case.
     * The persist-hook checks `coreDelegate == null || !bridgeAttached`;
     * without a stub, `coreDelegate == null` always short-circuits to
     * persist and the bridge-attached signal cannot be isolated.
     */
    private class NoopDelegate : PolyfenceCoreDelegate {
        override fun onGeofenceEvent(eventData: Map<String, Any>) {}
        override fun onLocationUpdate(locationData: Map<String, Any>) {}
        override fun onPerformanceEvent(performanceData: Map<String, Any>) {}
        override fun onError(errorData: Map<String, Any>) {}
        override fun isTrackingEnabled(): Boolean = true
    }

    @Test
    fun `event persists when queue is enabled and no delegate is registered`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)

        invokeHandleGeofenceEvent("zone-1", "ENTER")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("zone-1", drained[0]["zoneId"])
        assertEquals("ENTER", drained[0]["eventType"])
    }

    @Test
    fun `event persists when delegate is set but bridge is not attached`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())
        tracker.setBridgeAttached(false)

        invokeHandleGeofenceEvent("zone-1", "EXIT")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("zone-1", drained[0]["zoneId"])
    }

    @Test
    fun `event does NOT persist when delegate is set and bridge is attached (live delivery)`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())
        tracker.setBridgeAttached(true)
        // Stated rather than inherited from setCoreDelegate's side effect, so
        // this reads as the all-three-conditions case it is meant to cover.
        tracker.setEventListenerActive(true)

        invokeHandleGeofenceEvent("zone-1", "ENTER")

        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    /**
     * A registered delegate and a wired sink are not enough. When the consumer
     * has unsubscribed, the bridge emits into an empty subscriber list and the
     * crossing is destroyed, so the queue is the only place it can survive.
     * This is the case a bridge reports through `setEventListenerActive`, and
     * the one that produces a fired OS notification with nothing in the log.
     */
    @Test
    fun `event persists when the bridge is attached but no listener is active`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())
        tracker.setBridgeAttached(true)
        tracker.setEventListenerActive(false)

        invokeHandleGeofenceEvent("zone-1", "ENTER")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("zone-1", drained[0]["zoneId"])
        assertEquals("ENTER", drained[0]["eventType"])
    }

    @Test
    fun `listener toggle takes effect between fires`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(false)
        invokeHandleGeofenceEvent("queued-1", "ENTER")
        val queued = LocationTracker.drainPendingEvents(context)
        assertEquals(1, queued.size)
        assertEquals("queued-1", queued[0]["zoneId"])

        // Raised after the drain above, so the replay this triggers has nothing
        // to hand back and cannot mask the live-delivery assertion below.
        tracker.setEventListenerActive(true)
        invokeHandleGeofenceEvent("live-1", "EXIT")
        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    @Test
    fun `event does NOT persist when queue size is zero`() {
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)

        invokeHandleGeofenceEvent("zone-1", "ENTER")

        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    @Test
    fun `bridge-attached toggle takes effect between fires`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())

        tracker.setBridgeAttached(true)
        invokeHandleGeofenceEvent("live-1", "ENTER")
        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())

        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("queued-1", "EXIT")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("queued-1", drained[0]["zoneId"])
    }

    /**
     * A delegate whose onGeofenceEvent always throws — a broken bridge
     * sink (e.g. Flutter EventSink.success off the main thread →
     * IllegalStateException) that the tracker must catch and auto-flip
     * bridgeAttached to persist rather than propagate.
     */
    private class ThrowingDelegate : PolyfenceCoreDelegate {
        override fun onGeofenceEvent(eventData: Map<String, Any>) {
            throw IllegalStateException("simulated sink failure")
        }
        override fun onLocationUpdate(locationData: Map<String, Any>) {}
        override fun onPerformanceEvent(performanceData: Map<String, Any>) {}
        override fun onError(errorData: Map<String, Any>) {}
        override fun isTrackingEnabled(): Boolean = true
    }

    @Test
    fun `companion setBridgeAttached delegates to the live instance`() {
        // Companion wrapper is the entry point platform bridges call so they
        // don't have to reach past the private `currentInstance` field. It
        // mirrors the existing setBridgePlatform / setPendingCoreDelegate
        // shape — routes to the running instance when present, stages a
        // pending value otherwise. This test proves the live-delegation half.
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(NoopDelegate())

        LocationTracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("companion-1", "ENTER")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("companion-1", drained[0]["zoneId"])
    }

    @Test
    fun `delegate throw persists the event and auto-flips bridgeAttached to false`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(ThrowingDelegate())
        tracker.setBridgeAttached(true)

        invokeHandleGeofenceEvent("throw-1", "ENTER")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("throw-1", drained[0]["zoneId"])

        // Subsequent fires must go straight to queue because bridgeAttached
        // was auto-flipped to false by the exception path — no need for the
        // bridge to explicitly call setBridgeAttached(false) on a crash.
        invokeHandleGeofenceEvent("throw-2", "EXIT")
        val drainedAgain = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drainedAgain.size)
        assertEquals("throw-2", drainedAgain[0]["zoneId"])
    }

}

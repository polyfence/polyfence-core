package io.polyfence.core

import android.content.Context
import android.location.Location
import androidx.test.core.app.ApplicationProvider
import io.polyfence.core.utils.PolyfenceConfig
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * Coverage for automatic delivery of the durable pending-events queue.
 *
 * The load-bearing property is the one `noDeliveryWhileOnlyTheBridgeSinkIsAttached`
 * asserts: a bridge attaching its platform-channel sink is NOT a listener, and
 * replaying into that window puts the events somewhere nobody is subscribed.
 *
 * Runs under Robolectric so `LocationTracker` can be constructed with a real
 * Context. Private members are reached via reflection — same pattern as
 * `LocationTrackerPersistHookTest`.
 */
@RunWith(RobolectricTestRunner::class)
class PendingEventsAutoDrainTest {

    private lateinit var context: Context
    private lateinit var tracker: LocationTracker
    private lateinit var storeDir: File
    private lateinit var collector: CollectingDelegate

    /** Stands in for a bridge's delivery sink; records what core hands over. */
    private class CollectingDelegate : PolyfenceCoreDelegate {
        val received = mutableListOf<Map<String, Any>>()
        override fun onGeofenceEvent(eventData: Map<String, Any>) {
            received.add(eventData)
        }
        override fun onLocationUpdate(locationData: Map<String, Any>) {}
        override fun onPerformanceEvent(performanceData: Map<String, Any>) {}
        override fun onError(errorData: Map<String, Any>) {}
        override fun isTrackingEnabled(): Boolean = true
    }

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        storeDir = File(context.noBackupFilesDir, "pending_events")
        storeDir.deleteRecursively()
        // The staged signal and the config suite are process-wide and outlive an
        // individual test, so a value left behind by another one would decide
        // this one's outcome.
        clearStagedListenerSignal()
        PolyfenceConfig(context).resetToDefaults()
        collector = CollectingDelegate()
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
    }

    @After
    fun tearDown() {
        storeDir.deleteRecursively()
        clearStagedListenerSignal()
        LocationTracker.setPendingCoreDelegate(null)
        PolyfenceConfig(context).resetToDefaults()
    }

    // --- reflection seams ---

    private fun clearStagedListenerSignal() {
        val field = LocationTracker::class.java.getDeclaredField("pendingEventListenerActive")
        field.isAccessible = true
        field.set(null, null)
    }

    private fun invokeUpdateConfigurationFromMap(configMap: Map<String, Any>) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "updateConfigurationFromMap",
            Map::class.java
        )
        method.isAccessible = true
        method.invoke(tracker, configMap)
    }

    private fun invokeHandleGeofenceEvent(zoneId: String, eventType: String) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "handleGeofenceEvent",
            String::class.java,
            String::class.java,
            Location::class.java,
            Double::class.javaPrimitiveType
        )
        method.isAccessible = true
        method.invoke(tracker, zoneId, eventType, locationAt(51.5, -0.1), 5.0)
    }

    /**
     * Stands in for the `startTracking()` step that loads zones and their
     * persisted membership. A replay is held back until this has run, so
     * without it every auto-drain assertion would be vacuously true.
     */
    private fun invokeRestoreZonesFromStorage() {
        val method = LocationTracker::class.java.getDeclaredMethod("restoreZonesFromStorage")
        method.isAccessible = true
        method.invoke(tracker)
    }

    private fun forceEngineRecoveredFromPersistence(engine: GeofenceEngine) {
        val field = GeofenceEngine::class.java.getDeclaredField("stateRecoveredFromPersistence")
        field.isAccessible = true
        field.setBoolean(engine, true)
    }

    private fun locationAt(lat: Double, lng: Double): Location = Location("test").apply {
        latitude = lat
        longitude = lng
    }

    private fun circleAt(lat: Double, lng: Double): Map<String, Any> = mapOf(
        "type" to "circle",
        "center" to mapOf("latitude" to lat, "longitude" to lng),
        "radius" to 100.0
    )

    /**
     * Queue `count` events without a live listener, then put the tracker in the
     * state a consumer resumes into: zones restored, sink attached, delegate
     * registered, nothing subscribed yet.
     */
    private fun queueEventsAndResume(vararg events: Pair<String, String>) {
        LocationTracker.setEventListenerActive(false)
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        events.forEach { (zoneId, eventType) -> invokeHandleGeofenceEvent(zoneId, eventType) }

        invokeRestoreZonesFromStorage()
        tracker.setCoreDelegate(collector)
        tracker.setBridgeAttached(true)
    }

    // --- 1. delivery on first listener ---

    @Test
    fun `queued events reach the normal callback when a listener goes live and the queue empties`() {
        queueEventsAndResume("zone-a" to "ENTER", "zone-b" to "EXIT")

        tracker.setEventListenerActive(true)

        assertEquals(2, collector.received.size)
        assertEquals("zone-a", collector.received[0]["zoneId"])
        assertEquals("ENTER", collector.received[0]["eventType"])
        assertEquals("zone-b", collector.received[1]["zoneId"])
        assertEquals("EXIT", collector.received[1]["eventType"])
        assertTrue(
            "Queue must be empty after an automatic replay",
            LocationTracker.drainPendingEvents(context).isEmpty()
        )
    }

    @Test
    fun `replayed events carry the late-delivery provenance fields`() {
        queueEventsAndResume("zone-a" to "ENTER")

        tracker.setEventListenerActive(true)

        val event = collector.received.single()
        assertEquals(true, event["deliveredLate"])
        val capturedTs = (event["capturedTs"] as Number).toLong()
        assertEquals(
            "capturedTs must be the crossing's own timestamp, not the replay moment",
            (event["timestamp"] as Number).toLong(),
            capturedTs
        )
        val queued = (event["queuedDurationMs"] as Number).toLong()
        assertTrue("queuedDurationMs must not be negative, got $queued", queued >= 0L)
    }

    // --- 2. delivery must not happen before a subscriber exists ---

    @Test
    fun `no delivery while only the bridge sink is attached — the drain waits for a listener`() {
        // Reproduces the bridge's initialize() sequence: the plugin declares that
        // it owns the listener signal, wires its sink, and registers the delegate
        // — all before any consumer has subscribed. Replaying anywhere in that
        // window emits into a stream nobody is reading.
        queueEventsAndResume("zone-a" to "ENTER", "zone-b" to "EXIT")

        assertTrue(
            "Nothing may be delivered before a listener is signalled — " +
                "attaching the sink and registering the delegate is what initialize() does",
            collector.received.isEmpty()
        )

        tracker.setEventListenerActive(true)

        assertEquals(
            "Both queued events must arrive once a listener is genuinely live",
            2,
            collector.received.size
        )
    }

    /**
     * A direct consumer that registers before the Service exists. `onCreate` applies that delegate, which raises
     * the subscribe signal, and the replay it triggers must reach the queue.
     *
     * Ordering-sensitive. Raising the signal before `pendingEventsStore` is
     * built makes the replay return on the queue-size check, which sits above
     * the zone-state check that would otherwise defer it, so the deferred flag
     * is never armed and the restore below hands over nothing. Live delivery of
     * new crossings still works in that state, which is what makes the loss
     * quiet: the consumer sees fresh events and never learns the stored ones
     * existed.
     */
    @Test
    fun `a delegate staged before the service starts replays the queue once zones restore`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")

        // Null staged signal is what "no bridge has claimed it" looks like; a
        // bridge stages false and keeps the auto-raise suppressed.
        clearStagedListenerSignal()
        LocationTracker.setPendingCoreDelegate(collector)

        val staged = Robolectric.buildService(LocationTracker::class.java).create().get()
        // Restore is driven on `staged` directly rather than through the class
        // helper, which targets the tracker from setUp. Staging a delegate also
        // live-applies it to the existing instance, so both are holding this
        // collector; restoring on both would drain one file through two stores.
        LocationTracker::class.java
            .getDeclaredMethod("restoreZonesFromStorage")
            .apply { isAccessible = true }
            .invoke(staged)

        assertEquals(
            "the crossing queued before the consumer registered must be handed over",
            1,
            collector.received.size
        )
        assertEquals("zone-a", collector.received[0]["zoneId"])
        assertEquals(true, collector.received[0]["deliveredLate"])
    }

    @Test
    fun `registering a delegate replays for a direct consumer that never declares the signal`() {
        // A direct-Kotlin consumer has no listener lifecycle to hook, so setting
        // the delegate IS its subscription moment. This is the same call the
        // previous test proves must NOT replay — the difference is that a bridge
        // has declared ownership of the signal there and has not here.
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")
        invokeRestoreZonesFromStorage()

        tracker.setCoreDelegate(collector)

        assertEquals(1, collector.received.size)
        assertEquals("zone-a", collector.received[0]["zoneId"])
        assertEquals(true, collector.received[0]["deliveredLate"])
    }

    // --- 3. opt-out ---

    @Test
    fun `auto-drain disabled delivers nothing and leaves the queue for a manual drain`() {
        LocationTracker.setEventListenerActive(false)
        invokeUpdateConfigurationFromMap(
            mapOf(
                "pendingEventsQueueSize" to 10,
                "pendingEventsAutoDrainEnabled" to false
            )
        )
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")
        invokeRestoreZonesFromStorage()
        tracker.setCoreDelegate(collector)
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)

        assertTrue("Opt-out must suppress automatic delivery", collector.received.isEmpty())

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals("The queue must survive intact for the manual drain", 1, drained.size)
        assertEquals("zone-a", drained[0]["zoneId"])
    }

    // --- 4. empty queue ---

    @Test
    fun `an empty queue on listener attach delivers nothing and does not read the log file`() {
        LocationTracker.setEventListenerActive(false)
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        invokeRestoreZonesFromStorage()
        tracker.setCoreDelegate(collector)
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)

        assertTrue(collector.received.isEmpty())
        assertFalse(
            "An attach with nothing queued must not create the log file",
            File(storeDir, "queue.jsonl").exists()
        )
    }

    // --- 5. repeat subscription ---

    @Test
    fun `a second listener signal does not replay the batch again`() {
        queueEventsAndResume("zone-a" to "ENTER")

        tracker.setEventListenerActive(true)
        assertEquals(1, collector.received.size)

        tracker.setEventListenerActive(true)
        assertEquals("A second subscriber must not re-receive the first one's batch", 1, collector.received.size)

        // A genuine resubscribe is a fresh edge, but there is nothing left to
        // replay — and the store answers that without touching disk.
        tracker.setEventListenerActive(false)
        tracker.setEventListenerActive(true)
        assertEquals(1, collector.received.size)
    }

    // --- 6. config survives a process restart ---

    @Test
    fun `auto-drain opt-out survives a simulated process restart`() {
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsAutoDrainEnabled" to false))

        // Discard the tracker and build a fresh one — the shape a killed and
        // relaunched process takes. Anything held only in memory reads as its
        // compile-time default here, so the readback below is what proves the
        // flag reached SharedPreferences.
        Robolectric.buildService(LocationTracker::class.java).create().get()

        assertEquals(false, PolyfenceConfig(context).pendingEventsAutoDrainEnabled)
        assertEquals(
            false,
            LocationTracker.getCurrentConfigurationMap(context)["pendingEventsAutoDrainEnabled"]
        )
    }

    @Test
    fun `auto-drain defaults to on when nothing was ever written`() {
        assertTrue(PolyfenceConfig(context).pendingEventsAutoDrainEnabled)
        assertEquals(true, LocationTracker.getCurrentConfigurationMap(context)["pendingEventsAutoDrainEnabled"])
    }

    // --- 7. drain-then-reconcile ordering ---

    @Test
    fun `a replayed ENTER that resolves the mismatch suppresses RECOVERY_ENTER`() {
        val engine = tracker.geofenceEngineForOsGeofence
        engine.addZone("zone-a", "Zone A", circleAt(50.0, 0.0))

        LocationTracker.setEventListenerActive(false)
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")

        invokeRestoreZonesFromStorage()
        tracker.setCoreDelegate(collector)
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)
        assertEquals(1, collector.received.size)
        assertEquals("ENTER", collector.received[0]["eventType"])
        assertEquals(true, engine.getCurrentZoneStates()["zone-a"])

        // The reconcile that runs off the first fix after restore now sees the
        // post-replay truth: still inside, state already inside, no mismatch.
        forceEngineRecoveredFromPersistence(engine)
        engine.reconcileZoneStates(locationAt(50.0, 0.0))

        val recovery = collector.received.firstOrNull {
            it["eventType"] == GeofenceEngine.EVENT_RECOVERY_ENTER ||
                it["eventType"] == GeofenceEngine.EVENT_RECOVERY_EXIT
        }
        assertNull(
            "A replayed ENTER already told the consumer about this crossing — " +
                "reconcile must not also report it as a recovery",
            recovery
        )
    }

    // --- 8. queue off ---

    @Test
    fun `a listener signal is inert when pendingEventsQueueSize is zero`() {
        LocationTracker.setEventListenerActive(false)
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")
        invokeRestoreZonesFromStorage()
        tracker.setCoreDelegate(collector)
        tracker.setBridgeAttached(true)

        tracker.setEventListenerActive(true)

        assertTrue(collector.received.isEmpty())
        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    // --- companion staging ---

    @Test
    fun `a listener signalled before the service exists replays once the service starts`() {
        LocationTracker.setEventListenerActive(false)
        invokeUpdateConfigurationFromMap(mapOf("pendingEventsQueueSize" to 10))
        tracker.setCoreDelegate(null)
        tracker.setBridgeAttached(false)
        invokeHandleGeofenceEvent("zone-a", "ENTER")

        // Signal arrives while nothing is running, then a Service comes up.
        LocationTracker.setEventListenerActive(true)
        val revived = Robolectric.buildService(LocationTracker::class.java).create().get()
        revived.setCoreDelegate(collector)
        revived.setBridgeAttached(true)

        assertTrue(
            "A staged signal must not replay before zones are restored",
            collector.received.isEmpty()
        )

        val method = LocationTracker::class.java.getDeclaredMethod("restoreZonesFromStorage")
        method.isAccessible = true
        method.invoke(revived)

        assertEquals(1, collector.received.size)
        assertEquals("zone-a", collector.received[0]["zoneId"])
    }
}

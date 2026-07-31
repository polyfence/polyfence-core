package io.polyfence.core

import android.app.Application
import android.app.PendingIntent
import android.content.Context
import android.location.Location
import android.os.Build
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.tasks.Tasks
import io.polyfence.core.utils.PolyfenceConfig
import java.io.File
import java.time.Duration
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.ArgumentCaptor
import org.mockito.ArgumentMatchers.any
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.times
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Coverage for the OS wake-fence layer. Swift counterpart:
 * `test/ios/OsGeofenceWakeTests.swift` — every case here has a mirror there.
 *
 * The bar these cases defend:
 *  - `osGeofenceWakeEnabled = false` (the default) means nothing is registered
 *    with the OS and the in-process pipeline is byte-identical.
 *  - When on, the top-N-nearest set is selected and registered, recalculated
 *    on zone-set change and on movement.
 *  - An OS-fired transition lands in the SAME `PendingEventsStore` the tracker
 *    drains, not a second instance racing the same file.
 *  - Cap-hits and permission denial are both observable via the health field
 *    and neither crashes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [Build.VERSION_CODES.Q])
class OsGeofenceWakeTest {

    private lateinit var context: Context
    private lateinit var tracker: LocationTracker
    private lateinit var storeDir: File
    private val capturedErrors = mutableListOf<Map<String, Any>>()

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        storeDir = File(context.noBackupFilesDir, "pending_events")
        storeDir.deleteRecursively()
        PolyfenceConfig(context).resetToDefaults()
        capturedErrors.clear()
        PolyfenceErrorManager.initialize { capturedErrors.add(it) }
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
        setIsRunning(true)
        LocationTracker.applyClearZonesDirect(tracker)
    }

    @After
    fun tearDown() {
        LocationTracker.applyClearZonesDirect(tracker)
        setIsRunning(false)
        tracker.onDestroy()
        PolyfenceErrorManager.dispose()
        storeDir.deleteRecursively()
        PolyfenceConfig(context).resetToDefaults()
    }

    // ---------------------------------------------------------------
    // Fixtures — same reflection seams the sibling LocationTracker
    // suites use rather than widening production visibility for tests.
    // ---------------------------------------------------------------

    private fun setIsRunning(value: Boolean) {
        val field = LocationTracker::class.java.getDeclaredField("isRunning")
        field.isAccessible = true
        field.setBoolean(null, value)
    }

    private fun applyConfig(configMap: Map<String, Any>) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "updateConfigurationFromMap",
            Map::class.java
        )
        method.isAccessible = true
        method.invoke(tracker, configMap)
    }

    private fun fireGeofenceEvent(zoneId: String, eventType: String) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "handleGeofenceEvent",
            String::class.java,
            String::class.java,
            Location::class.java,
            Double::class.javaPrimitiveType
        )
        method.isAccessible = true
        method.invoke(tracker, zoneId, eventType, fixAt(51.5, -0.1), 5.0)
    }

    private fun circleZoneData(lat: Double, lng: Double, radius: Double = 250.0): Map<String, Any> =
        mapOf(
            "type" to "circle",
            "center" to mapOf("latitude" to lat, "longitude" to lng),
            "radius" to radius
        )

    private fun engineZone(id: String, lat: Double, lng: Double, radius: Double = 250.0) =
        GeofenceEngine.Zone(
            id = id,
            name = "Zone $id",
            type = GeofenceEngine.ZoneType.CIRCLE,
            center = GeofenceEngine.LatLng(lat, lng),
            radius = radius,
            points = emptyList()
        )

    private fun enginePolygonZone(id: String, lat: Double, lng: Double, halfSpanDeg: Double = 0.01) =
        GeofenceEngine.Zone(
            id = id,
            name = "Zone $id",
            type = GeofenceEngine.ZoneType.POLYGON,
            center = null,
            radius = null,
            points = listOf(
                GeofenceEngine.LatLng(lat - halfSpanDeg, lng - halfSpanDeg),
                GeofenceEngine.LatLng(lat - halfSpanDeg, lng + halfSpanDeg),
                GeofenceEngine.LatLng(lat + halfSpanDeg, lng + halfSpanDeg),
                GeofenceEngine.LatLng(lat + halfSpanDeg, lng - halfSpanDeg)
            )
        )

    private fun fixAt(lat: Double, lng: Double) = Location("test").apply {
        latitude = lat
        longitude = lng
    }

    private fun grantAllLocationPermissions() {
        shadowOf(ApplicationProvider.getApplicationContext<Application>()).grantPermissions(
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.ACCESS_COARSE_LOCATION,
            android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
        )
    }

    private fun denyBackgroundLocationPermission() {
        val app = shadowOf(ApplicationProvider.getApplicationContext<Application>())
        app.grantPermissions(
            android.Manifest.permission.ACCESS_FINE_LOCATION,
            android.Manifest.permission.ACCESS_COARSE_LOCATION
        )
        app.denyPermissions(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    }

    // Plain Java Mockito, not the Kotlin extensions: mockito-kotlin's inline
    // helpers ship as JVM-11 bytecode and cannot be inlined into this module's
    // 1.8 target. Same choice the sibling engine / scheduler suites made.
    private fun succeedingClient(): GeofencingClient {
        val client = mock(GeofencingClient::class.java)
        `when`(client.addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java)))
            .thenReturn(Tasks.forResult<Void>(null))
        `when`(client.removeGeofences(any(PendingIntent::class.java)))
            .thenReturn(Tasks.forResult<Void>(null))
        return client
    }

    /**
     * A registrar in the only state that holds OS slots: app backgrounded.
     * While foregrounded the registrar deliberately holds zero slots, so a
     * registration case built without this would assert against a no-op.
     */
    private fun backgroundedRegistrar(
        client: GeofencingClient,
        maxRegions: Int = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
    ): OsGeofenceRegistrar =
        OsGeofenceRegistrar(context, client, maxRegions).apply { onAppBackgrounded() }

    /** Drains the paused Robolectric main looper so posted GMS listeners run. */
    private fun idleMainLooper() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    /**
     * Runs [block] on a worker thread while pumping the main looper, and
     * returns its result.
     *
     * The boot path blocks until Play Services settles the registration, and
     * Play Services delivers that callback on the main looper. Calling it
     * straight from a Robolectric test would block the very looper that has to
     * deliver the completion. The production caller is a broadcast receiver's
     * worker thread, so driving it the same way here is both necessary and
     * faithful.
     */
    private fun <T> awaitOffMainLooper(timeoutMs: Long = 5_000, block: () -> T): T {
        val result = java.util.concurrent.atomic.AtomicReference<T>()
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val worker = Thread {
            try {
                result.set(block())
            } catch (t: Throwable) {
                failure.set(t)
            }
        }
        worker.start()
        val deadline = System.currentTimeMillis() + timeoutMs
        while (worker.isAlive && System.currentTimeMillis() < deadline) {
            idleMainLooper()
            Thread.sleep(5)
        }
        worker.join(1_000)
        failure.get()?.let { throw it }
        return result.get()
    }

    /**
     * Advances the paused Robolectric clock past the registrar's debounce
     * window so the coalesced refresh actually fires. A plain `idle()` only
     * runs tasks already due, so a `postDelayed` refresh would never run.
     */
    private fun idlePastDebounce() {
        shadowOf(Looper.getMainLooper())
            .idleFor(Duration.ofMillis(OsGeofenceRegistrar.DEBOUNCE_MS + 100))
    }

    /**
     * Seeds the shared engine the debounced refresh path reads from —
     * `refreshRegistrationInternal` pulls zones off the running tracker, so
     * without this an OS registration has nothing to register.
     */
    private fun seedEngineZone(id: String, lat: Double, lng: Double) {
        LocationTracker.applyAddZoneDirect(tracker, id, "Zone $id", circleZoneData(lat, lng))
    }

    // ---------------------------------------------------------------
    // Config default: off
    // ---------------------------------------------------------------

    @Test
    fun `osGeofenceWakeEnabled defaults to false`() {
        assertFalse(PolyfenceConfig(context).osGeofenceWakeEnabled)
    }

    @Test
    fun `default config exposes osGeofenceWakeEnabled false on the read side`() {
        assertEquals(false, LocationTracker.buildDefaultConfigurationMap()["osGeofenceWakeEnabled"])
        assertEquals(false, LocationTracker.getCurrentConfigurationMap(context)["osGeofenceWakeEnabled"])
    }

    @Test
    fun `default config never activates the registrar`() {
        grantAllLocationPermissions()

        LocationTracker.applyAddZoneDirect(tracker, "z1", "Zone 1", circleZoneData(51.5, -0.1))
        idleMainLooper()

        // No registrar instance means no OS call was even attempted, and the
        // health field stays null so a consumer can tell opt-out from cap-hit.
        assertNull(LocationTracker.osGeofenceRegistrationHealth())
    }

    @Test
    fun `in-process persist path is unchanged when the wake flag is off`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10))

        fireGeofenceEvent("z1", "ENTER")

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("ENTER", drained[0]["eventType"])
        // No `source` marker — the in-process path must stay byte-identical
        // to what it emitted before OS wake fences existed.
        assertNull(drained[0]["source"])
    }

    // ---------------------------------------------------------------
    // Config on: registers top-N-nearest
    // ---------------------------------------------------------------

    @Test
    fun `registrar registers the nearest zones first when enabled`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        registrar.refreshNowForTest(
            zones = listOf(
                engineZone("far", 52.5, -0.1),
                engineZone("near", 51.5001, -0.1),
                engineZone("mid", 51.6, -0.1)
            ),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        val captor = ArgumentCaptor.forClass(GeofencingRequest::class.java)
        verify(client).addGeofences(captor.capture(), any(PendingIntent::class.java))
        assertEquals(
            listOf("near", "mid", "far"),
            captor.allValues[0].geofences.map { it.requestId }
        )
    }

    @Test
    fun `selection falls back to insertion order when no fix has landed`() {
        val selected = OsGeofenceRegistrar.selectTopNNearest(
            zones = listOf(engineZone("a", 1.0, 1.0), engineZone("b", 2.0, 2.0)),
            seed = null,
            topN = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        )
        assertEquals(listOf("a", "b"), selected.map { it.zoneId })
    }

    @Test
    fun `polygon zones register as a circular bounding cover around the centroid`() {
        val selected = OsGeofenceRegistrar.selectTopNNearest(
            zones = listOf(enginePolygonZone("poly", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1),
            topN = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        )
        assertEquals(1, selected.size)
        // Centroid of the symmetric square is the zone's nominal centre, and
        // the cover radius must reach at least the furthest vertex — a smaller
        // radius would leave a corner of the polygon outside the wake trigger.
        assertEquals(51.5, selected[0].centerLat, 1e-9)
        assertEquals(-0.1, selected[0].centerLng, 1e-9)
        assertTrue(
            "cover radius must exceed the polygon half-span",
            selected[0].radiusMeters > 1000.0
        )
    }

    @Test
    fun `health reports requested equals registered under the cap`() {
        grantAllLocationPermissions()
        val registrar = backgroundedRegistrar(succeedingClient())

        registrar.refreshNowForTest(
            zones = (1..5).map { engineZone("z$it", 51.5 + it * 0.001, -0.1) },
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        val health = registrar.health
        assertNotNull(health)
        assertEquals(5, health!!.requested)
        assertEquals(5, health.registered)
        assertNull(health.lastError)
    }

    @Test
    fun `health map shape matches the documented three-key contract`() {
        grantAllLocationPermissions()
        val registrar = backgroundedRegistrar(succeedingClient())

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        assertEquals(
            setOf("requested", "registered", "lastError"),
            registrar.health!!.toMap().keys
        )
    }

    // ---------------------------------------------------------------
    // Cap-hit
    // ---------------------------------------------------------------

    @Test
    fun `cap-hit health reports requested above registered`() {
        grantAllLocationPermissions()
        val registrar = backgroundedRegistrar(succeedingClient())
        val overCap = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS + 25

        registrar.refreshNowForTest(
            zones = (1..overCap).map { engineZone("z$it", 51.5 + it * 0.001, -0.1) },
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        val health = registrar.health
        assertNotNull(health)
        assertEquals(overCap, health!!.requested)
        assertEquals(PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS, health.registered)
        // A cap-hit is partial coverage, not a failure — lastError stays null
        // so consumers can distinguish it from permission drift.
        assertNull(health.lastError)
    }

    @Test
    fun `selection never exceeds the platform cap`() {
        val selected = OsGeofenceRegistrar.selectTopNNearest(
            zones = (1..500).map { engineZone("z$it", 51.5 + it * 0.001, -0.1) },
            seed = fixAt(51.5, -0.1),
            topN = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        )
        assertEquals(PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS, selected.size)
    }

    // ---------------------------------------------------------------
    // Permission denial
    // ---------------------------------------------------------------

    @Test
    fun `permission denial emits a warning onError and does not crash`() {
        denyBackgroundLocationPermission()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        verify(client, never()).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))

        val error = capturedErrors.firstOrNull { it["type"] == "os_geofence_permission_denied" }
        assertNotNull("permission denial must surface via onError", error)
        @Suppress("UNCHECKED_CAST")
        val ctx = error!!["context"] as Map<String, Any>
        assertEquals("warning", ctx["severity"])
        assertEquals("android", ctx["platform"])
    }

    @Test
    fun `permission denial populates the health field with the documented marker`() {
        denyBackgroundLocationPermission()
        val registrar = backgroundedRegistrar(succeedingClient())

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )

        val health = registrar.health
        assertNotNull(health)
        assertEquals(0, health!!.registered)
        assertEquals("background_location_denied", health.lastError)
    }

    @Test
    @Config(sdk = [Build.VERSION_CODES.P])
    fun `pre-Q needs no background permission and registers on foreground grant alone`() {
        // ACCESS_BACKGROUND_LOCATION did not exist before Q — gating on it
        // there would permanently disable the feature on those devices.
        denyBackgroundLocationPermission()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        verify(client).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
        assertNull(registrar.health?.lastError)
    }

    @Test
    fun `permission absent from the merged manifest degrades like a denied grant`() {
        // A consumer who never declares ACCESS_BACKGROUND_LOCATION sees
        // checkSelfPermission report DENIED, so the undeclared case and the
        // declared-but-refused case converge on one code path — which is why
        // polyfence-core can safely leave the permission out of its manifest.
        denyBackgroundLocationPermission()
        val registrar = backgroundedRegistrar(succeedingClient())

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )

        assertEquals(
            OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED,
            registrar.health!!.lastError
        )
        assertTrue(capturedErrors.any { it["type"] == "os_geofence_permission_denied" })
    }

    @Test
    fun `SecurityException from the OS surfaces the same permission-denied path`() {
        grantAllLocationPermissions()
        // Play Services can still refuse at call time even when
        // checkSelfPermission passes — a revoke racing the request, or an OEM
        // policy. That must land on the documented marker, not escape.
        val throwingClient = mock(GeofencingClient::class.java)
        `when`(
            throwingClient.addGeofences(
                any(GeofencingRequest::class.java),
                any(PendingIntent::class.java)
            )
        ).thenThrow(SecurityException("no background location"))
        `when`(throwingClient.removeGeofences(any(PendingIntent::class.java)))
            .thenReturn(Tasks.forResult<Void>(null))

        val registrar = backgroundedRegistrar(throwingClient)
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )

        assertEquals(
            OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED,
            registrar.health!!.lastError
        )
        assertEquals(0, registrar.health!!.registered)
    }

    @Test
    fun `permission denial leaves the pending queue intact and drainable`() {
        denyBackgroundLocationPermission()
        applyConfig(mapOf("pendingEventsQueueSize" to 10))
        fireGeofenceEvent("z1", "ENTER")

        backgroundedRegistrar(succeedingClient()).refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )

        // The degraded path must not corrupt or clear what was already queued.
        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("ENTER", drained[0]["eventType"])
    }

    // ---------------------------------------------------------------
    // OS-fired events reach the shared store
    // ---------------------------------------------------------------

    @Test
    fun `OS-fired transition lands in the pending events store`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = fixAt(51.5, -0.1)
        )

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("z1", drained[0]["zoneId"])
        assertEquals("ENTER", drained[0]["eventType"])
        assertEquals(
            PolyfenceGeofenceBroadcastReceiver.EVENT_SOURCE_OS_GEOFENCE,
            drained[0]["source"]
        )
    }

    @Test
    fun `OS-fired transition writes to the running tracker's own store`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))

        // The receiver must share the Service's store instance — a second
        // store would put two independent writer threads on one file. Drain
        // through the tracker's own composite path to prove they agree.
        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "EXIT",
            zoneIds = listOf("z9"),
            triggeringLocation = fixAt(51.5, -0.1)
        )

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(1, drained.size)
        assertEquals("z9", drained[0]["zoneId"])
        assertEquals("EXIT", drained[0]["eventType"])
    }

    @Test
    fun `multiple triggering fences enqueue one event each`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("a", "b", "c"),
            triggeringLocation = null
        )

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals(listOf("a", "b", "c"), drained.map { it["zoneId"] })
    }

    @Test
    fun `OS-fired events are membership-applied by the same drain path in-process events use`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))
        LocationTracker.applyAddZoneDirect(tracker, "z1", "Zone 1", circleZoneData(51.5, -0.1))

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = fixAt(51.5, -0.1)
        )
        LocationTracker.drainPendingEvents(context)

        // drainAndApply must have written the post-drain truth into zoneStates,
        // so the next reconcile sees no mismatch and fires no RECOVERY event.
        assertEquals(true, LocationTracker.getCurrentZoneStates()["z1"])
    }

    @Test
    fun `OS-fired transition carries the zone name when the engine knows it`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))
        LocationTracker.applyAddZoneDirect(tracker, "z1", "Congestion Zone", circleZoneData(51.5, -0.1))

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = null
        )

        val drained = LocationTracker.drainPendingEvents(context)
        assertEquals("Congestion Zone", drained[0]["zoneName"])
    }

    @Test
    fun `queue disabled means an OS-fired transition is dropped, not queued`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 0, "osGeofenceWakeEnabled" to true))

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = null
        )

        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    // ---------------------------------------------------------------
    // Slot allocation: zero held while foregrounded
    // ---------------------------------------------------------------

    @Test
    fun `foreground transition releases every registered fence`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()
        assertEquals(1, registrar.health!!.registered)

        registrar.onAppForegrounded()
        idleMainLooper()

        // The consumer gets the whole platform allocation back while its app is
        // alive — the in-process engine is doing the detection anyway.
        verify(client).removeGeofences(any(PendingIntent::class.java))
        assertEquals(0, registrar.health!!.registered)
        assertNull(registrar.health!!.lastError)
    }

    @Test
    fun `no registration happens while the app is foregrounded`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        // Constructed foregrounded — no onAppBackgrounded() call.
        val registrar = OsGeofenceRegistrar(context, client)
        registrar.onAppForegrounded()

        seedEngineZone("z1", 51.5, -0.1)
        registrar.requestRefresh()
        idlePastDebounce()

        verify(client, never())
            .addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `movement while foregrounded does not register`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = OsGeofenceRegistrar(context, client)
        registrar.onAppForegrounded()

        seedEngineZone("z1", 51.5, -0.1)
        registrar.onLocationUpdate(fixAt(51.55, -0.1))
        idlePastDebounce()

        verify(client, never())
            .addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `background transition registers up to the configured cap`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = OsGeofenceRegistrar(context, client, requestedMaxRegions = 3)
        registrar.onAppForegrounded()
        repeat(6) { seedEngineZone("z$it", 51.5 + it * 0.001, -0.1) }

        registrar.onAppBackgrounded()
        idlePastDebounce()

        val captor = ArgumentCaptor.forClass(GeofencingRequest::class.java)
        verify(client).addGeofences(captor.capture(), any(PendingIntent::class.java))
        assertEquals(3, captor.allValues[0].geofences.size)
        assertEquals(6, registrar.health!!.requested)
        assertEquals(3, registrar.health!!.registered)
    }

    // ---------------------------------------------------------------
    // Activity-lifecycle monitor
    // ---------------------------------------------------------------

    private class MonitorProbe {
        var foregroundCount = 0
        var backgroundCount = 0
    }

    private fun monitorStartedForegrounded(probe: MonitorProbe) =
        OsGeofenceRegistrar.AppForegroundMonitor(
            handler = android.os.Handler(Looper.getMainLooper()),
            startedForegrounded = true,
            onForeground = { probe.foregroundCount++ },
            onBackground = { probe.backgroundCount++ }
        )

    private fun idlePastSettle() {
        shadowOf(Looper.getMainLooper())
            .idleFor(Duration.ofMillis(OsGeofenceRegistrar.BACKGROUND_SETTLE_MS + 100))
    }

    @Test
    fun `monitor reports the first background even though it never saw the first start`() {
        // registerActivityLifecycleCallbacks does not replay past callbacks, so
        // a monitor attached while an activity is already started never sees
        // its onActivityStarted. Seeding foreground state from the caller's
        // probe is what makes the very first background transition — the one
        // that arms wake fences for the session most likely to be killed —
        // actually fire.
        val probe = MonitorProbe()
        val monitor = monitorStartedForegrounded(probe)
        val activity = android.app.Activity()

        monitor.onActivityStopped(activity)
        idlePastSettle()

        assertEquals(1, probe.backgroundCount)
    }

    @Test
    fun `monitor treats a rotation as continuous foreground`() {
        val probe = MonitorProbe()
        val monitor = monitorStartedForegrounded(probe)
        val activity = android.app.Activity()

        // A configuration change stops and restarts the activity, momentarily
        // leaving none started. Reporting that as backgrounded would register
        // and immediately unregister the whole fence set on every rotation.
        monitor.onActivityStopped(activity)
        monitor.onActivityStarted(activity)
        idlePastSettle()

        assertEquals(0, probe.backgroundCount)
    }

    @Test
    fun `monitor reports a real background after the settle window`() {
        val probe = MonitorProbe()
        val monitor = monitorStartedForegrounded(probe)
        val activity = android.app.Activity()

        monitor.onActivityStarted(activity)
        monitor.onActivityStopped(activity)
        idlePastSettle()

        assertEquals(1, probe.backgroundCount)
    }

    @Test
    fun `monitor reports foreground exactly once across a background round-trip`() {
        val probe = MonitorProbe()
        val monitor = monitorStartedForegrounded(probe)
        val activity = android.app.Activity()

        monitor.onActivityStopped(activity)
        idlePastSettle()
        monitor.onActivityStarted(activity)

        assertEquals(1, probe.backgroundCount)
        assertEquals(1, probe.foregroundCount)
    }

    // ---------------------------------------------------------------
    // Configurable cap
    // ---------------------------------------------------------------

    @Test
    fun `default cap leaves headroom below the platform maximum`() {
        assertEquals(50, PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS)
        assertEquals(100, PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS)
        assertEquals(
            PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS,
            PolyfenceConfig(context).osGeofenceMaxRegions
        )
    }

    @Test
    fun `cap above the platform maximum is clamped rather than rejected`() {
        // Play Services refuses an over-large request wholesale, so honouring
        // the raw value would register nothing at all instead of registering
        // more.
        assertEquals(
            PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS,
            OsGeofenceRegistrar(context, succeedingClient(), requestedMaxRegions = 5_000)
                .effectiveMaxRegions()
        )
        assertEquals(
            1,
            OsGeofenceRegistrar(context, succeedingClient(), requestedMaxRegions = 0)
                .effectiveMaxRegions()
        )
    }

    @Test
    fun `config persists the clamped cap, not the raw request`() {
        // Echoing the raw value back through getConfiguration would advertise a
        // budget the registrar never uses and leave the consumer no way to
        // discover the effective one.
        val config = PolyfenceConfig(context)
        config.osGeofenceMaxRegions = 5_000
        assertEquals(
            PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS,
            config.osGeofenceMaxRegions
        )
        config.osGeofenceMaxRegions = 0
        assertEquals(1, config.osGeofenceMaxRegions)
    }

    @Test
    fun `stale registration callback cannot resurrect health after a release`() {
        grantAllLocationPermissions()
        // Play Services resolves on the main looper at an arbitrary later time.
        // A foreground release landing in between must win — otherwise health
        // reports N regions monitored moments after all N were removed.
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )

        registrar.onAppForegrounded()
        idleMainLooper()

        assertEquals(0, registrar.health!!.registered)
        assertEquals(0, registrar.health!!.requested)
    }

    @Test
    fun `cap propagates from config through updateConfiguration`() {
        applyConfig(mapOf("osGeofenceMaxRegions" to 12, "osGeofenceWakeEnabled" to true))

        assertEquals(12, PolyfenceConfig(context).osGeofenceMaxRegions)
        assertEquals(
            12,
            LocationTracker.getCurrentConfigurationMap(context)["osGeofenceMaxRegions"]
        )
    }

    @Test
    fun `cap is exposed on the default configuration map`() {
        assertEquals(
            PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS,
            LocationTracker.buildDefaultConfigurationMap()["osGeofenceMaxRegions"]
        )
    }

    @Test
    fun `wake flag survives service reconstruction`() {
        applyConfig(mapOf("osGeofenceWakeEnabled" to true))

        // When the OS wakes a killed app on a crossing, the receiver runs
        // before any bridge re-applies configuration. An in-memory-only flag
        // would read false there and the crossing would be discarded.
        assertTrue(PolyfenceConfig(context).osGeofenceWakeEnabled)
        tracker.onDestroy()
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
        setIsRunning(true)

        assertEquals(
            true,
            LocationTracker.getCurrentConfigurationMap(context)["osGeofenceWakeEnabled"]
        )
    }

    // ---------------------------------------------------------------
    // Boot re-registration
    // ---------------------------------------------------------------

    @Test
    fun `boot re-registration no-ops when the feature was off at last shutdown`() {
        grantAllLocationPermissions()
        PolyfenceConfig(context).osGeofenceWakeEnabled = false
        LocationTracker.applyAddZoneDirect(tracker, "z1", "Zone 1", circleZoneData(51.5, -0.1))
        val client = succeedingClient()

        val registered = awaitOffMainLooper {
            OsGeofenceRegistrar.registerFromPersistedZones(context, client, null)
        }

        assertEquals(0, registered)
        verify(client, never())
            .addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `boot re-registration no-ops when no zones are persisted`() {
        grantAllLocationPermissions()
        PolyfenceConfig(context).osGeofenceWakeEnabled = true
        LocationTracker.applyClearZonesDirect(tracker)
        val client = succeedingClient()

        val registered = awaitOffMainLooper {
            OsGeofenceRegistrar.registerFromPersistedZones(context, client, null)
        }

        assertEquals(0, registered)
        verify(client, never())
            .addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `boot re-registration re-arms fences from persisted zones`() {
        grantAllLocationPermissions()
        PolyfenceConfig(context).osGeofenceWakeEnabled = true
        LocationTracker.applyAddZoneDirect(tracker, "z1", "Zone 1", circleZoneData(51.5, -0.1))
        LocationTracker.applyAddZoneDirect(tracker, "z2", "Zone 2", circleZoneData(51.6, -0.1))
        val client = succeedingClient()

        // Play Services drops every geofence on reboot, and no tracker is
        // running at boot — the zone set has to come off disk.
        val registered = awaitOffMainLooper {
            OsGeofenceRegistrar.registerFromPersistedZones(context, client, fixAt(51.5, -0.1))
        }

        assertEquals(2, registered)
        val captor = ArgumentCaptor.forClass(GeofencingRequest::class.java)
        verify(client).addGeofences(captor.capture(), any(PendingIntent::class.java))
        assertEquals(
            setOf("z1", "z2"),
            captor.allValues[0].geofences.map { it.requestId }.toSet()
        )
    }

    @Test
    fun `boot re-registration honours the configured cap`() {
        grantAllLocationPermissions()
        PolyfenceConfig(context).osGeofenceWakeEnabled = true
        PolyfenceConfig(context).osGeofenceMaxRegions = 2
        repeat(5) {
            LocationTracker.applyAddZoneDirect(
                tracker, "z$it", "Zone $it", circleZoneData(51.5 + it * 0.001, -0.1)
            )
        }
        val client = succeedingClient()

        val registered = awaitOffMainLooper {
            OsGeofenceRegistrar.registerFromPersistedZones(context, client, fixAt(51.5, -0.1))
        }

        assertEquals(2, registered)
    }

    @Test
    fun `boot receiver ignores broadcasts other than BOOT_COMPLETED`() {
        grantAllLocationPermissions()
        PolyfenceConfig(context).osGeofenceWakeEnabled = true
        LocationTracker.applyAddZoneDirect(tracker, "z1", "Zone 1", circleZoneData(51.5, -0.1))

        // A receiver that acted on any delivered intent would re-register on
        // unrelated system broadcasts the consumer's manifest happens to route.
        PolyfenceBootReceiver().onReceive(
            context,
            android.content.Intent(android.content.Intent.ACTION_AIRPLANE_MODE_CHANGED)
        )

        assertNull(LocationTracker.osGeofenceRegistrationHealth())
    }

    // ---------------------------------------------------------------
    // No double-reporting
    // ---------------------------------------------------------------

    @Test
    fun `OS-fired transition is skipped while live delivery is possible`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))
        tracker.setCoreDelegate(LiveDelegate())
        tracker.setBridgeAttached(true)

        // The in-process engine already reports this crossing to a live sink.
        // Queueing the OS copy too would hand the consumer one physical
        // crossing twice on the next drain.
        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = null
        )

        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    @Test
    fun `OS-fired transition is queued when no live sink is attached`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to true))
        tracker.setCoreDelegate(LiveDelegate())
        tracker.setBridgeAttached(false)

        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = null
        )

        assertEquals(1, LocationTracker.drainPendingEvents(context).size)
    }

    @Test
    fun `OS-fired transition is skipped when the wake flag is off`() {
        applyConfig(mapOf("pendingEventsQueueSize" to 10, "osGeofenceWakeEnabled" to false))

        // Play Services holds registered fences across process death, so a
        // consumer who once enabled the flag can still be woken by that
        // session's fences. With the flag off those wakes must not reach the
        // queue — behaviour has to be indistinguishable from never opting in.
        PolyfenceGeofenceBroadcastReceiver.enqueueOsTransition(
            context = context,
            eventType = "ENTER",
            zoneIds = listOf("z1"),
            triggeringLocation = null
        )

        assertTrue(LocationTracker.drainPendingEvents(context).isEmpty())
    }

    /**
     * Minimal live sink — `canDeliverLive()` requires a non-null delegate, so
     * the dedup gate cannot be exercised without one.
     */
    private class LiveDelegate : PolyfenceCoreDelegate {
        override fun onGeofenceEvent(eventData: Map<String, Any>) {}
        override fun onLocationUpdate(locationData: Map<String, Any>) {}
        override fun onPerformanceEvent(performanceData: Map<String, Any>) {}
        override fun onError(errorData: Map<String, Any>) {}
        override fun isTrackingEnabled(): Boolean = true
    }

    // ---------------------------------------------------------------
    // Re-registration triggers
    // ---------------------------------------------------------------

    @Test
    fun `movement anchor advances even when registration is refused`() {
        denyBackgroundLocationPermission()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        // A refused attempt must still move the anchor. Leaving it null makes
        // every later fix look like "moved far enough", producing one retry
        // and one onError per GPS fix for as long as the grant is missing.
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        capturedErrors.clear()

        registrar.onLocationUpdate(fixAt(51.5001, -0.1))
        idlePastDebounce()

        assertTrue(
            "a sub-threshold fix must not trigger another registration attempt",
            capturedErrors.none { it["type"] == "os_geofence_permission_denied" }
        )
    }

    @Test
    fun `repeated denials are rate-limited on the error channel`() {
        denyBackgroundLocationPermission()
        val registrar = backgroundedRegistrar(succeedingClient())

        repeat(10) {
            registrar.refreshNowForTest(
                zones = listOf(engineZone("z1", 51.5, -0.1)),
                seed = fixAt(51.5, -0.1)
            )
        }

        // Ten attempts, one report — an un-throttled channel would evict every
        // genuine entry from the consumer's bounded error history.
        assertEquals(
            1,
            capturedErrors.count { it["type"] == "os_geofence_permission_denied" }
        )
    }

    @Test
    fun `denial health reports total zone count, not candidate count`() {
        denyBackgroundLocationPermission()
        val registrar = backgroundedRegistrar(succeedingClient())
        val overCap = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS + 25

        registrar.refreshNowForTest(
            zones = (1..overCap).map { engineZone("z$it", 51.5 + it * 0.001, -0.1) },
            seed = fixAt(51.5, -0.1)
        )

        // `requested` must mean the same thing on every path. Reporting the
        // post-cap candidate count here would make a denial read as a cap hit.
        assertEquals(overCap, registrar.health!!.requested)
        assertEquals(0, registrar.health!!.registered)
    }

    @Test
    fun `rapid zone-set changes coalesce into one registration`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        seedEngineZone("z1", 51.5, -0.1)
        repeat(5) { registrar.requestRefresh() }
        idlePastDebounce()

        // Five rapid zone mutations must coalesce into a single OS call —
        // the debounce is what keeps a bulk addZone() loop from burning quota.
        verify(client).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `a refresh request does not reach the OS before the debounce window elapses`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        seedEngineZone("z1", 51.5, -0.1)
        registrar.requestRefresh()
        idleMainLooper()

        verify(client, never())
            .addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))

        idlePastDebounce()
        verify(client).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `zone-set change reaches the OS with the updated set after debounce`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1), engineZone("z2", 51.51, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        val captor = ArgumentCaptor.forClass(GeofencingRequest::class.java)
        verify(client, times(2)).addGeofences(captor.capture(), any(PendingIntent::class.java))
        assertEquals(listOf("z1"), captor.allValues[0].geofences.map { it.requestId })
        assertEquals(listOf("z1", "z2"), captor.allValues[1].geofences.map { it.requestId })
    }

    @Test
    fun `movement below the recalc threshold does not re-register`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        // ~11 m north — two orders of magnitude below MOVEMENT_RECALC_METERS.
        registrar.onLocationUpdate(fixAt(51.5001, -0.1))
        idlePastDebounce()

        verify(client).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `movement past the recalc threshold re-registers`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        seedEngineZone("z1", 51.5, -0.1)
        registrar.refreshNowForTest(
            zones = listOf(engineZone("z1", 51.5, -0.1)),
            seed = fixAt(51.5, -0.1)
        )
        idleMainLooper()

        // ~5.5 km north — comfortably past MOVEMENT_RECALC_METERS.
        registrar.onLocationUpdate(fixAt(51.55, -0.1))
        idlePastDebounce()

        verify(client, times(2)).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
    }

    @Test
    fun `shutdown removes registered fences and stops accepting refreshes`() {
        grantAllLocationPermissions()
        val client = succeedingClient()
        val registrar = backgroundedRegistrar(client)

        seedEngineZone("z1", 51.5, -0.1)
        registrar.shutdown()
        registrar.requestRefresh()
        idlePastDebounce()

        verify(client).removeGeofences(any(PendingIntent::class.java))
        verify(client, never()).addGeofences(any(GeofencingRequest::class.java), any(PendingIntent::class.java))
        assertNull(registrar.health)
    }
}

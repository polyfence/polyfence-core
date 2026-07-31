package io.polyfence.core

import android.content.Context
import android.location.Location
import androidx.test.core.app.ApplicationProvider
import io.polyfence.core.utils.PolyfenceConfig
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/**
 * The engine's in-memory `zoneStates` covers registered zones plus whatever a
 * drained batch touched — it is never authoritative over the whole persisted
 * set. These tests pin the resulting property: every write the engine makes to
 * stored zone membership is scoped to the zones it actually knows about, so a
 * partially-populated map cannot erase the rest.
 *
 * Runs under Robolectric for a real Context (SharedPreferences-backed
 * ZonePersistence) and for working `android.location.Location` setters — the
 * plain-JUnit stub silently no-ops `latitude = x`, stranding every reconcile
 * against a (0,0) coordinate.
 */
@RunWith(RobolectricTestRunner::class)
class ZoneStatePersistenceScopeTest {

    private lateinit var context: Context
    private lateinit var persistence: ZonePersistence
    private lateinit var storeDir: File
    private val emittedEvents = mutableListOf<Pair<String, String>>()

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        persistence = ZonePersistence(context)
        persistence.clearAllZoneStates()
        persistence.clearAllZones()
        storeDir = File(context.noBackupFilesDir, "pending_events")
        storeDir.deleteRecursively()
        PolyfenceConfig(context).resetToDefaults()
        emittedEvents.clear()
    }

    @After
    fun tearDown() {
        persistence.clearAllZoneStates()
        persistence.clearAllZones()
        storeDir.deleteRecursively()
        PolyfenceConfig(context).resetToDefaults()
    }

    // --- helpers ---

    private fun circleAt(lat: Double, lng: Double): Map<String, Any> = mapOf(
        "type" to "circle",
        "center" to mapOf("latitude" to lat, "longitude" to lng),
        "radius" to 100.0
    )

    private fun locationAt(lat: Double, lng: Double): Location = Location("test").apply {
        latitude = lat
        longitude = lng
    }

    private fun drainedEvent(zoneId: String, eventType: String): Map<String, Any> = mapOf(
        "zoneId" to zoneId,
        "eventType" to eventType,
        "timestamp" to System.currentTimeMillis()
    )

    /**
     * An engine wired to the shared persistence, holding only the zones named.
     * `zoneStates` is therefore sparse relative to storage — the shape a drain
     * that lands before zone restoration produces.
     */
    private fun engineHolding(vararg zoneIds: String): GeofenceEngine {
        val engine = GeofenceEngine()
        engine.setZonePersistence(persistence)
        engine.setEventCallback { zoneId, eventType, _, _ ->
            emittedEvents.add(zoneId to eventType)
        }
        zoneIds.forEach { zoneId ->
            val lat = 50.0 + zoneIds.indexOf(zoneId)
            engine.addZone(zoneId, "Zone $zoneId", circleAt(lat, 0.0))
        }
        return engine
    }

    /**
     * Force the engine into the mismatch-recovery branch of reconcileZoneStates
     * without a full restore cycle. The flag is private — reflection is the
     * least-invasive path, matching how DrainThenReconcileTest reaches it.
     */
    private fun forceRecoveredFromPersistence(engine: GeofenceEngine) {
        val field = GeofenceEngine::class.java.getDeclaredField("stateRecoveredFromPersistence")
        field.isAccessible = true
        field.setBoolean(engine, true)
    }

    // --- applying a drained batch ---

    @Test
    fun `applying a drained batch preserves persisted membership for every zone outside it`() {
        persistence.saveZoneStates(
            mapOf("zone-a" to false, "zone-b" to true, "zone-c" to true, "zone-d" to false)
        )

        // Only zone-a is registered, so zoneStates holds one entry against four
        // on disk — a drain that lands before restoreZonesFromStorage.
        val engine = engineHolding("zone-a")
        engine.applyDrainedEventsToState(listOf(drainedEvent("zone-a", "ENTER")))

        assertEquals(
            "membership for zones outside the drained batch must survive",
            mapOf("zone-a" to true, "zone-b" to true, "zone-c" to true, "zone-d" to false),
            persistence.loadZoneStates()
        )
    }

    @Test
    fun `applying a drained batch writes the membership implied for the zones it touches`() {
        persistence.saveZoneStates(mapOf("zone-a" to true, "zone-b" to false, "zone-c" to true))

        val engine = engineHolding("zone-a", "zone-b", "zone-c")
        engine.loadPersistedZoneStates()
        engine.applyDrainedEventsToState(
            listOf(
                drainedEvent("zone-a", "EXIT"),
                drainedEvent("zone-b", "ENTER"),
                drainedEvent("zone-b", "DWELL")
            )
        )

        val persisted = persistence.loadZoneStates()
        assertEquals("last event per zone wins", false, persisted["zone-a"])
        assertEquals("DWELL implies inside", true, persisted["zone-b"])
        assertEquals("untouched zone keeps its stored value", true, persisted["zone-c"])
    }

    // --- the two reconcile persist sites ---

    @Test
    fun `establishing a cold-start baseline preserves membership for zones the engine does not hold`() {
        // A zone whose stored record fails to parse on restore leaves its state
        // entry behind with no matching registration, so reconcile persists from
        // a map that does not cover it.
        persistence.saveZoneStates(mapOf("zone-unrestored" to true))

        val engine = engineHolding("zone-a")
        engine.reconcileZoneStates(locationAt(50.0, 0.0))

        val persisted = persistence.loadZoneStates()
        assertEquals("baseline for the held zone is written", true, persisted["zone-a"])
        assertEquals(
            "a zone the engine never registered keeps its stored membership",
            true,
            persisted["zone-unrestored"]
        )
    }

    @Test
    fun `reconciling a mismatch preserves membership for zones the engine does not hold`() {
        persistence.saveZoneStates(mapOf("zone-unrestored" to true))

        val engine = engineHolding("zone-a")
        forceRecoveredFromPersistence(engine)
        engine.reconcileZoneStates(locationAt(50.0, 0.0))

        assertNotNull(
            "the held zone still recovers its missed transition",
            emittedEvents.firstOrNull { it == "zone-a" to GeofenceEngine.EVENT_RECOVERY_ENTER }
        )
        assertEquals(
            "a zone the engine never registered keeps its stored membership",
            true,
            persistence.loadZoneStates()["zone-unrestored"]
        )
    }

    // --- drain-then-reconcile ordering across a restore ---

    @Test
    fun `a drained ENTER applied before restoration survives it and produces no RECOVERY_ENTER`() {
        persistence.saveZoneStates(mapOf("zone-a" to false, "zone-b" to true))

        // Drain lands first, with only zone-a in the engine.
        val draining = engineHolding("zone-a")
        draining.applyDrainedEventsToState(listOf(drainedEvent("zone-a", "ENTER")))

        // Restoration then brings the full zone set up in a fresh engine and
        // reloads membership from storage, exactly as restoreZonesFromStorage does.
        val restored = engineHolding("zone-a", "zone-b")
        restored.loadPersistedZoneStates()
        restored.reconcileZoneStates(locationAt(50.0, 0.0))

        assertNull(
            "the drained ENTER already reported the crossing — reconcile must not repeat it",
            emittedEvents.firstOrNull { it == "zone-a" to GeofenceEngine.EVENT_RECOVERY_ENTER }
        )
        // zone-b was stored INSIDE and the fix places the device outside it.
        // Reconcile can only see that genuine mismatch if the drain left
        // zone-b's stored membership alone.
        assertNotNull(
            "zone-b's genuine transition must still be recovered after the drain",
            emittedEvents.firstOrNull { it == "zone-b" to GeofenceEngine.EVENT_RECOVERY_EXIT }
        )
    }

    // --- the manual drain entry point ---

    @Test
    fun `manual drainPendingEvents before zone restoration does not erase stored membership`() {
        persistence.saveZoneStates(
            mapOf("zone-a" to false, "zone-b" to true, "zone-c" to true)
        )

        // Seed the durable queue before the Service exists so the drain has a
        // batch to apply. The tracker's own store reads the same log file.
        val seeder = PendingEventsStore(context, 10)
        seeder.append(drainedEvent("zone-a", "ENTER"))
        seeder.shutdown()

        // onCreate wires persistence into the engine and publishes the instance;
        // restoreZonesFromStorage only runs on startTracking, so a bridge that
        // drains here hits a live Service with no zones registered.
        val controller = Robolectric.buildService(LocationTracker::class.java).create()
        try {
            assertEquals(0, controller.get().geofenceEngineForOsGeofence.getZoneCount())

            val drained = LocationTracker.drainPendingEvents(context)

            assertEquals("the batch is still returned to the caller", 1, drained.size)
            assertEquals("zone-a", drained[0]["zoneId"])
            assertEquals(
                mapOf("zone-a" to true, "zone-b" to true, "zone-c" to true),
                persistence.loadZoneStates()
            )
        } finally {
            controller.destroy()
        }
    }
}

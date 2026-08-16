package io.polyfence.core

import android.location.Location
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Direct coverage of the direction-doc §9 drain-then-reconcile ordering rule:
 * zones whose enter/exit history was already delivered via drainPendingEvents
 * must not fire a RECOVERY_ENTER / RECOVERY_EXIT in the following reconcile
 * pass. Runs under Robolectric so `android.location.Location` has working
 * setters — the plain-JUnit stub silently no-ops `latitude = x`, which would
 * strand every reconcile against a (0,0) coordinate.
 */
@RunWith(RobolectricTestRunner::class)
class DrainThenReconcileTest {

    private lateinit var engine: GeofenceEngine
    private val emittedEvents = mutableListOf<Triple<String, String, Location>>()

    @Before
    fun setUp() {
        engine = GeofenceEngine()
        emittedEvents.clear()
        engine.setEventCallback { zoneId, eventType, location, _ ->
            emittedEvents.add(Triple(zoneId, eventType, location))
        }
        engine.addZone("zone-a", "Zone A", circleAt(50.0, 0.0))
        engine.addZone("zone-b", "Zone B", circleAt(51.0, 0.0))
    }

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
     * Force the engine into the mismatch-recovery branch of reconcileZoneStates
     * without wiring up a full ZonePersistence. The flag is private — reflection
     * is the least-invasive path, matching how LocationTrackerConfigTest reaches
     * private state elsewhere in the test tree.
     */
    private fun forceRecoveredFromPersistence() {
        val field = GeofenceEngine::class.java.getDeclaredField("stateRecoveredFromPersistence")
        field.isAccessible = true
        field.setBoolean(engine, true)
    }

    // --- applyDrainedEventsToState primitive coverage ---

    @Test
    fun `applyDrainedEventsToState with empty list is a no-op`() {
        // Baseline: addZone in setUp populates zoneStates[id] = false for both zones.
        val baseline = engine.getCurrentZoneStates().toMap()
        val touched = engine.applyDrainedEventsToState(emptyList())
        assertTrue(touched.isEmpty())
        assertEquals(baseline, engine.getCurrentZoneStates())
    }

    @Test
    fun `applyDrainedEventsToState maps event types to inside-state correctly`() {
        val events = listOf(
            drainedEvent("zone-a", "ENTER"),
            drainedEvent("zone-b", "EXIT")
        )
        val touched = engine.applyDrainedEventsToState(events)
        assertEquals(setOf("zone-a", "zone-b"), touched)
        val states = engine.getCurrentZoneStates()
        assertEquals(true, states["zone-a"])
        assertEquals(false, states["zone-b"])
    }

    @Test
    fun `applyDrainedEventsToState skips membership-neutral event types`() {
        // zone-a starts at false from addZone. SIGNAL_* events do not touch state.
        val events = listOf(
            drainedEvent("zone-a", "SIGNAL_LOST"),
            drainedEvent("zone-a", "SIGNAL_RESTORED")
        )
        val touched = engine.applyDrainedEventsToState(events)
        assertTrue(touched.isEmpty())
        assertEquals(false, engine.getCurrentZoneStates()["zone-a"])
    }

    @Test
    fun `applyDrainedEventsToState treats DWELL as inside`() {
        val touched = engine.applyDrainedEventsToState(listOf(drainedEvent("zone-a", "DWELL")))
        assertEquals(setOf("zone-a"), touched)
        assertEquals(true, engine.getCurrentZoneStates()["zone-a"])
    }

    // --- drain-then-reconcile ordering coverage ---
    //
    // The direction-doc §9 invariant is met by applyDrainedEventsToState
    // running BEFORE reconcile: reconcile sees the post-drain truth and its
    // normal mismatch check produces the right output. No skip-set — an
    // absolute skip would incorrectly suppress the eviction/re-enter case
    // (drain returned a complete visit ending outside, but user is actually
    // inside → recovery MUST fire).

    @Test
    fun `reconcile fires RECOVERY_ENTER for a zone whose persisted state does not match actual`() {
        forceRecoveredFromPersistence()
        val insideZoneA = locationAt(50.0, 0.0)
        engine.reconcileZoneStates(insideZoneA)

        val zoneARecovery = emittedEvents.firstOrNull {
            it.first == "zone-a" && it.second == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        assertNotNull("zone-a should fire RECOVERY_ENTER on genuine mismatch", zoneARecovery)
    }

    @Test
    fun `drain-then-reconcile complete-visit scenario — no double-report`() {
        // Roadie's canonical scenario: user entered zone-a, exited zone-a, all
        // while the JS runtime was dead. Both events queued; drain replays them.
        // applyDrainedEventsToState brings zoneStates[zone-a] to false (final
        // post-EXIT state). Reconcile then sees actual=outside for zone-a and
        // does NOT fire RECOVERY_EXIT because state is already consistent —
        // no mismatch, no recovery event.
        val events = listOf(
            drainedEvent("zone-a", "ENTER"),
            drainedEvent("zone-a", "EXIT")
        )
        val touched = engine.applyDrainedEventsToState(events)
        assertEquals(setOf("zone-a"), touched)
        assertEquals(false, engine.getCurrentZoneStates()["zone-a"])

        forceRecoveredFromPersistence()
        val outsideBoth = locationAt(52.0, 0.0)
        engine.reconcileZoneStates(outsideBoth)

        val zoneARecovery = emittedEvents.firstOrNull {
            it.first == "zone-a" &&
                (it.second == GeofenceEngine.EVENT_RECOVERY_ENTER || it.second == GeofenceEngine.EVENT_RECOVERY_EXIT)
        }
        assertNull("zone-a must NOT double-report — drain already delivered the enter/exit", zoneARecovery)
    }

    @Test
    fun `drain contained complete visit but user re-entered — RECOVERY_ENTER MUST fire`() {
        // Phase 1 §5.5 edge case: the queue captured a complete visit
        // [ENTER, EXIT] to zone-a. Between the EXIT and the drain, the user
        // re-entered zone-a and a subsequent ENTER was dropped because the
        // queue was full at the time (eviction). Now on resume, the user is
        // still INSIDE zone-a.
        //
        // After applyDrainedEventsToState: zoneStates[zone-a] = false (final
        // state after the EXIT that was in the queue). Reconcile sees
        // persistedState=false, actualState=true → genuine mismatch → MUST
        // fire RECOVERY_ENTER so the consumer recovers the missed re-entry.
        val events = listOf(
            drainedEvent("zone-a", "ENTER"),
            drainedEvent("zone-a", "EXIT")
        )
        val touched = engine.applyDrainedEventsToState(events)
        assertEquals(setOf("zone-a"), touched)
        assertEquals(false, engine.getCurrentZoneStates()["zone-a"])

        forceRecoveredFromPersistence()
        val insideZoneA = locationAt(50.0, 0.0)
        engine.reconcileZoneStates(insideZoneA)

        val zoneARecovery = emittedEvents.firstOrNull {
            it.first == "zone-a" && it.second == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        assertNotNull("Reconcile MUST fire RECOVERY_ENTER for zone-a — drain's complete visit ended outside but user is now inside (missed re-entry due to queue eviction)", zoneARecovery)
    }

    @Test
    fun `drain-then-reconcile still-inside scenario — no duplicate RECOVERY_ENTER`() {
        // User entered zone-a while dead and is STILL INSIDE on resume. Drain
        // delivers the ENTER. applyDrainedEventsToState flips
        // zoneStates[zone-a] = true. Reconcile then sees persisted=true /
        // actual=true → no mismatch → no RECOVERY_ENTER. Consumer sees just
        // the drained ENTER once.
        engine.applyDrainedEventsToState(listOf(drainedEvent("zone-a", "ENTER")))
        forceRecoveredFromPersistence()

        val insideZoneA = locationAt(50.0, 0.0)
        engine.reconcileZoneStates(insideZoneA)

        val zoneARecovery = emittedEvents.firstOrNull {
            it.first == "zone-a" && it.second == GeofenceEngine.EVENT_RECOVERY_ENTER
        }
        assertNull("No duplicate RECOVERY_ENTER for zone-a — drain-applied state matches actual", zoneARecovery)
    }
}

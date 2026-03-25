package io.polyfence.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for ZonePersistence.
 * Tests SharedPreferences-based zone storage on a real Android context.
 */
@RunWith(AndroidJUnit4::class)
class ZonePersistenceInstrumentedTest {

    private lateinit var persistence: ZonePersistence

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        persistence = ZonePersistence(context)
        persistence.clearAllZones()
        persistence.clearAllZoneStates()
    }

    // ========================================================================
    // Zone Data Persistence
    // ========================================================================

    @Test
    fun saveZone_andLoadAll_returnsMatchingData() {
        val zoneData = mapOf<String, Any>(
            "type" to "circle",
            "center" to mapOf("latitude" to 40.7128, "longitude" to -74.0060),
            "radius" to 100.0
        )

        persistence.saveZone("zone-1", "NYC Zone", zoneData)

        val loaded = persistence.loadAllZones()
        assertEquals("Should have 1 zone", 1, loaded.size)
        assertTrue("Should contain zone-1", loaded.containsKey("zone-1"))

        val (id, name, _) = loaded["zone-1"]!!
        assertEquals("zone-1", id)
        assertEquals("NYC Zone", name)
    }

    @Test
    fun saveMultipleZones_allPersisted() {
        persistence.saveZone("zone-1", "Zone 1", mapOf("type" to "circle", "radius" to 100.0))
        persistence.saveZone("zone-2", "Zone 2", mapOf("type" to "circle", "radius" to 200.0))
        persistence.saveZone("zone-3", "Zone 3", mapOf("type" to "polygon"))

        assertEquals("Should have 3 zones", 3, persistence.getZoneCount())
        assertTrue(persistence.hasZone("zone-1"))
        assertTrue(persistence.hasZone("zone-2"))
        assertTrue(persistence.hasZone("zone-3"))
    }

    @Test
    fun removeZone_deletesFromStorage() {
        persistence.saveZone("zone-1", "Zone 1", mapOf("type" to "circle"))
        persistence.saveZone("zone-2", "Zone 2", mapOf("type" to "circle"))

        persistence.removeZone("zone-1")

        assertEquals("Should have 1 zone after removal", 1, persistence.getZoneCount())
        assertFalse("zone-1 should be removed", persistence.hasZone("zone-1"))
        assertTrue("zone-2 should remain", persistence.hasZone("zone-2"))
    }

    @Test
    fun clearAllZones_emptiesStorage() {
        persistence.saveZone("zone-1", "Zone 1", mapOf("type" to "circle"))
        persistence.saveZone("zone-2", "Zone 2", mapOf("type" to "circle"))

        persistence.clearAllZones()

        assertEquals("Should have 0 zones", 0, persistence.getZoneCount())
    }

    @Test
    fun hasZone_returnsFalseForNonexistent() {
        assertFalse(persistence.hasZone("nonexistent"))
    }

    @Test
    fun saveZone_overwritesExisting() {
        persistence.saveZone("zone-1", "Original", mapOf("type" to "circle"))
        persistence.saveZone("zone-1", "Updated", mapOf("type" to "polygon"))

        assertEquals("Should still have 1 zone", 1, persistence.getZoneCount())
        val loaded = persistence.loadAllZones()
        assertEquals("Name should be updated", "Updated", loaded["zone-1"]!!.second)
    }

    // ========================================================================
    // Zone State Persistence
    // ========================================================================

    @Test
    fun saveZoneStates_andLoad_returnsMatchingStates() {
        val states = mapOf("zone-1" to true, "zone-2" to false, "zone-3" to true)

        persistence.saveZoneStates(states)

        val loaded = persistence.loadZoneStates()
        assertEquals(3, loaded.size)
        assertEquals(true, loaded["zone-1"])
        assertEquals(false, loaded["zone-2"])
        assertEquals(true, loaded["zone-3"])
    }

    @Test
    fun saveZoneState_singleUpdate_mergesWithExisting() {
        persistence.saveZoneStates(mapOf("zone-1" to false, "zone-2" to false))

        persistence.saveZoneState("zone-1", true)

        val loaded = persistence.loadZoneStates()
        assertEquals(true, loaded["zone-1"])
        assertEquals(false, loaded["zone-2"])
    }

    @Test
    fun removeZoneState_deletesSpecificState() {
        persistence.saveZoneStates(mapOf("zone-1" to true, "zone-2" to false))

        persistence.removeZoneState("zone-1")

        val loaded = persistence.loadZoneStates()
        assertFalse("zone-1 state should be removed", loaded.containsKey("zone-1"))
        assertTrue("zone-2 state should remain", loaded.containsKey("zone-2"))
    }

    @Test
    fun clearAllZoneStates_emptiesStateStorage() {
        persistence.saveZoneStates(mapOf("zone-1" to true, "zone-2" to false))

        persistence.clearAllZoneStates()

        val loaded = persistence.loadZoneStates()
        assertTrue("States should be empty", loaded.isEmpty())
    }

    @Test
    fun hasPersistedZoneStates_reflectsStorageState() {
        assertFalse("Should be false initially", persistence.hasPersistedZoneStates())

        persistence.saveZoneStates(mapOf("zone-1" to true))
        assertTrue("Should be true after saving", persistence.hasPersistedZoneStates())

        persistence.clearAllZoneStates()
        assertFalse("Should be false after clearing", persistence.hasPersistedZoneStates())
    }

    @Test
    fun getLastStateUpdateTime_returnsRecentTimestamp() {
        val before = System.currentTimeMillis()
        persistence.saveZoneStates(mapOf("zone-1" to true))
        val after = System.currentTimeMillis()

        val lastUpdate = persistence.getLastStateUpdateTime()
        assertTrue("Last update should be >= before", lastUpdate >= before)
        assertTrue("Last update should be <= after", lastUpdate <= after)
    }
}

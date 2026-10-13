package io.polyfence.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Reading one zone's stored metadata back out: `loadZoneData` and
 * `loadZoneName`.
 *
 * Before these, data went in through `saveZone` and only came back out through
 * `loadAllZones`, so a caller holding one zone id had to convert every stored
 * zone to answer a question about one of them.
 *
 * Deliberately a Robolectric unit test rather than an instrumented one.
 * `ZonePersistenceInstrumentedTest` covers neighbouring ground in
 * `src/androidTest`, but CI runs `gradlew test` and never
 * `connectedAndroidTest`, so nothing in that directory runs on a pull request.
 */
@RunWith(RobolectricTestRunner::class)
class ZoneMetadataReadTest {

    private lateinit var context: Context
    private lateinit var persistence: ZonePersistence

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        // Preferences are process-wide, so a previous test's zones would read as
        // this test's starting state.
        context.getSharedPreferences("polyfence_zones", Context.MODE_PRIVATE)
            .edit().clear().commit()
        persistence = ZonePersistence(context)
    }

    // -------- loadZoneData --------

    @Test
    fun `returns the data saveZone stored`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue", "radius" to 50))

        val data = persistence.loadZoneData("z1")
        assertNotNull(data)
        assertEquals("blue", data!!["colour"])
        assertEquals(50, data["radius"])
    }

    @Test
    fun `returns null for a zone that was never saved`() {
        assertNull(persistence.loadZoneData("nope"))
    }

    @Test
    fun `returns null once the zone is removed`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue"))
        persistence.removeZone("z1")
        assertNull(persistence.loadZoneData("z1"))
    }

    @Test
    fun `returns null for every zone once all are cleared`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue"))
        persistence.saveZone("z2", "Work", mapOf("colour" to "red"))
        persistence.clearAllZones()
        assertNull(persistence.loadZoneData("z1"))
        assertNull(persistence.loadZoneData("z2"))
    }

    @Test
    fun `reads the zone asked for and not a neighbour`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue"))
        persistence.saveZone("z2", "Work", mapOf("colour" to "red"))

        assertEquals("blue", persistence.loadZoneData("z1")!!["colour"])
        assertEquals("red", persistence.loadZoneData("z2")!!["colour"])
    }

    @Test
    fun `round-trips a nested structure, not just flat values`() {
        // The realistic payload: a caller attaching its own object to a zone.
        persistence.saveZone(
            "z1",
            "Home",
            mapOf(
                "notes" to listOf("milk", "bread"),
                "meta" to mapOf("icon" to "house", "pinned" to true)
            )
        )

        val data = persistence.loadZoneData("z1")!!
        assertEquals(listOf("milk", "bread"), data["notes"])
        @Suppress("UNCHECKED_CAST")
        val meta = data["meta"] as Map<String, Any>
        assertEquals("house", meta["icon"])
        assertEquals(true, meta["pinned"])
    }

    @Test
    fun `an empty data map round-trips as empty rather than null`() {
        // Absent and "saved with nothing attached" are different answers.
        persistence.saveZone("z1", "Home", emptyMap())
        assertEquals(emptyMap<String, Any>(), persistence.loadZoneData("z1"))
    }

    @Test
    fun `a stored null comes back as JSONObject NULL at every depth`() {
        // Asserted rather than described, because a caller forwarding these
        // values somewhere null is expressible has to translate the sentinel,
        // and an == null check does not see it. The map's value type is
        // non-null, so a Java null cannot travel in it at all.
        val data = HashMap<String, Any?>()
        data["polygon"] = null
        data["meta"] = hashMapOf<String, Any?>("note" to null)
        data["list"] = arrayListOf<Any?>("a", null)
        @Suppress("UNCHECKED_CAST")
        persistence.saveZone("z1", "Home", data as Map<String, Any>)

        val back = persistence.loadZoneData("z1")!!

        assertSame(org.json.JSONObject.NULL, back["polygon"])

        @Suppress("UNCHECKED_CAST")
        val meta = back["meta"] as Map<String, Any>
        assertSame(org.json.JSONObject.NULL, meta["note"])

        @Suppress("UNCHECKED_CAST")
        val list = back["list"] as List<Any>
        assertEquals("a", list[0])
        assertSame(org.json.JSONObject.NULL, list[1])
    }

    // -------- loadZoneName --------

    @Test
    fun `returns the name saveZone stored`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue"))
        assertEquals("Home", persistence.loadZoneName("z1"))
    }

    @Test
    fun `returns a null name for a zone that was never saved`() {
        assertNull(persistence.loadZoneName("nope"))
    }

    @Test
    fun `returns a null name once the zone is removed`() {
        persistence.saveZone("z1", "Home", mapOf("colour" to "blue"))
        persistence.removeZone("z1")
        assertNull(persistence.loadZoneName("z1"))
    }

    @Test
    fun `overwriting a zone with less data leaves no stale fields`() {
        persistence.saveZone(
            "z1",
            "Home",
            mapOf("colour" to "blue", "note" to "milk", "pinned" to true)
        )
        persistence.saveZone("z1", "Work", mapOf("colour" to "red"))

        val data = persistence.loadZoneData("z1")!!
        assertEquals("red", data["colour"])
        assertNull("the previous note must not survive", data["note"])
        assertNull("the previous flag must not survive", data["pinned"])
        assertEquals("Work", persistence.loadZoneName("z1"))
    }

    // -------- the robustness the doc comment claims --------

    @Test
    fun `corruption of the outer string is not scoped, and the order decides what survives`() {
        // The limit the doc now admits. getSavedZones wraps its key loop in one
        // try and returns what it accumulated, so an entry that is not an
        // object hides every zone stored after it and none stored before it.
        // Asserted so the doc cannot drift back to claiming the stronger thing.
        val prefs = context.getSharedPreferences("polyfence_zones", Context.MODE_PRIVATE)

        prefs.edit().putString(
            "saved_zones",
            """{"good":{"id":"good","name":"Home","data":{"colour":"blue"},"timestamp":0},""" +
                """"bad":"oops"}"""
        ).commit()
        assertEquals(
            "a zone stored before the bad entry still answers",
            "blue",
            persistence.loadZoneData("good")!!["colour"]
        )

        prefs.edit().putString(
            "saved_zones",
            """{"bad":"oops",""" +
                """"good":{"id":"good","name":"Home","data":{"colour":"blue"},"timestamp":0}}"""
        ).commit()
        assertNull(
            "a zone stored after the bad entry is hidden, which is the documented limit",
            persistence.loadZoneData("good")
        )
        assertEquals(0, persistence.getZoneCount())
    }

    @Test
    fun `one unreadable zone does not hide a readable one, which loadAllZones cannot manage`() {
        // loadAllZones wraps the whole set in a single try, so one unparseable
        // zone costs the caller every zone. A single-zone read is scoped to the
        // zone asked for. This asserts both halves, so the claim in
        // loadZoneData's doc comment cannot quietly stop being true.
        persistence.saveZone("good", "Home", mapOf("colour" to "blue"))

        // Corrupt one entry in place: "data" is a string where the reader
        // expects an object, which is what a format change would look like.
        val prefs = context.getSharedPreferences("polyfence_zones", Context.MODE_PRIVATE)
        val stored = org.json.JSONObject(prefs.getString("saved_zones", "{}")!!)
        stored.put(
            "bad",
            org.json.JSONObject().apply {
                put("id", "bad")
                put("name", "Broken")
                put("data", "not-an-object")
                put("timestamp", 0L)
            }
        )
        prefs.edit().putString("saved_zones", stored.toString()).commit()

        assertTrue(
            "loadAllZones is expected to lose everything here; if it stops doing " +
                "that, loadZoneData's robustness note needs rewording",
            persistence.loadAllZones().isEmpty()
        )
        assertEquals("blue", persistence.loadZoneData("good")!!["colour"])
        assertNull(persistence.loadZoneData("bad"))
    }
}

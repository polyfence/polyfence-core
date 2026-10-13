package io.polyfence.core

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.polyfence.core.utils.PolyfenceConfig
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf

/**
 * Host-settable notification text: the placeholder renderer, the defaults, and
 * the five places a config field has to appear before a host can actually use
 * it.
 *
 * The last part is the point of this file. `PolyfenceConfig` persists these, so
 * storage and the read path alone make the feature look finished: the strings
 * are there, the notification picks them up, and every foreground test passes.
 * It stays broken for every bridge consumer until `updateConfigurationFromMap`
 * can write them, `getCurrentConfigurationMap` can read them back, and
 * `buildDefaultConfigurationMap` can restore them. Those three are asserted
 * here so removing any one of them turns this file red.
 */
@RunWith(RobolectricTestRunner::class)
class NotificationTextTest {

    private lateinit var tracker: LocationTracker
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        // Preferences are process-wide, so a previous test's writes would read
        // as this test's starting state.
        context.getSharedPreferences("polyfence_config", Context.MODE_PRIVATE)
            .edit().clear().commit()
        tracker = Robolectric.buildService(LocationTracker::class.java).create().get()
        // Companion-level and process-wide, so a test that raises it would
        // otherwise decide the outcome of every test after it.
        setIsRunning(false)
    }

    @After
    fun tearDown() {
        setIsRunning(false)
    }

    /**
     * `isRunning` is private to the LocationTracker companion and is set only by
     * a real foreground start. Reach past visibility rather than widen the
     * production surface for a test, which is what this file's neighbours do for
     * `trackingScheduler`.
     */
    private fun setIsRunning(value: Boolean) {
        val companionInstance = LocationTracker::class.java
            .getDeclaredField("Companion")
            .apply { isAccessible = true }
            .get(null)
        LocationTracker::class.java
            .getDeclaredField("isRunning")
            .apply { isAccessible = true }
            .setBoolean(companionInstance, value)
    }

    private fun postedTrackingNotification(): Notification? {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return shadowOf(manager).getNotification(1001)
    }

    private fun titleOf(notification: Notification?): String? =
        notification?.extras?.getString(Notification.EXTRA_TITLE)

    private fun channel(id: String): android.app.NotificationChannel? {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.getNotificationChannel(id)
    }

    private fun invokeUpdateConfigurationFromMap(configMap: Map<String, Any>) {
        val method = LocationTracker::class.java.getDeclaredMethod(
            "updateConfigurationFromMap",
            Map::class.java
        )
        method.isAccessible = true
        method.invoke(tracker, configMap)
    }

    @Suppress("UNCHECKED_CAST")
    private fun notificationTextOf(map: Map<String, Any>): Map<String, Any> =
        map["notificationText"] as Map<String, Any>

    // -------- the placeholder renderer --------

    @Test
    fun `renders the zone name into the slot`() {
        assertEquals(
            "Entered Home",
            LocationTracker.renderNotificationText("Entered {zone}", mapOf("zone" to "Home"))
        )
    }

    @Test
    fun `renders a template that puts the slot first`() {
        // The reason substitution is used instead of a fixed prefix: a host
        // writing in a language that leads with the place has to be able to.
        assertEquals(
            "Home: arrived",
            LocationTracker.renderNotificationText("{zone}: arrived", mapOf("zone" to "Home"))
        )
    }

    @Test
    fun `renders a template with no slot at all`() {
        // A host that wants the same line regardless of zone is making a choice
        // about its own copy, not a mistake.
        assertEquals(
            "You arrived",
            LocationTracker.renderNotificationText("You arrived", mapOf("zone" to "Home"))
        )
    }

    @Test
    fun `renders every occurrence when a slot repeats`() {
        assertEquals(
            "Home, welcome to Home",
            LocationTracker.renderNotificationText(
                "{zone}, welcome to {zone}",
                mapOf("zone" to "Home")
            )
        )
    }

    @Test
    fun `leaves a placeholder it has no value for exactly as written`() {
        // Blanking it would turn a host's typo into a sentence with a hole in
        // it. Left visible, the tray shows which line needs fixing.
        assertEquals(
            "Entered Home ({whatver})",
            LocationTracker.renderNotificationText(
                "Entered {zone} ({whatver})",
                mapOf("zone" to "Home")
            )
        )
    }

    @Test
    fun `renders hours and minutes independently`() {
        assertEquals(
            "2h 30min",
            LocationTracker.renderNotificationText(
                "{hours}h {minutes}min",
                mapOf("hours" to "2", "minutes" to "30")
            )
        )
    }

    // -------- defaults: a host that sets nothing sees no change --------

    @Test
    fun `an unconfigured host reads today's exact English`() {
        val cfg = PolyfenceConfig(context)
        assertEquals("Polyfence Active", cfg.trackingNotificationTitle)
        assertEquals("Monitoring geofence zones", cfg.trackingNotificationText)
        assertNull(cfg.trackingNotificationIconName)
        assertEquals("Entered {zone}", cfg.alertTitleEnter)
        assertEquals("Dwelling in {zone}", cfg.alertTitleDwell)
        assertEquals("Exited {zone}", cfg.alertTitleExit)
        assertEquals("Here under a minute", cfg.alertDwellBodyUnderMinute)
        assertEquals("Here {minutes} min", cfg.alertDwellBodyMinutes)
        assertEquals("Here {hours}h", cfg.alertDwellBodyHours)
        assertEquals("Here {hours}h {minutes} min", cfg.alertDwellBodyHoursMinutes)
    }

    @Test
    fun `the unconfigured defaults render to the strings this change replaced`() {
        // Belt and braces on the one promise that matters to an existing
        // integrator: upgrade, set nothing, see byte-identical text.
        val cfg = PolyfenceConfig(context)
        val zone = mapOf("zone" to "Home")
        assertEquals(
            "Entered Home",
            LocationTracker.renderNotificationText(cfg.alertTitleEnter, zone)
        )
        assertEquals(
            "Dwelling in Home",
            LocationTracker.renderNotificationText(cfg.alertTitleDwell, zone)
        )
        assertEquals(
            "Exited Home",
            LocationTracker.renderNotificationText(cfg.alertTitleExit, zone)
        )
        assertEquals(
            "Here 5 min",
            LocationTracker.renderNotificationText(
                cfg.alertDwellBodyMinutes,
                mapOf("minutes" to "5")
            )
        )
        assertEquals(
            "Here 2h",
            LocationTracker.renderNotificationText(
                cfg.alertDwellBodyHours,
                mapOf("hours" to "2")
            )
        )
        assertEquals(
            "Here 2h 30 min",
            LocationTracker.renderNotificationText(
                cfg.alertDwellBodyHoursMinutes,
                mapOf("hours" to "2", "minutes" to "30")
            )
        )
    }

    // -------- place 2: the write path --------

    @Test
    fun `updateConfiguration writes notification text a host sets`() {
        invokeUpdateConfigurationFromMap(
            mapOf(
                "notificationText" to mapOf(
                    "trackingTitle" to "Roadie",
                    "enterTitle" to "Arrivé à {zone}",
                    "dwellBodyMinutes" to "{minutes} minutes ici"
                )
            )
        )

        val cfg = PolyfenceConfig(context)
        assertEquals("Roadie", cfg.trackingNotificationTitle)
        assertEquals("Arrivé à {zone}", cfg.alertTitleEnter)
        assertEquals("{minutes} minutes ici", cfg.alertDwellBodyMinutes)
    }

    @Test
    fun `a partial write leaves the keys it did not mention alone`() {
        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("enterTitle" to "Arrivé à {zone}"))
        )

        val cfg = PolyfenceConfig(context)
        assertEquals("Arrivé à {zone}", cfg.alertTitleEnter)
        assertEquals("Exited {zone}", cfg.alertTitleExit)
        assertEquals("Polyfence Active", cfg.trackingNotificationTitle)
    }

    @Test
    fun `an ill-typed value is ignored rather than stored`() {
        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("enterTitle" to 42))
        )
        assertEquals("Entered {zone}", PolyfenceConfig(context).alertTitleEnter)
    }

    @Test
    fun `a config map with no notificationText key changes nothing`() {
        PolyfenceConfig(context).alertTitleEnter = "Arrivé à {zone}"
        invokeUpdateConfigurationFromMap(mapOf("enableDebugLogging" to true))
        assertEquals("Arrivé à {zone}", PolyfenceConfig(context).alertTitleEnter)
    }

    // -------- place 4: read-back --------

    @Test
    fun `getConfiguration emits the text a host set`() {
        PolyfenceConfig(context).alertTitleEnter = "Arrivé à {zone}"

        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        assertEquals("Arrivé à {zone}", emitted["enterTitle"])
    }

    @Test
    fun `getConfiguration falls back to defaults with no context`() {
        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(null))
        assertEquals("Entered {zone}", emitted["enterTitle"])
    }

    @Test
    fun `the null-context snapshot is a read, not the reset payload`() {
        // The two maps differ by one key and are not interchangeable.
        // trackingIconName is present and empty in the reset payload, because
        // empty is the value that clears an icon. Handing that out as a
        // configuration snapshot would make a read-then-write clear a host's
        // icon, which is the opposite of what the round-trip exists to protect.
        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(null))
        assertFalse(emitted.containsKey("trackingIconName"))
    }

    @Test
    fun `writing back the null-context snapshot does not clear a stored icon`() {
        // The failure the shape split prevents, asserted end to end.
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"

        val snapshot = LocationTracker.getCurrentConfigurationMap(null)
        invokeUpdateConfigurationFromMap(snapshot)

        assertEquals("ic_tracking", PolyfenceConfig(context).trackingNotificationIconName)
    }

    @Test
    fun `the null-context snapshot and a real unset read have the same keys`() {
        // One shape for "what is the configuration", whether or not a context
        // was available to read it from.
        val withContext = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        val withoutContext = notificationTextOf(LocationTracker.getCurrentConfigurationMap(null))

        assertEquals(withContext.keys, withoutContext.keys)
        assertEquals(withContext, withoutContext)
    }

    @Test
    fun `an unset icon name is absent rather than null`() {
        // The map crosses a bridge that cannot carry a null.
        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        assertFalse(emitted.containsKey("trackingIconName"))
    }

    @Test
    fun `a round-trip through getConfiguration does not reset the host's wording`() {
        // The failure this guards: read the config into a cache, write the cache
        // back, and wording the host set earlier is silently replaced by ours.
        PolyfenceConfig(context).alertTitleEnter = "Arrivé à {zone}"

        val readBack = LocationTracker.getCurrentConfigurationMap(context)
        invokeUpdateConfigurationFromMap(readBack)

        assertEquals("Arrivé à {zone}", PolyfenceConfig(context).alertTitleEnter)
    }

    // -------- place 5: defaults payload --------

    @Test
    fun `the reset payload carries the default text`() {
        val emitted = notificationTextOf(LocationTracker.buildDefaultConfigurationMap())
        assertEquals("Polyfence Active", emitted["trackingTitle"])
        assertEquals("Entered {zone}", emitted["enterTitle"])
        assertEquals("Here {hours}h {minutes} min", emitted["dwellBodyHoursMinutes"])
    }

    @Test
    fun `resetConfiguration restores the default text over a host's wording`() {
        PolyfenceConfig(context).alertTitleEnter = "Arrivé à {zone}"

        invokeUpdateConfigurationFromMap(LocationTracker.buildDefaultConfigurationMap())

        assertEquals("Entered {zone}", PolyfenceConfig(context).alertTitleEnter)
    }

    // -------- the renderer must not rescan what it just inserted --------

    @Test
    fun `a zone name that contains a placeholder is not substituted again`() {
        // A zone can legitimately be called "Bay {minutes}". Replacing slots one
        // at a time in the running result would rescan the name just inserted and
        // turn the host's own text into a number.
        assertEquals(
            "In Bay {minutes} for 12 min",
            LocationTracker.renderNotificationText(
                "In {zone} for {minutes} min",
                mapOf("zone" to "Bay {minutes}", "hours" to "2", "minutes" to "12")
            )
        )
    }

    @Test
    fun `a replacement that looks like another slot is left alone`() {
        assertEquals(
            "{hours}",
            LocationTracker.renderNotificationText(
                "{zone}",
                mapOf("zone" to "{hours}", "hours" to "9")
            )
        )
    }

    @Test
    fun `an unterminated brace is left exactly as written`() {
        assertEquals(
            "Entered {zone",
            LocationTracker.renderNotificationText("Entered {zone", mapOf("zone" to "Home"))
        )
    }

    @Test
    fun `an empty brace pair is left exactly as written`() {
        assertEquals(
            "Entered {} now",
            LocationTracker.renderNotificationText("Entered {} now", mapOf("zone" to "Home"))
        )
    }

    @Test
    fun `text after the last slot survives`() {
        assertEquals(
            "a Home b",
            LocationTracker.renderNotificationText("a {zone} b", mapOf("zone" to "Home"))
        )
    }

    // -------- the ongoing notification is reissued, not just restyled --------

    @Test
    fun `renaming the tracking notification while running updates what is posted`() {
        // It is built once at startForeground. Without a reissue the host watches
        // its zone alerts change while the notification the user is looking at
        // keeps the old words until the service restarts.
        setIsRunning(true)

        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("trackingTitle" to "Roadie"))
        )

        assertEquals("Roadie", titleOf(postedTrackingNotification()))
    }

    @Test
    fun `changing only alert wording does not reissue the tracking notification`() {
        setIsRunning(true)

        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("enterTitle" to "Arrivé à {zone}"))
        )

        assertNull(postedTrackingNotification())
    }

    @Test
    fun `nothing is posted when the service is not running`() {
        // isRunning is only set after startForeground returned, so posting
        // without it would put a notification in the tray where the service has
        // none, and the user could swipe this one away.
        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("trackingTitle" to "Roadie"))
        )

        assertNull(postedTrackingNotification())
    }

    // -------- reset has to be able to clear the icon --------

    @Test
    fun `resetConfiguration clears a host-set icon`() {
        // The read map omits this key when unset, so the reset payload cannot say
        // "no icon" by omission the way it can for the nine sentences. An empty
        // string is the value that means cleared.
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"

        invokeUpdateConfigurationFromMap(LocationTracker.buildDefaultConfigurationMap())

        assertNull(PolyfenceConfig(context).trackingNotificationIconName)
    }

    @Test
    fun `an empty icon name clears a host-set icon`() {
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"

        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("trackingIconName" to ""))
        )

        assertNull(PolyfenceConfig(context).trackingNotificationIconName)
    }

    @Test
    fun `a partial write that omits the icon leaves it alone`() {
        // Omission means "leave what is stored alone", which is what every other
        // partial update does. Only an explicit empty value clears.
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"

        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("trackingTitle" to "Roadie"))
        )

        assertEquals("ic_tracking", PolyfenceConfig(context).trackingNotificationIconName)
    }

    @Test
    fun `getConfiguration omits the icon key again after a reset`() {
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"
        invokeUpdateConfigurationFromMap(LocationTracker.buildDefaultConfigurationMap())

        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        assertFalse(emitted.containsKey("trackingIconName"))
    }

    @Test
    fun `the reset payload carries an empty icon name rather than omitting it`() {
        val defaults = notificationTextOf(LocationTracker.buildDefaultConfigurationMap())
        assertEquals("", defaults["trackingIconName"])
    }

    // -------- channel labels, which live in the system Settings app --------

    @Test
    fun `an unconfigured host reads today's channel labels`() {
        val cfg = PolyfenceConfig(context)
        assertEquals("Location Tracking", cfg.trackingChannelName)
        assertEquals("Background location tracking", cfg.trackingChannelDescription)
        assertEquals("Geofence Alerts", cfg.alertChannelName)
        assertEquals("Zone entry and exit notifications", cfg.alertChannelDescription)
    }

    @Test
    @Config(sdk = [34])
    fun `the channels are created with the default labels`() {
        // onCreate built them, so this is what a host that sets nothing ships.
        assertEquals("Location Tracking", channel("polyfence_tracking")?.name)
        assertEquals("Geofence Alerts", channel("polyfence_alerts")?.name)
    }

    @Test
    @Config(sdk = [34])
    fun `relabelling a channel updates the live channel, not just the stored string`() {
        // The point of the test. A channel is otherwise only built at service
        // start, so storing the new label without re-creating the channel would
        // leave the phone's Settings screen in English until the next launch.
        invokeUpdateConfigurationFromMap(
            mapOf(
                "notificationText" to mapOf(
                    "trackingChannelName" to "Suivi de position",
                    "trackingChannelDescription" to "Suivi en arrière-plan",
                    "alertChannelName" to "Alertes de zone",
                    "alertChannelDescription" to "Entrées et sorties de zone"
                )
            )
        )

        assertEquals("Suivi de position", channel("polyfence_tracking")?.name)
        assertEquals("Suivi en arrière-plan", channel("polyfence_tracking")?.description)
        assertEquals("Alertes de zone", channel("polyfence_alerts")?.name)
        assertEquals("Entrées et sorties de zone", channel("polyfence_alerts")?.description)
    }

    @Test
    @Config(sdk = [34])
    fun `relabelling one channel leaves the other alone`() {
        invokeUpdateConfigurationFromMap(
            mapOf("notificationText" to mapOf("alertChannelName" to "Alertes de zone"))
        )

        assertEquals("Alertes de zone", channel("polyfence_alerts")?.name)
        assertEquals("Location Tracking", channel("polyfence_tracking")?.name)
    }

    @Test
    fun `getConfiguration emits the channel labels a host set`() {
        PolyfenceConfig(context).alertChannelName = "Alertes de zone"

        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        assertEquals("Alertes de zone", emitted["alertChannelName"])
    }

    @Test
    @Config(sdk = [34])
    fun `resetConfiguration restores the default channel labels`() {
        PolyfenceConfig(context).alertChannelName = "Alertes de zone"

        invokeUpdateConfigurationFromMap(LocationTracker.buildDefaultConfigurationMap())

        assertEquals("Geofence Alerts", PolyfenceConfig(context).alertChannelName)
        assertEquals("Geofence Alerts", channel("polyfence_alerts")?.name)
    }

    @Test
    fun `a round-trip through getConfiguration does not reset the host's channel labels`() {
        PolyfenceConfig(context).alertChannelName = "Alertes de zone"

        val readBack = LocationTracker.getCurrentConfigurationMap(context)
        invokeUpdateConfigurationFromMap(readBack)

        assertEquals("Alertes de zone", PolyfenceConfig(context).alertChannelName)
    }

    @Test
    fun `the reset payload carries every channel label`() {
        val defaults = notificationTextOf(LocationTracker.buildDefaultConfigurationMap())
        assertEquals("Location Tracking", defaults["trackingChannelName"])
        assertEquals("Background location tracking", defaults["trackingChannelDescription"])
        assertEquals("Geofence Alerts", defaults["alertChannelName"])
        assertEquals("Zone entry and exit notifications", defaults["alertChannelDescription"])
    }

    @Test
    fun `the group emits exactly the documented keys`() {
        // The exact set rather than the count. A count catches a key dropped
        // from the read side but not one renamed there, and a rename is the same
        // defect from a caller's point of view: the value it set never comes
        // back. These names are the wire contract both bridges will carry.
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"

        val emitted = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        assertEquals(
            setOf(
                "trackingTitle",
                "trackingText",
                "trackingIconName",
                "enterTitle",
                "dwellTitle",
                "exitTitle",
                "dwellBodyUnderMinute",
                "dwellBodyMinutes",
                "dwellBodyHours",
                "dwellBodyHoursMinutes",
                "trackingChannelName",
                "trackingChannelDescription",
                "alertChannelName",
                "alertChannelDescription"
            ),
            emitted.keys
        )
    }

    @Test
    fun `the reset payload emits the same keys as the read side, bar the icon`() {
        // Reset carries trackingIconName as an empty string where the read side
        // omits it when unset, so the two sets are otherwise identical. A key
        // present in one and missing from the other is a reset that cannot
        // restore it, or a value that cannot be read back.
        PolyfenceConfig(context).trackingNotificationIconName = "ic_tracking"
        val readSide = notificationTextOf(LocationTracker.getCurrentConfigurationMap(context))
        val resetSide = notificationTextOf(LocationTracker.buildDefaultConfigurationMap())

        assertEquals(readSide.keys, resetSide.keys)
    }

    // -------- which dwell body applies, and with what numbers --------

    @Test
    fun `the dwell body table holds at every boundary`() {
        // A four-way branch plus a total-versus-remainder switch, and the whole
        // thing had no coverage because formatDwellBody needs a live engine.
        // Both the branch choice and the number each sentence is handed are
        // asserted here, at and either side of every boundary.
        data class Case(
            val totalMinutes: Int,
            val variant: LocationTracker.DwellBodyVariant,
            val hours: Int,
            val minutes: Int
        )

        val cases = listOf(
            Case(-5, LocationTracker.DwellBodyVariant.UNDER_MINUTE, 0, 0),
            Case(0, LocationTracker.DwellBodyVariant.UNDER_MINUTE, 0, 0),
            Case(1, LocationTracker.DwellBodyVariant.MINUTES, 0, 1),
            Case(59, LocationTracker.DwellBodyVariant.MINUTES, 0, 59),
            Case(60, LocationTracker.DwellBodyVariant.HOURS, 1, 0),
            Case(61, LocationTracker.DwellBodyVariant.HOURS_MINUTES, 1, 1),
            Case(119, LocationTracker.DwellBodyVariant.HOURS_MINUTES, 1, 59),
            Case(120, LocationTracker.DwellBodyVariant.HOURS, 2, 0),
            Case(121, LocationTracker.DwellBodyVariant.HOURS_MINUTES, 2, 1),
            Case(1440, LocationTracker.DwellBodyVariant.HOURS, 24, 0)
        )

        for (case in cases) {
            val selection = LocationTracker.selectDwellBody(case.totalMinutes)
            assertEquals("variant at ${case.totalMinutes}", case.variant, selection.variant)
            assertEquals("hours at ${case.totalMinutes}", case.hours, selection.hours)
            assertEquals("minutes at ${case.totalMinutes}", case.minutes, selection.minutes)
        }
    }

    @Test
    fun `a negative duration never reaches a host's sentence`() {
        // Clock skew between a dwell start and the reading can produce one.
        // "-1" in a host's wording reads as a bug in their app.
        val selection = LocationTracker.selectDwellBody(-1)
        assertEquals(0, selection.hours)
        assertEquals(0, selection.minutes)
        assertEquals(LocationTracker.DwellBodyVariant.UNDER_MINUTE, selection.variant)
    }

    @Test
    fun `the under-an-hour body is handed the whole duration, not the remainder`() {
        // Below an hour the two are the same number, since `spent % 60` is
        // `spent` for 0..59, so swapping them there cannot be detected by any
        // input and is not worth hunting. The switch that does matter is the
        // one at and above an hour, where the table above pins the remainder.
        assertEquals(42, LocationTracker.selectDwellBody(42).minutes)
        assertEquals(1, LocationTracker.selectDwellBody(61).minutes)
    }

    // -------- blank handling, which differs by field on purpose --------

    @Test
    fun `an empty or ASCII-whitespace icon name reads as unset`() {
        // The rule is spelled out rather than borrowed, because the obvious
        // predicate on each platform disagrees with the other: Kotlin's isBlank
        // counts U+001C to U+001F and not U+0085, Foundation's
        // whitespacesAndNewlines the reverse. The same table runs on iOS.
        val cfg = PolyfenceConfig(context)
        for (empty in listOf(
            "", " ", "   ", "\t", "\n", "\r", "\r\n", " \n ", "\u000B", "\u000C", " \t\r\n "
        )) {
            cfg.trackingNotificationIconName = empty
            assertNull(
                "${empty.map { it.code }} must read as unset",
                cfg.trackingNotificationIconName
            )
        }
    }

    @Test
    fun `anything outside ASCII whitespace is kept as a name`() {
        // Including the separators and exotic spaces the two platforms disagree
        // about. A drawable cannot be named with them, so the resolver falls
        // back visibly rather than the SDK discarding what the host set.
        val cfg = PolyfenceConfig(context)
        for (kept in listOf("\u0085", "\u00A0", "\u2028", "\u2029", "\u3000", "\u001C", "ic_x")) {
            cfg.trackingNotificationIconName = kept
            assertEquals(
                "${kept.map { it.code }} must be kept",
                kept,
                cfg.trackingNotificationIconName
            )
        }
    }

    @Test
    fun `a blank sentence field is kept, unlike the icon`() {
        // Deliberately different from the icon, and the only place it is
        // written down. An empty title gives a titleless notification, which is
        // the host's choice to make.
        val cfg = PolyfenceConfig(context)
        cfg.alertTitleEnter = ""
        assertEquals("", cfg.alertTitleEnter)
        cfg.trackingNotificationTitle = "   "
        assertEquals("   ", cfg.trackingNotificationTitle)
    }

    // -------- the renderer over awkward scalars --------

    @Test
    fun `a combining mark after a brace does not abandon the rest of the template`() {
        // Swift scanned grapheme clusters, so "}" followed by a combining mark
        // was one Character that did not equal "}": the search missed and every
        // remaining slot went unrendered. Kotlin walks code units. Same answer
        // is the contract.
        assertEquals(
            "Homé for 12 min",
            LocationTracker.renderNotificationText(
                "{zone}́ for {minutes} min",
                mapOf("zone" to "Home", "minutes" to "12")
            )
        )
    }

    @Test
    fun `an emoji in the template and in the replacement both survive`() {
        assertEquals(
            "🚀 Casa 🏠 now",
            LocationTracker.renderNotificationText(
                "🚀 {zone} now",
                mapOf("zone" to "Casa 🏠")
            )
        )
    }
}

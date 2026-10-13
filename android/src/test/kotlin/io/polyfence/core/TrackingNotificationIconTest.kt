package io.polyfence.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The ongoing tracking notification's small icon is resolved by resource name,
 * and the resolved value is checked before it is used.
 *
 * This matters more than a wrong picture. The notification goes straight to
 * `startForeground`, and Android kills the service when that call does not
 * land, so an icon that no longer resolves must degrade to the platform glyph
 * rather than take background tracking down with it.
 *
 * The branch exists because resource ids move. They are assigned at compile
 * time and shift when the host app's resources change, so an id stored in
 * preferences stops matching after the host's next release. The name survives,
 * which is why the setting holds a name and resolution happens at call time.
 *
 * Pure Kotlin: the resolver is injected, so no Context or Robolectric is
 * needed to exercise every branch.
 */
class TrackingNotificationIconTest {

    private val platformGlyph = android.R.drawable.ic_menu_mylocation

    @Test
    fun `unset name falls back to the platform glyph`() {
        val icon = LocationTracker.resolveTrackingIcon(null) { fail_("must not resolve when unset") }
        assertEquals(platformGlyph, icon)
    }

    @Test
    fun `a name that resolves is used`() {
        val hostIcon = 0x7f080123
        val icon = LocationTracker.resolveTrackingIcon("ic_tracking") { name ->
            assertEquals("ic_tracking", name)
            hostIcon
        }
        assertEquals(hostIcon, icon)
    }

    @Test
    fun `a name that no longer resolves falls back rather than returning zero`() {
        // getIdentifier answers 0 for a name that is not there, which is what
        // happens after the host app renames or removes the drawable. Returning
        // it would reach setSmallIcon and then startForeground.
        val icon = LocationTracker.resolveTrackingIcon("ic_renamed_away") { 0 }
        assertEquals(platformGlyph, icon)
        assert(icon != 0) { "a zero icon id reaches startForeground and kills the service" }
    }

    @Test
    fun `an empty name is treated as unresolvable`() {
        val icon = LocationTracker.resolveTrackingIcon("") { 0 }
        assertEquals(platformGlyph, icon)
    }

    private fun fail_(message: String): Int = throw AssertionError(message)
}

package io.polyfence.core

import android.content.Context
import android.content.SharedPreferences
import android.app.AlarmManager
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.mockito.ArgumentMatchers.any
import org.mockito.ArgumentMatchers.anyBoolean
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when` as whenever

/**
 * Round-trip coverage for the schedule config portion of
 * `getConfiguration()`: `updateConfig(map)` → `getConfigMap()` must
 * preserve the nested `TimeOfDay` shape (`{hour, minute}` blocks)
 * exactly. The TypeScript / Dart `TimeWindow` interfaces on the
 * bridges are pinned to this shape, so catching a divergence at the
 * platform level prevents the on-wire shape from silently changing.
 */
class TrackingSchedulerTest {

    private lateinit var mockContext: Context
    private lateinit var mockPrefs: SharedPreferences
    private lateinit var mockEditor: SharedPreferences.Editor
    private lateinit var scheduler: TrackingScheduler

    @Before
    fun setUp() {
        mockContext = mock(Context::class.java)
        mockPrefs = mock(SharedPreferences::class.java)
        mockEditor = mock(SharedPreferences.Editor::class.java)
        val mockAlarmManager: AlarmManager = mock(AlarmManager::class.java)

        whenever(mockContext.getSharedPreferences(anyString(), anyInt())).thenReturn(mockPrefs)
        whenever(mockContext.getSystemService(Context.ALARM_SERVICE)).thenReturn(mockAlarmManager)
        whenever(mockPrefs.edit()).thenReturn(mockEditor)
        whenever(mockEditor.putBoolean(anyString(), anyBoolean())).thenReturn(mockEditor)
        whenever(mockEditor.putString(anyString(), any())).thenReturn(mockEditor)
        whenever(mockEditor.remove(anyString())).thenReturn(mockEditor)
        // Empty-string default so the persistence branch doesn't
        // load a stale window list from a previous test.
        whenever(mockPrefs.getBoolean(anyString(), anyBoolean())).thenReturn(false)
        whenever(mockPrefs.getString(anyString(), any())).thenReturn("")

        scheduler = TrackingScheduler(mockContext)
    }

    // -------- getConfigMap default shape --------

    @Test
    fun `default getConfigMap returns a stable three-key shape with an empty time-window list`() {
        val map = scheduler.getConfigMap()

        assertEquals(
            "getConfigMap must expose the same three top-level keys the bridge accepts on write.",
            setOf("enabled", "startImmediatelyIfInWindow", "timeWindows"),
            map.keys
        )
        assertEquals(false, map["enabled"])
        assertEquals(true, map["startImmediatelyIfInWindow"])
        assertEquals(emptyList<Any>(), map["timeWindows"])
    }

    // -------- updateConfig → getConfigMap round-trip --------

    @Test
    fun `updateConfig with a full time-window round-trips through getConfigMap without shape drift`() {
        val input: Map<String, Any> = mapOf(
            "enabled" to true,
            "startImmediatelyIfInWindow" to false,
            "timeWindows" to listOf(
                mapOf(
                    "startTime" to mapOf("hour" to 9, "minute" to 0),
                    "endTime" to mapOf("hour" to 17, "minute" to 30),
                    "daysOfWeek" to listOf(1, 2, 3, 4, 5)
                )
            )
        )
        scheduler.updateConfig(input)

        val output = scheduler.getConfigMap()
        assertEquals(true, output["enabled"])
        assertEquals(false, output["startImmediatelyIfInWindow"])

        @Suppress("UNCHECKED_CAST")
        val windows = output["timeWindows"] as List<Map<String, Any>>
        assertEquals(1, windows.size)

        val window = windows[0]
        // TimeOfDay must survive as a nested map, not a flattened
        // startHour / startMinute pair — the TypeScript / Dart
        // types on the bridge side depend on the nested shape.
        @Suppress("UNCHECKED_CAST")
        val startTime = window["startTime"] as Map<String, Any>
        assertEquals(9, startTime["hour"])
        assertEquals(0, startTime["minute"])

        @Suppress("UNCHECKED_CAST")
        val endTime = window["endTime"] as Map<String, Any>
        assertEquals(17, endTime["hour"])
        assertEquals(30, endTime["minute"])

        assertEquals(listOf(1, 2, 3, 4, 5), window["daysOfWeek"])
    }

    @Test
    fun `updateConfig with null resets to the default shape (empty windows, disabled)`() {
        // Seed with a real window first so we can prove the reset
        // actually clears it — a common bridge path calls
        // updateConfig(null) as part of resetConfiguration().
        scheduler.updateConfig(
            mapOf(
                "enabled" to true,
                "startImmediatelyIfInWindow" to false,
                "timeWindows" to listOf(
                    mapOf(
                        "startTime" to mapOf("hour" to 8, "minute" to 15),
                        "endTime" to mapOf("hour" to 12, "minute" to 45),
                        "daysOfWeek" to listOf(6, 7)
                    )
                )
            )
        )
        assertEquals(true, scheduler.getConfigMap()["enabled"])

        scheduler.updateConfig(null)

        val map = scheduler.getConfigMap()
        assertEquals(false, map["enabled"])
        assertEquals(true, map["startImmediatelyIfInWindow"])
        assertEquals(emptyList<Any>(), map["timeWindows"])
    }

    @Test
    fun `updateConfig with multiple windows preserves them all in order`() {
        val input: Map<String, Any> = mapOf(
            "enabled" to true,
            "startImmediatelyIfInWindow" to true,
            "timeWindows" to listOf(
                mapOf(
                    "startTime" to mapOf("hour" to 6, "minute" to 0),
                    "endTime" to mapOf("hour" to 10, "minute" to 0),
                    "daysOfWeek" to listOf(1, 3, 5)
                ),
                mapOf(
                    "startTime" to mapOf("hour" to 18, "minute" to 0),
                    "endTime" to mapOf("hour" to 22, "minute" to 0),
                    "daysOfWeek" to listOf(2, 4)
                )
            )
        )
        scheduler.updateConfig(input)

        @Suppress("UNCHECKED_CAST")
        val windows = scheduler.getConfigMap()["timeWindows"] as List<Map<String, Any>>
        assertEquals(2, windows.size)

        @Suppress("UNCHECKED_CAST")
        val firstStart = windows[0]["startTime"] as Map<String, Any>
        assertEquals(6, firstStart["hour"])
        @Suppress("UNCHECKED_CAST")
        val secondEnd = windows[1]["endTime"] as Map<String, Any>
        assertEquals(22, secondEnd["hour"])
    }

    @Test
    fun `updateConfig omitting daysOfWeek round-trips as an empty list, not null`() {
        // The bridge contract is that `daysOfWeek: []` means
        // "every day of the week". An emitted null would be
        // ambiguous — TypeScript / Dart consumers can't distinguish
        // "unset" from "empty means all days". Stability guard.
        val input: Map<String, Any> = mapOf(
            "enabled" to true,
            "startImmediatelyIfInWindow" to true,
            "timeWindows" to listOf(
                mapOf(
                    "startTime" to mapOf("hour" to 0, "minute" to 0),
                    "endTime" to mapOf("hour" to 23, "minute" to 59)
                    // daysOfWeek omitted — TimeWindow.fromMap defaults to []
                )
            )
        )
        scheduler.updateConfig(input)

        @Suppress("UNCHECKED_CAST")
        val windows = scheduler.getConfigMap()["timeWindows"] as List<Map<String, Any>>
        assertEquals(emptyList<Int>(), windows[0]["daysOfWeek"])
    }
}

package io.polyfence.core.utils

import android.content.Context
import android.content.SharedPreferences
import android.util.Log

/**
 * Centralized configuration management for Polyfence
 * Single responsibility: Runtime configuration and persistence
 *
 * ## Every field here must be written by updateConfigurationFromMap
 *
 * This class is the only thing that survives process death. The OS can
 * relaunch a killed process — on a geofence crossing, on a significant
 * location change, at boot — and run library code before any bridge has had
 * the chance to re-apply configuration. Whatever is not persisted here reads
 * as its compile-time default in that window.
 *
 * A field that is applied to an in-memory property but not written back here
 * therefore appears to work in every test and in every foreground session, and
 * silently reverts in exactly the scenario the durable-queue and wake-fence
 * features exist for. Adding a config field means adding it in three places:
 * this class, the write path in `LocationTracker.updateConfigurationFromMap`,
 * and the read path in the tracker's setup. The iOS `PolyfenceConfig` carries
 * the same rule.
 */
class PolyfenceConfig(context: Context) {

    companion object {
        private const val TAG = "PolyfenceConfig"
        const val DEFAULT_TRACKING_NOTIFICATION_TITLE = "Polyfence Active"
        const val DEFAULT_TRACKING_NOTIFICATION_TEXT = "Monitoring geofence zones"

        // Crossing-alert text. `{zone}` is replaced with the zone's name, and
        // `{hours}` / `{minutes}` with the time spent inside it. The host app
        // writes each of these as a whole sentence in its own language, rather
        // than us assembling one from parts: word order and plural rules move
        // between languages, so a sentence built from a prefix and a unit can
        // only ever come out as English grammar wearing other words.
        const val DEFAULT_ALERT_TITLE_ENTER = "Entered {zone}"
        const val DEFAULT_ALERT_TITLE_DWELL = "Dwelling in {zone}"
        const val DEFAULT_ALERT_TITLE_EXIT = "Exited {zone}"
        const val DEFAULT_ALERT_DWELL_BODY_UNDER_MINUTE = "Here under a minute"
        const val DEFAULT_ALERT_DWELL_BODY_MINUTES = "Here {minutes} min"
        const val DEFAULT_ALERT_DWELL_BODY_HOURS = "Here {hours}h"
        const val DEFAULT_ALERT_DWELL_BODY_HOURS_MINUTES = "Here {hours}h {minutes} min"

        // Blank is not uniform across these fourteen, deliberately. The icon
        // name is a resource lookup, so an empty or whitespace-only value is
        // the same as having none and reads as unset, which is what lets a
        // reset clear it. The thirteen sentences are copy, so a blank one is
        // kept and used: an empty title gives a title-less notification, which
        // is a host's choice to make and not ours to second-guess.
        //
        // Notification-channel labels. Android has required channels since API
        // 26 and shows these in the phone's own Settings app, under the host
        // app's notification settings, where they label the switches that turn
        // each kind of notification off. Not a tray string, but still Polyfence
        // writing English into someone else's app.
        /**
         * ASCII whitespace, the characters an "effectively empty" value may be
         * made of. Spelled out rather than borrowed from a standard predicate
         * because iOS has to agree exactly, and the obvious choice on each side
         * does not: Kotlin's `isBlank` counts U+001C to U+001F and not U+0085,
         * while Foundation's `whitespacesAndNewlines` is the other way round, so
         * the same stored value read as unset on one platform and as a name on
         * the other. Anything outside this set is kept, including a no-break
         * space, because a drawable resource name cannot contain one anyway and
         * a visible resolver fallback beats silently discarding what a host set.
         */
        private const val ASCII_WHITESPACE = " \t\n\r\u000B\u000C"

        /** True when [value] is empty or made only of [ASCII_WHITESPACE]. */
        internal fun isEffectivelyEmpty(value: String): Boolean =
            value.all { it in ASCII_WHITESPACE }

        const val DEFAULT_TRACKING_CHANNEL_NAME = "Location Tracking"
        const val DEFAULT_TRACKING_CHANNEL_DESCRIPTION = "Background location tracking"
        const val DEFAULT_ALERT_CHANNEL_NAME = "Geofence Alerts"
        const val DEFAULT_ALERT_CHANNEL_DESCRIPTION = "Zone entry and exit notifications"
        private const val PREFS_NAME = "polyfence_config"

        // Default GPS Configuration
        const val DEFAULT_GPS_INTERVAL_MS = 5000L // 5 seconds - balanced
        const val DEFAULT_GPS_ACCURACY_THRESHOLD = 100.0f
        const val DEFAULT_MIN_UPDATE_INTERVAL_MS = 1000L
        const val DEFAULT_MAX_UPDATE_DELAY_MS = 6000L
        const val MIN_UPDATE_DISTANCE_METERS = 10f

        // Zone Validation Configuration
        const val DEFAULT_CONFIDENCE_POINTS = 2
        const val DEFAULT_CONFIDENCE_TIMEOUT_MS = 10000L
        const val DEFAULT_REQUIRE_CONFIRMATION = false
        const val LARGE_ZONE_RADIUS_THRESHOLD_METERS = 200.0
        const val MIN_SINGLE_POINT_ZONE_RADIUS_METERS = 50.0
        const val MIN_POLYGON_POINTS = 3

        // Speed and Movement Thresholds
        const val HIGH_SPEED_THRESHOLD_KMH = 40.0
        const val SPEED_MS_TO_KMH_MULTIPLIER = 3.6

        // GPS Health and Recovery
        const val MAX_GPS_FAILURES_BEFORE_COOLDOWN = 2
        const val MIN_GPS_FAILURES_FOR_RECOVERY = 3
        const val MAX_GPS_FAILURES_FOR_RECOVERY = 5
        const val GPS_HEALTH_CHECK_TIMEOUT_MS = 120000L // 2 minutes
        const val HEALTH_CHECK_INTERVAL_MS = 30000L // 30 seconds
        const val GPS_RESTART_DELAY_MS = 3000L // 3 seconds
        const val SERVICE_RESTART_DELAY_MS = 5000L // 5 seconds

        // GPS Restart Configuration
        const val MIN_GPS_RESTART_INTERVAL_MS = 10000L // 10 seconds
        const val MIN_UPDATE_RESTART_INTERVAL_MS = 5000L // 5 seconds
        const val MAX_UPDATE_RESTART_DELAY_MS = 15000L // 15 seconds

        // System Defaults
        const val DEFAULT_BATTERY_LEVEL = 100.0
        const val DEVICE_ID_RANDOM_RANGE = 10000
        const val FOREGROUND_NOTIFICATION_ID = 1001
        const val APP_VERSION = "1.0.0"

        // Validation Ranges
        const val MIN_GPS_INTERVAL_MS = 1000L
        const val MAX_GPS_INTERVAL_MS = 60000L
        const val MIN_ACCURACY_THRESHOLD = 1.0f
        const val MAX_ACCURACY_THRESHOLD = 500.0f
        const val MIN_CONFIDENCE_POINTS = 1
        const val MAX_CONFIDENCE_POINTS = 5

        // Calculation Factors
        const val MIN_UPDATE_INTERVAL_FACTOR = 2L // minInterval = gpsInterval / 2
        const val MAX_UPDATE_DELAY_FACTOR = 2L // maxDelay = gpsInterval * 2

        // Cache Configuration
        const val DEFAULT_LRU_INITIAL_CAPACITY = 16
        const val DEFAULT_LRU_LOAD_FACTOR = 0.75f

        // OS wake-fence slot allocation. Google Play Services caps geofences at
        // 100 per app; the default reserves half for the consumer's own
        // registrations because there is no way to discover how many they hold.
        const val DEFAULT_OS_GEOFENCE_MAX_REGIONS = 50
        const val DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS = 100

        /**
         * Constrains a slot budget to what the platform will honour. Play
         * Services rejects an over-large `addGeofences` request wholesale, so
         * passing a raw value through would register nothing rather than
         * register more. Kept identical in shape to the iOS clamp so the same
         * consumer value produces the same effective budget on both platforms.
         */
        fun clampOsGeofenceMaxRegions(requested: Int): Int =
            requested.coerceIn(1, DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS)
    }

    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // GPS Configuration
    var gpsIntervalMs: Long
        get() = prefs.getLong("gps_interval_ms", DEFAULT_GPS_INTERVAL_MS)
        set(value) {
            prefs.edit().putLong("gps_interval_ms", value).apply()
        }

    var gpsAccuracyThreshold: Float
        get() = prefs.getFloat("gps_accuracy_threshold", DEFAULT_GPS_ACCURACY_THRESHOLD)
        set(value) {
            prefs.edit().putFloat("gps_accuracy_threshold", value).apply()
        }

    // Degraded-GPS handling. 0 = off (default). When > 0, a low-accuracy fix may
    // drive EXITs (Option D) and, after this many ms with no valid fix while
    // inside a zone, the staleness watchdog emits SIGNAL_LOST. One knob gates
    // both behaviours.
    var gpsStalenessTimeoutMs: Long
        get() = prefs.getLong("gps_staleness_timeout_ms", 0L)
        set(value) {
            prefs.edit().putLong("gps_staleness_timeout_ms", value).apply()
        }

    // Durable pending-events queue cap. 0 = off (default). When > 0, geofence
    // events fired while the bridge sink is not receiving are persisted to disk
    // in a bounded ring buffer; oldest events evict on overflow. Drained by the
    // consumer via LocationTracker.drainPendingEvents.
    var pendingEventsQueueSize: Int
        get() = prefs.getInt("pending_events_queue_size", 0)
        set(value) {
            prefs.edit().putInt("pending_events_queue_size", value).apply()
        }

    // Text of the ongoing foreground-service notification Android requires while
    // background location tracking runs. It names the app doing the tracking to
    // that app's own users, so the host app has to be able to say who it is. The
    // defaults describe Polyfence because an integrator who sets nothing is
    // running Polyfence; any integrator shipping to their own users will set
    // them.
    var trackingNotificationTitle: String
        get() = prefs.getString("tracking_notification_title", null)
            ?: DEFAULT_TRACKING_NOTIFICATION_TITLE
        set(value) {
            prefs.edit().putString("tracking_notification_title", value).apply()
        }

    var trackingNotificationText: String
        get() = prefs.getString("tracking_notification_text", null)
            ?: DEFAULT_TRACKING_NOTIFICATION_TEXT
        set(value) {
            prefs.edit().putString("tracking_notification_text", value).apply()
        }

    // Drawable resource NAME for the same notification's small icon, for example
    // "ic_tracking". Null means unset, and the tracker falls back to the platform
    // location glyph, so a host app that does not set this shows a generic Android
    // pin in its own notification tray.
    //
    // A name rather than an R.drawable id on purpose. Resource ids are assigned at
    // compile time and move when the host app's resources change, so a persisted
    // id silently stops matching after their next release. It would then reach
    // setSmallIcon and from there startForeground, which Android kills the service
    // for if it does not land. A name survives a rebuild and is resolved at call
    // time instead.
    //
    // Android renders a notification's small icon from its alpha channel alone,
    // so a full-colour drawable arrives as a white square. The name should point
    // at a monochrome, transparent-background asset.
    //
    // Empty reads as unset, which is how a reset clears it. The configuration map
    // carries values, not absences: a map that omits this key means "leave what is
    // stored alone", which is what a partial update needs, so the reset payload
    // has to be able to say "no icon" with a value. An empty string is that value,
    // and it cannot collide with a real drawable, since no resource can be named
    // "". iOS applies the same rule so a reset clears the icon on both platforms.
    var trackingNotificationIconName: String?
        get() = prefs.getString("tracking_notification_icon_name", null)
            ?.takeIf { !isEffectivelyEmpty(it) }
        set(value) {
            prefs.edit().putString("tracking_notification_icon_name", value).apply()
        }

    // Title of the notification shown when someone crosses a zone boundary.
    // Unset reads as the English default, so a host app that configures nothing
    // sees exactly today's text. ENTER and RECOVERY_ENTER share the enter title,
    // EXIT and RECOVERY_EXIT the exit one, which is the behaviour these replace.
    var alertTitleEnter: String
        get() = prefs.getString("alert_title_enter", null) ?: DEFAULT_ALERT_TITLE_ENTER
        set(value) {
            prefs.edit().putString("alert_title_enter", value).apply()
        }

    var alertTitleDwell: String
        get() = prefs.getString("alert_title_dwell", null) ?: DEFAULT_ALERT_TITLE_DWELL
        set(value) {
            prefs.edit().putString("alert_title_dwell", value).apply()
        }

    var alertTitleExit: String
        get() = prefs.getString("alert_title_exit", null) ?: DEFAULT_ALERT_TITLE_EXIT
        set(value) {
            prefs.edit().putString("alert_title_exit", value).apply()
        }

    // Body of the dwell notification. Four separate sentences rather than one
    // template plus unit strings, because which one applies depends on the
    // duration and each reads differently in a given language.
    var alertDwellBodyUnderMinute: String
        get() = prefs.getString("alert_dwell_body_under_minute", null) ?: DEFAULT_ALERT_DWELL_BODY_UNDER_MINUTE
        set(value) {
            prefs.edit().putString("alert_dwell_body_under_minute", value).apply()
        }

    var alertDwellBodyMinutes: String
        get() = prefs.getString("alert_dwell_body_minutes", null) ?: DEFAULT_ALERT_DWELL_BODY_MINUTES
        set(value) {
            prefs.edit().putString("alert_dwell_body_minutes", value).apply()
        }

    var alertDwellBodyHours: String
        get() = prefs.getString("alert_dwell_body_hours", null) ?: DEFAULT_ALERT_DWELL_BODY_HOURS
        set(value) {
            prefs.edit().putString("alert_dwell_body_hours", value).apply()
        }

    var alertDwellBodyHoursMinutes: String
        get() = prefs.getString("alert_dwell_body_hours_minutes", null) ?: DEFAULT_ALERT_DWELL_BODY_HOURS_MINUTES
        set(value) {
            prefs.edit().putString("alert_dwell_body_hours_minutes", value).apply()
        }

    // Labels for the two notification channels, shown in the phone's Settings
    // app rather than the tray. Changing one takes effect by re-creating the
    // channel under the same id, which Android treats as an update of its name
    // and description; it declines to override importance or sound once the user
    // has adjusted those themselves, which is the behaviour a host wants anyway.
    var trackingChannelName: String
        get() = prefs.getString("tracking_channel_name", null) ?: DEFAULT_TRACKING_CHANNEL_NAME
        set(value) {
            prefs.edit().putString("tracking_channel_name", value).apply()
        }

    var trackingChannelDescription: String
        get() = prefs.getString("tracking_channel_description", null) ?: DEFAULT_TRACKING_CHANNEL_DESCRIPTION
        set(value) {
            prefs.edit().putString("tracking_channel_description", value).apply()
        }

    var alertChannelName: String
        get() = prefs.getString("alert_channel_name", null) ?: DEFAULT_ALERT_CHANNEL_NAME
        set(value) {
            prefs.edit().putString("alert_channel_name", value).apply()
        }

    var alertChannelDescription: String
        get() = prefs.getString("alert_channel_description", null) ?: DEFAULT_ALERT_CHANNEL_DESCRIPTION
        set(value) {
            prefs.edit().putString("alert_channel_description", value).apply()
        }

    // Automatic delivery of queued events. true = on (default) — the moment a
    // consumer signals a live event listener, the queue is drained and replayed
    // through the normal event callback. false leaves the queue pull-only, so
    // nothing is delivered until the consumer calls
    // LocationTracker.drainPendingEvents itself. Only has an effect while
    // pendingEventsQueueSize > 0.
    var pendingEventsAutoDrainEnabled: Boolean
        get() = prefs.getBoolean("pending_events_auto_drain_enabled", true)
        set(value) {
            prefs.edit().putBoolean("pending_events_auto_drain_enabled", value).apply()
        }

    // OS wake-fence registration. false = off (default) — Polyfence's own polling
    // engine is the sole detector; nothing is registered with the OS. When true,
    // the top-N-nearest active zones are registered with GeofencingClient so an
    // OS-side broadcast can wake the app after full process kill and enqueue the
    // crossing into the pending-events queue for drain-on-next-boot. Requires
    // ACCESS_BACKGROUND_LOCATION granted by the consumer app.
    var osGeofenceWakeEnabled: Boolean
        get() = prefs.getBoolean("os_geofence_wake_enabled", false)
        set(value) {
            prefs.edit().putBoolean("os_geofence_wake_enabled", value).apply()
        }

    // How many OS geofence slots Polyfence may occupy while the app is
    // backgrounded. Google Play Services allows 100 geofences per APP, not per
    // library, and exposes no API to query how many are already spoken for —
    // so a consumer that registers its own geofences has to tell us how much
    // room to leave. The default leaves half the allocation free; a consumer
    // with no geofences of its own can raise this to
    // DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS for full coverage. Values above
    // the platform maximum are clamped.
    // Clamped on write so the persisted value is always the value that will
    // actually be applied. Storing the raw request instead would make
    // getConfiguration() echo a budget the registrar never uses, and would
    // leave consumers with no way to discover the effective one.
    var osGeofenceMaxRegions: Int
        get() = prefs.getInt("os_geofence_max_regions", DEFAULT_OS_GEOFENCE_MAX_REGIONS)
        set(value) {
            prefs.edit()
                .putInt("os_geofence_max_regions", clampOsGeofenceMaxRegions(value))
                .apply()
        }

    var minUpdateIntervalMs: Long
        get() = prefs.getLong("min_update_interval_ms", DEFAULT_MIN_UPDATE_INTERVAL_MS)
        set(value) {
            prefs.edit().putLong("min_update_interval_ms", value).apply()
        }

    var maxUpdateDelayMs: Long
        get() = prefs.getLong("max_update_delay_ms", DEFAULT_MAX_UPDATE_DELAY_MS)
        set(value) {
            prefs.edit().putLong("max_update_delay_ms", value).apply()
        }

    // Validation Configuration
    var requireConfirmation: Boolean
        get() = prefs.getBoolean("require_confirmation", DEFAULT_REQUIRE_CONFIRMATION)
        set(value) {
            prefs.edit().putBoolean("require_confirmation", value).apply()
        }

    var confidencePoints: Int
        get() = prefs.getInt("confidence_points", DEFAULT_CONFIDENCE_POINTS)
        set(value) {
            prefs.edit().putInt("confidence_points", value).apply()
        }

    var confidenceTimeoutMs: Long
        get() = prefs.getLong("confidence_timeout_ms", DEFAULT_CONFIDENCE_TIMEOUT_MS)
        set(value) {
            prefs.edit().putLong("confidence_timeout_ms", value).apply()
        }

    /**
     * Reset all configuration to defaults
     */
    fun resetToDefaults() {
        prefs.edit().clear().apply()
    }

    /**
     * Get current configuration as a map for debugging
     */
    fun getConfigurationMap(): Map<String, Any> {
        return mapOf(
            "gps_interval_ms" to gpsIntervalMs,
            "gps_accuracy_threshold" to gpsAccuracyThreshold,
            "min_update_interval_ms" to minUpdateIntervalMs,
            "max_update_delay_ms" to maxUpdateDelayMs,
            "require_confirmation" to requireConfirmation,
            "confidence_points" to confidencePoints,
            "confidence_timeout_ms" to confidenceTimeoutMs,
            "gps_staleness_timeout_ms" to gpsStalenessTimeoutMs
        )
    }

    /**
     * Update configuration from a map
     */
    fun updateFromMap(configMap: Map<String, Any>) {
        try {
            configMap["gps_interval_ms"]?.let {
                if (it is Number) gpsIntervalMs = it.toLong()
            }
            configMap["gps_accuracy_threshold"]?.let {
                if (it is Number) gpsAccuracyThreshold = it.toFloat()
            }
            configMap["gps_staleness_timeout_ms"]?.let {
                if (it is Number) gpsStalenessTimeoutMs = it.toLong()
            }
            configMap["min_update_interval_ms"]?.let {
                if (it is Number) minUpdateIntervalMs = it.toLong()
            }
            configMap["max_update_delay_ms"]?.let {
                if (it is Number) maxUpdateDelayMs = it.toLong()
            }
            configMap["require_confirmation"]?.let {
                if (it is Boolean) requireConfirmation = it
            }
            configMap["confidence_points"]?.let {
                if (it is Number) confidencePoints = it.toInt()
            }
            configMap["confidence_timeout_ms"]?.let {
                if (it is Number) confidenceTimeoutMs = it.toLong()
            }

        } catch (e: Exception) {
            Log.e(TAG, "Failed to update configuration: ${e.message}")
        }
    }

    /**
     * Validate configuration values
     */
    fun validateAndCorrect(): Boolean {
        var corrected = false

        // Ensure GPS interval is reasonable
        if (gpsIntervalMs < MIN_GPS_INTERVAL_MS || gpsIntervalMs > MAX_GPS_INTERVAL_MS) {
            gpsIntervalMs = DEFAULT_GPS_INTERVAL_MS
            corrected = true
        }

        // Ensure accuracy threshold is reasonable
        if (gpsAccuracyThreshold < MIN_ACCURACY_THRESHOLD || gpsAccuracyThreshold > MAX_ACCURACY_THRESHOLD) {
            gpsAccuracyThreshold = DEFAULT_GPS_ACCURACY_THRESHOLD
            corrected = true
        }

        // Ensure confidence points is reasonable
        if (confidencePoints < MIN_CONFIDENCE_POINTS || confidencePoints > MAX_CONFIDENCE_POINTS) {
            confidencePoints = DEFAULT_CONFIDENCE_POINTS
            corrected = true
        }

        // Ensure min interval is less than main interval
        if (minUpdateIntervalMs >= gpsIntervalMs) {
            minUpdateIntervalMs = gpsIntervalMs / MIN_UPDATE_INTERVAL_FACTOR
            corrected = true
        }

        // Ensure max delay is greater than main interval
        if (maxUpdateDelayMs <= gpsIntervalMs) {
            maxUpdateDelayMs = gpsIntervalMs * MAX_UPDATE_DELAY_FACTOR
            corrected = true
        }

        if (corrected) {
            Log.w(TAG, "Configuration values corrected")
        }

        return !corrected
    }

    /**
     * Log current configuration for debugging
     */
    fun logCurrentConfig() {
    }
}

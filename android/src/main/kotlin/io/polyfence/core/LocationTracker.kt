package io.polyfence.core

import android.annotation.SuppressLint
import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.*
import io.polyfence.core.utils.GeoMath
import io.polyfence.core.utils.PolyfenceConfig
import io.polyfence.core.utils.PolyfenceErrorRecovery
import io.polyfence.core.configuration.SmartGpsConfig
import io.polyfence.core.configuration.SmartGpsConfigFactory
import io.polyfence.core.configuration.DeviceOptimization
import io.polyfence.core.configuration.ActivitySettings
import io.polyfence.core.configuration.ActivityType
import io.polyfence.core.GeofenceEngine.LatLng
import io.polyfence.core.GeofenceEngine.ZoneType
import java.util.Collections
import java.util.HashMap
import kotlin.math.*

/**
 * Simple GPS tracking service
 * Single responsibility: GPS updates → GeofenceEngine → Notifications
 */
class LocationTracker : Service() {

    companion object {
        private const val TAG = "LocationTracker"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "polyfence_tracking"
        private const val GEOFENCE_CHANNEL_ID = "polyfence_alerts"

        const val ACTION_START_TRACKING = "START_TRACKING"
        const val ACTION_STOP_TRACKING = "STOP_TRACKING"
        const val ACTION_ADD_ZONE = "ADD_ZONE"
        const val ACTION_REMOVE_ZONE = "REMOVE_ZONE"
        const val ACTION_CLEAR_ZONES = "CLEAR_ZONES"
        const val ACTION_UPDATE_CONFIG = "UPDATE_CONFIG"

        var isRunning = false
            private set

        // Smart GPS Configuration
        private var currentSmartConfig: SmartGpsConfig = SmartGpsConfig()

        // Alert Notifications Control
        private var alertNotificationsEnabled = true

        // Tracking Scheduler for time-based tracking
        private var trackingScheduler: TrackingScheduler? = null

        // Current instance reference for accessing zone states
        private var currentInstance: LocationTracker? = null

        // Pending activity settings (stored until tracking starts)
        private var pendingActivitySettings: ActivitySettings? = null

        // Pending bridge platform (stored until service creates TelemetryAggregator)
        private var pendingBridgePlatform: String? = null

        // Pending core delegate (stored until service starts)
        private var pendingCoreDelegate: PolyfenceCoreDelegate? = null

        /**
         * Store activity settings to be applied when tracking starts
         */
        fun setPendingActivitySettings(settings: ActivitySettings) {
            pendingActivitySettings = settings
            Log.d(TAG, "Stored pending activity settings: enabled=${settings.enabled}")
            // If service is already running, apply immediately
            currentInstance?.updateActivityRecognition(settings)
        }

        /**
         * Get current zone states from the active service instance
         * Returns which zones the plugin believes the device is currently inside
         * @return Map of zoneId to isInside state, or empty map if service not running
         */
        fun getCurrentZoneStates(): Map<String, Boolean> {
            return currentInstance?.geofenceEngine?.getCurrentZoneStates() ?: emptyMap()
        }

        /**
         * Get current smart GPS configuration
         */
        fun getCurrentSmartConfiguration(): SmartGpsConfig {
            return currentSmartConfig
        }

        /**
         * Full 12-key configuration snapshot for the bridge
         * `getConfiguration()` surface. Composes state from the four
         * places it actually lives:
         *   1. [currentSmartConfig] — top-level scalars +
         *      proximity / movement / battery blocks.
         *   2. Running [currentInstance]'s geofenceEngine — GPS
         *      accuracy threshold, dwell settings, cluster settings
         *      (fall back to engine defaults when the service isn't
         *      running).
         *   3. [TrackingScheduler.getInstance] singleton — schedule
         *      settings (always available since the singleton persists
         *      across service lifecycle).
         *   4. Running instance's activitySettings, or
         *      [pendingActivitySettings], or default when neither is
         *      set — same three-tier fallback the service already uses
         *      internally on first-run.
         *
         * The shape matches the JS `PolyfenceConfiguration` type and
         * round-trips cleanly through `updateConfiguration` — all eleven
         * top-level keys are emitted (never `null`) so bridges can cache
         * and re-apply the full configuration surface.
         *
         * ## Contract for bridge authors
         * **Pass `context` whenever possible.** When the service isn't
         * running and `context` is non-null, this method lazily
         * instantiates the companion [trackingScheduler] and rehydrates
         * its persisted config from SharedPreferences — a read that
         * mutates process-wide state. This is intentional (returns the
         * user's last-applied schedule rather than an empty-defaults
         * placeholder), but it means concurrent callers should provide
         * the same context. Passing `null` context ALWAYS returns an
         * empty schedule fallback even when a persisted config exists
         * on disk — asymmetric behaviour worth avoiding.
         */
        fun getCurrentConfigurationMap(context: android.content.Context?): Map<String, Any> {
            val base = SmartGpsConfigFactory.toMap(currentSmartConfig).toMutableMap()

            val instance = currentInstance
            val engine = instance?.geofenceEngine
            if (engine != null) {
                // Widen Float → Double at the map boundary so the
                // React Native / Flutter bridges receive the same
                // numeric type Swift emits (which is Double). Float
                // precision is enough for accuracy metres, but a
                // cross-platform `.toBe(100)` assertion would
                // otherwise diverge between Android (100.0f
                // marshalled as Double 100.0 by React Native, but as
                // literal Float across Flutter's MethodChannel) and
                // iOS (already Double 100.0).
                base["gpsAccuracyThreshold"] = engine.getGpsAccuracyThreshold().toDouble()
                base["dwellSettings"] = engine.getDwellConfigMap()
                base["clusterSettings"] = engine.getClusterConfigMap()
            } else {
                // Service not running — return the engine's compile-time
                // defaults so the caller sees a stable shape rather than
                // missing keys. Any user-set value that never reached the
                // engine (because the service was killed before it
                // landed) is invisible here; that matches how the write
                // path also drops those updates.
                base["gpsAccuracyThreshold"] = GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD.toDouble()
                base["dwellSettings"] = mapOf(
                    "enabled" to true,
                    "dwellThresholdMs" to GeofenceEngine.DEFAULT_DWELL_THRESHOLD_MS
                )
                base["clusterSettings"] = mapOf(
                    "enabled" to false,
                    "activeRadiusMeters" to GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS,
                    "refreshDistanceMeters" to GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS
                )
            }

            // TrackingScheduler is a companion field lazily initialised
            // on first setScheduleConfig / onStartCommand. Instantiate
            // against the caller's context when a schedule config was
            // never pushed (so we return the on-disk snapshot the
            // scheduler recovers, not a bare in-memory default) and
            // fall back to an empty shape only when no context is
            // available at all. Synchronised on the companion so a
            // concurrent [setScheduleConfig] can't race and orphan
            // one caller's newly-instantiated scheduler behind
            // another's — both call sites contend for the same lock.
            val schedulerSnapshot = synchronized(this) {
                trackingScheduler?.let { it }
                    ?: context?.let { ctx ->
                        val recovered = TrackingScheduler(ctx)
                        recovered.loadConfig()
                        trackingScheduler = recovered
                        recovered
                    }
            }
            base["scheduleSettings"] = schedulerSnapshot?.getConfigMap()
                ?: mapOf(
                    "enabled" to false,
                    "startImmediatelyIfInWindow" to true,
                    "timeWindows" to emptyList<Any>()
                )

            val effectiveActivitySettings =
                instance?.activitySettings
                    ?: pendingActivitySettings
                    ?: ActivitySettings()
            // ActivitySettings stores per-activity interval overrides
            // as nullable so `getIntervalForActivity` can lazily fall
            // back to the compile-time default. Emitting those nulls
            // straight through would leave the composed map with a
            // sparse `activitySettings` block whose interval keys
            // silently drop — a shape-stability regression the
            // docstring above claims we avoid. Materialise the
            // effective values (user override OR DEFAULT_* constant)
            // so `getConfiguration()` always returns the full 8-key
            // block and consumers can round-trip via
            // `updateConfiguration(cfg.activitySettings)` without
            // losing the interval defaults.
            val activityMap: Map<String, Any> = mapOf(
                "enabled" to effectiveActivitySettings.enabled,
                "confidenceThreshold" to effectiveActivitySettings.confidenceThreshold,
                "debounceSeconds" to effectiveActivitySettings.debounceSeconds,
                "stillIntervalMs" to (effectiveActivitySettings.stillIntervalMs
                    ?: ActivitySettings.DEFAULT_STILL_INTERVAL_MS),
                "walkingIntervalMs" to (effectiveActivitySettings.walkingIntervalMs
                    ?: ActivitySettings.DEFAULT_WALKING_INTERVAL_MS),
                "runningIntervalMs" to (effectiveActivitySettings.runningIntervalMs
                    ?: ActivitySettings.DEFAULT_RUNNING_INTERVAL_MS),
                "cyclingIntervalMs" to (effectiveActivitySettings.cyclingIntervalMs
                    ?: ActivitySettings.DEFAULT_CYCLING_INTERVAL_MS),
                "drivingIntervalMs" to (effectiveActivitySettings.drivingIntervalMs
                    ?: ActivitySettings.DEFAULT_DRIVING_INTERVAL_MS)
            )
            base["activitySettings"] = activityMap

            // Alert-notifications flag also lives outside SmartGpsConfig
            // (companion static, applied on both bridge init and via
            // setAlertNotificationsEnabled). Emit it as
            // `disableAlertNotifications` — the shape the bridges'
            // TypeScript / Dart configuration types expose — so a
            // round-trip `getConfiguration()` → cache → user code doesn't
            // silently reset the caller's original init preference.
            base["disableAlertNotifications"] = !alertNotificationsEnabled

            return base
        }

        /**
         * Most recent GPS accuracy in metres from the running tracker
         * instance, or `null` if no fix has landed yet (or the tracker
         * isn't running). Exposed so bridge `status`-event payloads can
         * include the latest known accuracy instead of hardcoding
         * `null` — paired with the runtime_status emission which uses
         * the same value to stabilise the field across emissions.
         */
        fun getLastKnownAccuracy(): Float? {
            return currentInstance?.currentGpsAccuracy
        }

        /**
         * Update smart GPS configuration.
         * Stores the config and delegates to the running instance if available.
         */
        fun updateSmartConfiguration(config: SmartGpsConfig) {
            currentSmartConfig = config
            currentInstance?.updateSmartConfiguration(config)
        }

        /**
         * Set whether alert notifications should be shown
         */
        fun setAlertNotificationsEnabled(enabled: Boolean) {
            alertNotificationsEnabled = enabled
            Log.d(TAG, "Alert notifications ${if (enabled) "enabled" else "disabled"}")
        }

        /**
         * Build the same 12-key configuration map that
         * [getCurrentConfigurationMap] emits, but populated entirely
         * with the SDK's compile-time defaults. Bridges use this as
         * the payload for `resetConfiguration()` so the reset walks
         * through the merge-aware `updateConfigurationFromMap` path
         * and every subsystem (SmartGpsConfig + engine dwell / cluster
         * / gpsAccuracyThreshold + scheduler + activity + alert flag)
         * lands back at its default value in one shot. Sending only
         * the 6-key SmartGpsConfig map on reset would leave dwell,
         * cluster, schedule, and activity settings untouched.
         */
        fun buildDefaultConfigurationMap(): Map<String, Any> {
            val defaultConfig = SmartGpsConfig()
            val base = SmartGpsConfigFactory.toMap(defaultConfig).toMutableMap()
            base["gpsAccuracyThreshold"] = GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD.toDouble()
            base["dwellSettings"] = mapOf(
                "enabled" to true,
                "dwellThresholdMs" to GeofenceEngine.DEFAULT_DWELL_THRESHOLD_MS
            )
            base["clusterSettings"] = mapOf(
                "enabled" to false,
                "activeRadiusMeters" to GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS,
                "refreshDistanceMeters" to GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS
            )
            base["scheduleSettings"] = mapOf(
                "enabled" to false,
                "startImmediatelyIfInWindow" to true,
                "timeWindows" to emptyList<Any>()
            )
            val defaults = ActivitySettings()
            base["activitySettings"] = mapOf(
                "enabled" to defaults.enabled,
                "confidenceThreshold" to defaults.confidenceThreshold,
                "debounceSeconds" to defaults.debounceSeconds,
                "stillIntervalMs" to ActivitySettings.DEFAULT_STILL_INTERVAL_MS,
                "walkingIntervalMs" to ActivitySettings.DEFAULT_WALKING_INTERVAL_MS,
                "runningIntervalMs" to ActivitySettings.DEFAULT_RUNNING_INTERVAL_MS,
                "cyclingIntervalMs" to ActivitySettings.DEFAULT_CYCLING_INTERVAL_MS,
                "drivingIntervalMs" to ActivitySettings.DEFAULT_DRIVING_INTERVAL_MS
            )
            base["disableAlertNotifications"] = false
            return base
        }

        /**
         * Apply a partial configuration map directly on the running
         * Service instance. Returns after the apply completes, so an
         * immediately-following [getCurrentConfigurationMap] observes
         * the new state — the difference from routing through
         * [ACTION_UPDATE_CONFIG], which is fire-and-forget and can
         * race against a read on the same thread.
         *
         * When no Service instance is running, falls back to sending
         * the [ACTION_UPDATE_CONFIG] Intent so [context] can boot the
         * Service — preserving the start-if-needed contract callers
         * relied on before this helper existed. In that path apply is
         * still asynchronous; callers that need read-after-write to be
         * observable must ensure the Service is running first.
         */
        fun applyConfigurationDirect(context: Context, configMap: Map<String, Any>) {
            val instance = currentInstance
            if (instance != null) {
                instance.updateConfigurationFromMap(configMap)
                return
            }
            val intent = Intent(context, LocationTracker::class.java).apply {
                action = ACTION_UPDATE_CONFIG
                putExtra("config", HashMap(configMap))
            }
            context.startService(intent)
        }

        /**
         * Add a zone directly on the running Service instance. Returns
         * after the engine and persistence are both updated, so an
         * immediately-following [getCurrentZoneStates] or bridge
         * `getZoneStates()` observes the addition. Falls back to
         * [ACTION_ADD_ZONE] Intent dispatch when no Service is running —
         * preserving the boot-service-then-process contract callers
         * relied on before this helper existed. Read-after-write is only
         * guaranteed on the direct path.
         */
        fun applyAddZoneDirect(
            context: Context,
            zoneId: String,
            zoneName: String,
            zoneData: Map<String, Any>
        ) {
            val instance = currentInstance
            if (instance != null) {
                instance.addZoneById(zoneId, zoneName, zoneData)
                return
            }
            val intent = Intent(context, LocationTracker::class.java).apply {
                action = ACTION_ADD_ZONE
                putExtra("zoneId", zoneId)
                putExtra("zoneName", zoneName)
                putExtra("zoneData", HashMap(zoneData))
            }
            context.startService(intent)
        }

        /**
         * Remove a zone directly on the running Service instance.
         * Returns after the engine's zoneStates map and persistence are
         * both updated, so an immediately-following [getCurrentZoneStates]
         * or bridge `getZoneStates()` no longer sees the zone. Falls back
         * to [ACTION_REMOVE_ZONE] Intent dispatch when no Service is
         * running. Read-after-write is only guaranteed on the direct path.
         */
        fun applyRemoveZoneDirect(context: Context, zoneId: String) {
            val instance = currentInstance
            if (instance != null) {
                instance.removeZoneById(zoneId)
                return
            }
            val intent = Intent(context, LocationTracker::class.java).apply {
                action = ACTION_REMOVE_ZONE
                putExtra("zoneId", zoneId)
            }
            context.startService(intent)
        }

        /**
         * Clear every zone directly on the running Service instance.
         * Returns after the engine and persistence are both wiped, so an
         * immediately-following [getCurrentZoneStates] returns empty.
         * Falls back to [ACTION_CLEAR_ZONES] Intent dispatch when no
         * Service is running. Read-after-write is only guaranteed on the
         * direct path.
         */
        fun applyClearZonesDirect(context: Context) {
            val instance = currentInstance
            if (instance != null) {
                instance.clearZones()
                return
            }
            val intent = Intent(context, LocationTracker::class.java).apply {
                action = ACTION_CLEAR_ZONES
            }
            context.startService(intent)
        }

        /**
         * Update schedule configuration for time-based tracking.
         *
         * Synchronised on the companion so a concurrent
         * [getCurrentConfigurationMap] read can't race with this
         * lazy-init and orphan the reader's scheduler behind ours
         * (or vice-versa). Both call sites contend for the same
         * monitor.
         */
        fun setScheduleConfig(context: Context, scheduleSettings: Map<String, Any>?) {
            val scheduler = synchronized(this) {
                trackingScheduler ?: TrackingScheduler(context).also {
                    trackingScheduler = it
                }
            }
            scheduler.updateConfig(scheduleSettings)
            Log.d(TAG, "Schedule config updated")
        }

        /**
         * Check if currently within a scheduled tracking window
         */
        fun isInScheduledWindow(): Boolean {
            return trackingScheduler?.isCurrentlyInScheduledWindow() ?: true
        }

        /**
         * Set which bridge platform is calling core (e.g. "flutter", "react-native").
         * Stored as pending if service not yet created; applied in onCreate.
         */
        fun setBridgePlatform(platform: String) {
            pendingBridgePlatform = platform
            currentInstance?.telemetryAggregator?.setBridgePlatform(platform)
        }

        /**
         * Set the core delegate for receiving events from the engine.
         * If the service is already running, applies immediately.
         * Otherwise stored as pending and applied in onCreate.
         */
        fun setPendingCoreDelegate(delegate: PolyfenceCoreDelegate?) {
            pendingCoreDelegate = delegate
            currentInstance?.setCoreDelegate(delegate)
        }

        /**
         * Collect session telemetry from all native components.
         */
        fun getSessionTelemetry(): Map<String, Any?> {
            val instance = currentInstance ?: return emptyMap()

            // Set device/config info before collecting
            instance.telemetryAggregator.setDeviceInfo(
                category = TelemetryAggregator.getDeviceCategory(),
                osVersion = android.os.Build.VERSION.SDK_INT
            )
            instance.telemetryAggregator.setConfig(
                accuracyProfile = instance.smartConfig.accuracyProfile.name.lowercase(),
                updateStrategy = instance.smartConfig.updateStrategy.name.lowercase()
            )

            // Battery start was captured in onCreate. Pair with a fresh end
            // read here and the OR of start/end charging state so the SaaS
            // can compute battery_drain_avg_pct_per_hr and tag whether the
            // measurement was muddied by charging at either end.
            val endLevel = instance.getBatteryLevel().toDouble()
            val chargingDuring = instance.chargingAtStart || instance.isCurrentlyCharging()
            instance.telemetryAggregator.setBatteryInfo(
                startPercent = instance.batterySnapshotAtStart,
                endPercent = endLevel,
                chargingDuring = chargingDuring
            )

            // Return complete v2 enhanced payload from centralized aggregator
            return instance.telemetryAggregator.getSessionTelemetry(
                geofenceEngine = instance.geofenceEngine
            )
        }

        /**
         * Check if scheduling is enabled
         */
        fun isScheduleEnabled(): Boolean {
            return trackingScheduler?.isEnabled() ?: false
        }
    }

    private var fusedLocationClient: FusedLocationProviderClient? = null
    private var locationCallback: LocationCallback? = null
    private val geofenceEngine = GeofenceEngine()
    private lateinit var zonePersistence: ZonePersistence
    private lateinit var config: PolyfenceConfig

    // Centralized telemetry aggregator
    internal val telemetryAggregator = TelemetryAggregator()

    // Core delegate for platform bridge communication
    private var coreDelegate: PolyfenceCoreDelegate? = null

    /**
     * Set the core delegate for receiving events from the engine.
     * Platform bridges (Flutter, React Native, etc.) implement PolyfenceCoreDelegate.
     */
    fun setCoreDelegate(delegate: PolyfenceCoreDelegate?) {
        coreDelegate = delegate
    }

    // Error Recovery Properties
    private lateinit var errorRecovery: PolyfenceErrorRecovery
    private var healthCheckHandler: android.os.Handler? = null
    private var pendingSmartConfigReapplyRunnable: Runnable? = null
    private var lastLocationTime: Long = 0L
    private var consecutiveGpsFailures: Int = 0

    // Battery snapshot for telemetry drain calculation.
    // Captured at every session-start: onCreate() (first session) and every
    // resetTelemetry() (subsequent sessions, when TelemetryAggregator restarts
    // sessionStartTime). Paired with a fresh read at every getSessionTelemetry()
    // call to give the SaaS the (start, end, chargingDuring) tuple it needs to
    // compute battery_drain_avg_pct_per_hr. Without this capture,
    // batteryLevelStart stays null on the aggregator → omitted from the
    // telemetry payload → drain field comes back null on every session.
    @Volatile private var batterySnapshotAtStart: Double? = null
    @Volatile private var chargingAtStart: Boolean = false

    // GPS Health Tracking
    private var currentGpsAccuracy: Float? = null
    private val gpsAvailabilityDropTimestamps = Collections.synchronizedList(mutableListOf<Long>())
    private var lastGpsUnreliableErrorTime: Long = 0L
    private val GPS_UNRELIABLE_ERROR_COOLDOWN_MS = 60_000L // Emit error max once per minute

    // Wake Lock Management
    private var wakeLock: PowerManager.WakeLock? = null
    private var isWakeLockAcquired = false
    private var wakeLockAcquireTime: Long = 0L
    // Wake lock duration now tied to accuracy profile (calculated dynamically)

    /**
     * Get wake lock duration based on accuracy profile
     * More aggressive profiles get shorter wake locks to limit battery impact
     */
    private fun getWakeLockDuration(): Long = when (smartConfig.accuracyProfile) {
        SmartGpsConfig.AccuracyProfile.MAX_ACCURACY -> 12 * 60 * 60 * 1000L   // 12 hours - max tracking
        SmartGpsConfig.AccuracyProfile.BALANCED -> 8 * 60 * 60 * 1000L        // 8 hours - balanced
        SmartGpsConfig.AccuracyProfile.BATTERY_OPTIMAL -> 4 * 60 * 60 * 1000L // 4 hours - battery priority
        SmartGpsConfig.AccuracyProfile.ADAPTIVE -> 6 * 60 * 60 * 1000L        // 6 hours - adaptive
    }

    // Smart GPS Configuration
    private var smartConfig: SmartGpsConfig = SmartGpsConfig()
    private var currentGpsInterval: Long = 5000L
    private var isStationary: Boolean = false

    // ML Telemetry: GPS interval distribution
    private val intervalTimeMs = java.util.concurrent.ConcurrentHashMap<Long, Long>()
    private var lastIntervalChangeTime: Long = System.currentTimeMillis()
    private var lastTrackedInterval: Long = 5000L
    private var totalIntervalMs: Long = 0L
    private var intervalSampleCount: Int = 0

    // ML Telemetry: stationary tracking
    private var cumulativeStationaryMs: Long = 0L
    private var stationaryStartTime: Long? = null
    private var trackingStartTime: Long = System.currentTimeMillis()

    // Movement tracking for stationary detection (independent of movementSettings)
    private var lastMovementLocation: android.location.Location? = null
    private var lastMovementTime: Long = 0L

    // Track last location where zone check was performed
    private var lastZoneCheckLocation: android.location.Location? = null
    private val MIN_MOVEMENT_FOR_ZONE_CHECK_METERS = 5.0f  // Only recheck zones if moved >5m
    private var lastKnownLocation: android.location.Location? = null

    // Runtime Status Emission
    private var lastEmittedStatus = mapOf<String, Any?>()
    private var lastStatusEmitTime = 0L

    // Consolidated health monitoring (replaces separate permission/GPS checks)
    // Combined health check runs every 60s instead of separate 30s GPS + 60s permission checks
    private var combinedHealthCheckHandler: android.os.Handler? = null
    private val combinedHealthCheckInterval = 60_000L  // 60 seconds (unified interval)
    private var healthScoreTickCount = 0
    private val healthScoreEmitEveryNTicks = 5  // Emit health score every 5 ticks = 5 minutes

    // Throttle callbacks when stationary
    private var lastDelegateCallbackTime = 0L
    private val stationaryDelegateCallbackInterval = 30_000L  // 30s when stationary (vs every update when moving)

    // Activity Recognition
    private var activityRecognitionManager: ActivityRecognitionManager? = null
    private var activitySettings: ActivitySettings = ActivitySettings()
    private var currentActivity: ActivityType = ActivityType.UNKNOWN

    override fun onCreate() {
        super.onCreate()

        // Set current instance for static access to zone states
        currentInstance = this

        // Capture battery snapshot for telemetry drain calculation. Done here
        // so it aligns with TelemetryAggregator's sessionStartTime (set when
        // this LocationTracker was constructed moments earlier). The matching
        // end-snapshot + setBatteryInfo call lives in the companion
        // getSessionTelemetry() below; subsequent sessions re-capture via
        // resetTelemetry().
        captureBatterySessionStart()

        // Apply pending bridge platform set before service existed
        pendingBridgePlatform?.let { platform ->
            telemetryAggregator.setBridgePlatform(platform)
        }

        // Apply pending core delegate set before service existed
        pendingCoreDelegate?.let { delegate ->
            coreDelegate = delegate
        }

        // Log device info for debugging battery issues on Samsung/etc
        DeviceOptimization.logDeviceInfo(TAG)

        // Initialize configuration
        config = PolyfenceConfig(this)
        config.validateAndCorrect()

        // Initialize persistence
        zonePersistence = ZonePersistence(this)

        // Initialize location client
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)

        // Initialize error recovery
        errorRecovery = PolyfenceErrorRecovery(this)
        healthCheckHandler = android.os.Handler(Looper.getMainLooper())

        // Setup geofence engine callback
        geofenceEngine.setEventCallback { zoneId, eventType, location, detectionTimeMs ->
            handleGeofenceEvent(zoneId, eventType, location, detectionTimeMs)
        }

        // Wire up zone persistence for state recovery across service restarts
        geofenceEngine.setZonePersistence(zonePersistence)

        // Configure validation using config
        geofenceEngine.setValidationConfig(
            requireConfirmation = config.requireConfirmation,
            confirmationPoints = config.confidencePoints
        )

        // Set GPS accuracy threshold from config (default: 100m for platform parity)
        geofenceEngine.setGpsAccuracyThreshold(config.gpsAccuracyThreshold)

        // Setup location callback with recovery
        setupLocationCallbackWithRecovery()

        // Initialize smart GPS configuration
        initializeSmartConfiguration()

        createNotificationChannels()

        // Initialize tracking scheduler and restore saved config.
        // Synchronised on the companion monitor so a concurrent
        // [getCurrentConfigurationMap] or [setScheduleConfig] on
        // another thread doesn't race with this lazy-init and
        // orphan one instance behind the other — all three
        // instantiation sites contend for the same lock.
        val scheduler = synchronized(Companion) {
            trackingScheduler ?: TrackingScheduler(this).also {
                trackingScheduler = it
            }
        }
        scheduler.loadConfig()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_TRACKING -> {
                if (!hasLocationPerms()) {
                    Log.w(TAG, "Missing runtime permissions for location/FGS; not starting tracking")
                    return START_NOT_STICKY // do not restart
                }
                startTracking()
            }
            ACTION_STOP_TRACKING -> stopTracking()
            ACTION_ADD_ZONE -> {
                // CRITICAL GUARD: Don't process zone operations if not tracking
                if (!isRunning) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                addZone(intent)
            }
            ACTION_REMOVE_ZONE -> {
                // Allow zone removal even when tracking is stopped
                // This ensures persistence is updated regardless of service state
                removeZone(intent)
                // Stop service if it's not actively tracking
                if (!isRunning) {
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_CLEAR_ZONES -> {
                // Allow clearing zones even when tracking is stopped
                // This ensures persistence is updated regardless of service state
                clearZones()
                // Stop service if it's not actively tracking
                if (!isRunning) {
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_UPDATE_CONFIG -> {
                val configMap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    @Suppress("UNCHECKED_CAST")
                    intent.getSerializableExtra("config", HashMap::class.java) as? Map<String, Any>
                } else {
                    @Suppress("DEPRECATION")
                    intent.getSerializableExtra("config") as? Map<String, Any>
                }
                if (configMap != null) {
                    updateConfigurationFromMap(configMap)
                }
            }
        }
        return START_STICKY
    }

    private fun hasLocationPerms(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val bgOk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        // API 34 (Android 14) requires FOREGROUND_SERVICE_LOCATION permission
        val fgsOk = if (Build.VERSION.SDK_INT >= 34) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.FOREGROUND_SERVICE_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true
        return (fine || coarse) && bgOk && fgsOk
    }

    // Track if GPS start is deferred waiting for zones
    private var gpsStartDeferred = false

    private fun startTracking() {
        // Must call startForeground() immediately — Android requires it within ~10s
        // of startForegroundService(). Do this BEFORE any checks that might bail out.
        startForeground(NOTIFICATION_ID, createTrackingNotification())

        if (!hasLocationPerms()) {
            Log.e(TAG, "Cannot start tracking - missing permissions")
            @Suppress("DEPRECATION")
            stopForeground(true)
            stopSelf()
            return
        }

        isRunning = true
        firstLocationAfterRestart = true  // Reset for state reconciliation
        hasReceivedFirstLocation = false  // Reset for distance filter deferral

        // Persist tracking state for restart recovery (used by ScheduleReceiver)
        getSharedPreferences("polyfence_tracking", Context.MODE_PRIVATE)
            .edit().putBoolean("continuous_tracking_active", true).apply()

        // Acquire wake lock before starting location requests
        acquireWakeLock()

        // Restore zones from storage ONLY when tracking starts
        restoreZonesFromStorage()

        // Start combined health monitoring (replaces separate GPS + permission checks)
        startCombinedHealthMonitoring()

        // Apply any pending activity settings that were set before tracking started
        pendingActivitySettings?.let { pending ->
            Log.d(TAG, "Applying pending activity settings: enabled=${pending.enabled}")
            activitySettings = pending
            pendingActivitySettings = null
        }

        // Ensure activity recognition is started if enabled but not running
        // Must be before the zones check since activity recognition is independent of zones
        if (activitySettings.enabled && activityRecognitionManager == null) {
            Log.d(TAG, "Starting activity recognition on tracking start")
            updateActivityRecognition(activitySettings)
        }

        // Only start GPS if zones exist, otherwise defer
        if (!geofenceEngine.hasZones()) {
            Log.d(TAG, "No zones registered - deferring GPS start until zones are added")
            gpsStartDeferred = true
            return
        }

        startGpsUpdates()
    }

    /**
     * Start GPS location updates (extracted for deferred start)
     */
    private fun startGpsUpdates() {
        gpsStartDeferred = false

        // Use smart GPS configuration for location request
        val priority = smartConfig.getLocationPriority()
        val interval = calculateCurrentInterval()

        // Defer distance filter until first location is received. Without this,
        // FusedLocationProvider suppresses ALL callbacks on a stationary device
        // because setMinUpdateDistanceMeters requires movement before delivering.
        // iOS handles this with requestLocation() + locationManager.location seed.
        val distanceFilter = if (!hasReceivedFirstLocation) 0f else smartConfig.getDistanceFilter()

        val locationRequest = LocationRequest.Builder(priority, interval)
            .setMinUpdateIntervalMillis(interval / 2)
            .setMaxUpdateDelayMillis(interval * 2)
            .setWaitForAccurateLocation(smartConfig.shouldWaitForAccurateLocation())
            .setMinUpdateDistanceMeters(distanceFilter)
            .build()

        try {
            val callback = locationCallback ?: run {
                Log.e(TAG, "LocationCallback is null - cannot start location updates")
                return
            }
            fusedLocationClient?.requestLocationUpdates(
                locationRequest,
                callback,
                Looper.getMainLooper()
            )
            Log.d(TAG, "GPS updates started with profile: ${smartConfig.accuracyProfile}, distanceFilter=${distanceFilter}m")

            // Seed initial location from FusedLocationProvider cache (mirrors iOS
            // pattern: requestLocation() + locationManager.location on startup).
            // This ensures the app gets a position immediately on a stationary device.
            if (!hasReceivedFirstLocation) {
                try {
                    @SuppressLint("MissingPermission")  // Permissions verified in startTracking()
                    val lastLocTask = fusedLocationClient?.lastLocation
                    lastLocTask?.addOnSuccessListener { location ->
                        if (location != null && firstLocationAfterRestart && isRunning) {
                            Log.d(TAG, "Seeding initial location from lastLocation cache")
                            lastLocationTime = System.currentTimeMillis()
                            sendLocationToDelegate(location)
                            firstLocationAfterRestart = false
                            geofenceEngine.reconcileZoneStates(location)
                            updateMovementState(location)
                        }
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Cannot seed lastLocation - permission denied")
                }
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Location permission denied: ${e.message}")
            PolyfenceErrorManager.reportError(
                "permission_revoked",
                "Location permission was revoked - SecurityException during GPS start",
                mapOf("platform" to "android", "error" to (e.message ?: ""), "timestamp" to System.currentTimeMillis())
            )
            errorRecovery.handlePermissionLoss()
            stopSelf()
        }
    }

    private fun stopTracking() {
        // Clear persisted tracking state (used by ScheduleReceiver for restart recovery)
        getSharedPreferences("polyfence_tracking", Context.MODE_PRIVATE)
            .edit().putBoolean("continuous_tracking_active", false).apply()

        isRunning = false
        locationCallback?.let { callback ->
            fusedLocationClient?.removeLocationUpdates(callback)
        }

        // Release wake lock before stopping
        releaseWakeLock()

        // Stop error monitoring
        errorRecovery.stopMonitoring()
        healthCheckHandler?.removeCallbacksAndMessages(null)

        // Stop combined health monitoring
        stopCombinedHealthMonitoring()

        // Stop activity recognition
        activityRecognitionManager?.stop()

        stopForeground(true)
        stopSelf()
    }

    /**
     * Combined health monitoring - consolidates GPS health + permission checks
     * Runs every 60 seconds instead of separate 30s GPS + 60s permission timers
     * Reduces timer overhead from 4 timers to 2 (this + wake lock check)
     */
    private fun startCombinedHealthMonitoring() {
        combinedHealthCheckHandler = android.os.Handler(Looper.getMainLooper())
        combinedHealthCheckHandler?.postDelayed(object : Runnable {
            override fun run() {
                if (!isRunning) return

                // === Permission Check (was separate 60s timer) ===
                if (!hasLocationPerms()) {
                    Log.w(TAG, "Location permission revoked - stopping tracking gracefully")
                    PolyfenceErrorManager.reportError(
                        "permission_revoked",
                        "Location permission was revoked by user during tracking",
                        mapOf("platform" to "android", "timestamp" to System.currentTimeMillis())
                    )
                    stopTracking()
                    return
                }

                // === GPS Health Check (was separate 30s timer) ===
                val currentTime = System.currentTimeMillis()
                val timeSinceLastLocation = currentTime - lastLocationTime

                if (timeSinceLastLocation > 120_000L && lastLocationTime > 0) {
                    Log.w(TAG, "GPS health check - no location for ${timeSinceLastLocation / 1000}s")

                    if (consecutiveGpsFailures in 3..5) {
                        Log.w(TAG, "Triggering GPS recovery")
                        errorRecovery.handleGpsFailure()
                    }
                }

                // === System Health Snapshot (was separate 12min timer, now piggybacks) ===
                try {
                    val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toDouble()
                    val isCharging = bm.isCharging
                    val gpsActive = timeSinceLastLocation < 60_000

                    Log.d(TAG, "Health - battery=${level}%, charging=$isCharging, gps=$gpsActive")
                } catch (e: Exception) {
                    Log.e(TAG, "Health snapshot failed: ${e.message}")
                }

                // === Health Score Emission (every 5 minutes) ===
                healthScoreTickCount++
                if (healthScoreTickCount >= healthScoreEmitEveryNTicks) {
                    healthScoreTickCount = 0
                    // emitHealthScore -> collectDebugInfo -> getCpuUsage reads
                    // /proc/stat with a 360ms sleep and require()s it isn't
                    // running on the main looper. This runnable IS scheduled
                    // on Looper.getMainLooper() (see combinedHealthCheckHandler
                    // init below), so calling emitHealthScore inline throws
                    // IllegalArgumentException — the outer try/catch swallows
                    // it and onHealthScore consumers never receive an event.
                    // Spawn a background thread so the CPU read can block
                    // without violating the main-looper guard. Once per 5
                    // minutes; lifecycle is trivial — no shared executor
                    // needed.
                    Thread {
                        try {
                            emitHealthScore()
                        } catch (e: Throwable) {
                            Log.e(TAG, "Health score background emission failed: ${e.message}")
                        }
                    }.start()
                }

                // Schedule next combined check
                if (isRunning) {
                    combinedHealthCheckHandler?.postDelayed(this, combinedHealthCheckInterval)
                }
            }
        }, combinedHealthCheckInterval)

        Log.d(TAG, "Combined health monitoring started - checking every ${combinedHealthCheckInterval / 1000}s")
    }

    /**
     * Stop combined health monitoring
     */
    private fun stopCombinedHealthMonitoring() {
        combinedHealthCheckHandler?.removeCallbacksAndMessages(null)
        combinedHealthCheckHandler = null
        healthScoreTickCount = 0
        Log.d(TAG, "Combined health monitoring stopped")
    }

    /**
     * Compute and emit health score via onPerformanceEvent.
     * Reads from PolyfenceDebugCollector and TelemetryAggregator.
     */
    private fun emitHealthScore() {
        // Parity with iOS LocationTracker.emitHealthScore which bails early
        // on `guard isRunning`. A background thread spawned in the previous
        // tick can race past a concurrent stopTracking() call and emit a
        // stale health score after the tracker is meant to be quiet. Cheap
        // guard, no behavioural cost when running.
        if (!isRunning) return
        try {
            val debugInfo = PolyfenceDebugCollector.collectDebugInfo(applicationContext)
            val perfMetrics = debugInfo["performance"] as? Map<*, *>
            val telemetry = telemetryAggregator.getSessionTelemetry()

            val gpsGoodRatio = (telemetry["gps_ok_ratio"] as? Number)?.toDouble() ?: 0.0
            val batteryMetrics = debugInfo["battery"] as? Map<*, *>
            val batteryDrain = (batteryMetrics?.get("estimatedHourlyDrainPercent") as? Number)?.toDouble() ?: 0.0
            val avgLatency = (perfMetrics?.get("averageDetectionLatencyMs") as? Number)?.toDouble() ?: 0.0
            val errorCount = (debugInfo["recentErrors"] as? List<*>)?.size ?: 0
            val falseRatio = (telemetry["false_event_ratio"] as? Number)?.toDouble() ?: 0.0
            val zoneCount = geofenceEngine.getZoneCount()

            val result = HealthScoreCalculator.calculate(
                gpsGoodRatio = gpsGoodRatio,
                batteryDrainPctPerHr = batteryDrain,
                avgDetectionLatencyMs = avgLatency,
                errorCountRecent = errorCount,
                falseEventRatio = falseRatio,
                isTracking = isRunning,
                activeZoneCount = zoneCount
            )

            val payload = mapOf<String, Any>(
                "type" to "health_score",
                "score" to result.score,
                "topIssue" to (result.topIssue ?: ""),
                "timestamp" to System.currentTimeMillis()
            )

            coreDelegate?.onPerformanceEvent(payload)
        } catch (e: Exception) {
            Log.e(TAG, "Health score emission failed: ${e.message}")
        }
    }

    private fun addZone(intent: Intent) {
        val zoneId = intent.getStringExtra("zoneId") ?: return
        val zoneName = intent.getStringExtra("zoneName") ?: "Unknown Zone"
        val zoneData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            @Suppress("UNCHECKED_CAST")
            intent.getSerializableExtra("zoneData", HashMap::class.java) as? Map<String, Any>
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("zoneData") as? Map<String, Any>
        } ?: return
        addZoneById(zoneId, zoneName, zoneData)
    }

    /**
     * Primitive-args entry point for adding a zone to the running service
     * instance. Extracted from the Intent-based `addZone(intent)` so the
     * [Companion.applyAddZoneDirect] helper can dispatch the same logic
     * synchronously without going through `startService`.
     *
     * Full behaviour of the Intent path: validate via engine, surface a
     * `zone_validation_failed` error on rejection, persist on success, kick
     * deferred GPS start when the first zone lands, and re-reconcile zone
     * states against the last-known location for cold-start ENTER when
     * tracking is already active.
     */
    private fun addZoneById(zoneId: String, zoneName: String, zoneData: Map<String, Any>) {
        // Mirror the Intent handler's guard: ADD_ZONE is only meaningful
        // while tracking is active. Without this, the direct-apply path
        // would add the zone to the running Service instance when the
        // Intent path would have dropped it — same call, opposite
        // outcome, decided by a race window between stopTracking() and
        // the Service's onDestroy. Bridge callers who add zones outside
        // of an active tracking session use their own persistence
        // pre-tracking (see the RN / Flutter bridges' addZone helpers),
        // so this guard preserves that split.
        if (!isRunning) return

        // Add to engine (skip invalid zones instead of crashing). Route the
        // rejection through PolyfenceErrorManager so the bridge surfaces the
        // failure via the onError channel — a plain Log.w would leave the
        // bridge's addZone() Promise resolving as success even though the
        // zone was dropped, and consumers would have no signal to react.
        try {
            geofenceEngine.addZone(zoneId, zoneName, zoneData)
        } catch (e: Exception) {
            Log.w(TAG, "Skipping invalid zone $zoneId: ${e.message}")
            PolyfenceErrorManager.reportError(
                "zone_validation_failed",
                "Zone $zoneId was rejected: ${e.message ?: "unknown validation error"}",
                mapOf(
                    "platform" to "android",
                    "zoneId" to zoneId,
                    "zoneName" to zoneName,
                    "timestamp" to System.currentTimeMillis()
                )
            )
            return
        }

        // Save to persistent storage
        zonePersistence.saveZone(zoneId, zoneName, zoneData)

        // Start GPS if it was deferred waiting for zones
        if (gpsStartDeferred && isRunning && geofenceEngine.hasZones()) {
            Log.d(TAG, "First zone added - starting deferred GPS updates")
            startGpsUpdates()
        } else if (isRunning) {
            // Tracking already running. This zone was added AFTER startGpsUpdates'
            // initial reconcile already ran, so without a re-reconcile the new
            // zone never gets its cold-start ENTER even if the user is currently
            // inside it (the engine's per-tick checkLocation goes through
            // getZonesToCheck which may exclude this zone via clustering until
            // it acquires INSIDE state, which would never happen).
            // Re-reconciling now uses the last-known location to evaluate the
            // newly-added zone against the user's current position.
            // Safe to call repeatedly because reconcileZoneStates' fresh-install
            // branch is now idempotent (fires ENTER only on the false -> true
            // state transition).
            lastKnownLocation?.let { cachedLocation ->
                geofenceEngine.reconcileZoneStates(cachedLocation)
            }
        }
    }

    private fun removeZone(intent: Intent) {
        val zoneId = intent.getStringExtra("zoneId") ?: return
        removeZoneById(zoneId)
    }

    /**
     * Primitive-args entry point for removing a zone from the running
     * service instance. Extracted from the Intent-based `removeZone(intent)`
     * so [Companion.applyRemoveZoneDirect] can dispatch the same removal
     * synchronously — engine state and persistence updated before this
     * returns, so a caller's next `getCurrentZoneStates()` observes the
     * removal.
     */
    private fun removeZoneById(zoneId: String) {
        geofenceEngine.removeZone(zoneId)
        zonePersistence.removeZone(zoneId)
    }

    private fun clearZones() {
        // Clear from engine
        geofenceEngine.clearAllZones()

        // Clear from persistent storage
        zonePersistence.clearAllZones()

    }

    // Restore zones from storage on service start
    private fun restoreZonesFromStorage() {
        try {
            val savedZones = zonePersistence.loadAllZones()
            var restored = 0
            var failed = 0

            savedZones.forEach { (zoneId, zoneInfo) ->
                try {
                    val (id, name, data) = zoneInfo
                    geofenceEngine.addZone(id, name, data)
                    restored++
                } catch (e: Exception) {
                    Log.w(TAG, "Skipping invalid zone $zoneId: ${e.message}")
                    failed++
                }
            }

            // Load persisted zone states AFTER zones are loaded
            // This restores the "inside/outside" state from before service restart
            geofenceEngine.loadPersistedZoneStates()

            Log.i(TAG, "Restored $restored zones from storage ($failed failed)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore zones: ${e.message}")
        }
    }

    // Track if first location after restart has been processed
    private var firstLocationAfterRestart = true
    private var hasReceivedFirstLocation = false

private fun handleGeofenceEvent(zoneId: String, eventType: String, location: android.location.Location, detectionTimeMs: Double) {
    // Get zone name from GeofenceEngine
    val zoneName = geofenceEngine.getZoneName(zoneId) ?: zoneId

    // Get GPS accuracy
    val gpsAccuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0

    // ML Telemetry: per-event enrichment
    val speedMps = if (location.hasSpeed()) location.speed.toDouble() else 0.0
    val activityType = activityRecognitionManager?.getCurrentActivity()?.name?.lowercase() ?: "unknown"
    val distanceToBoundary = geofenceEngine.getDistanceToBoundary(zoneId, location)

    // Record in centralized telemetry aggregator
    telemetryAggregator.recordGeofenceEvent(
        zoneId = zoneId,
        eventType = eventType,
        distanceM = distanceToBoundary,
        speedMps = speedMps,
        accuracyM = gpsAccuracy,
        detectionTimeMs = detectionTimeMs
    )

    // Send event to delegate with detection metrics, GPS coordinates, and ML context.
    // `timestamp` mirrors the iOS event map (see ios/Classes/LocationTracker.swift:639);
    // without it, polyfence-flutter's bridge can't parse the event and emits a noisy
    // "Invalid timestamp type: Null" error for every geofence transition.
    //
    // `dwellDurationMs` is populated only for DWELL events. For
    // ENTER/EXIT/RECOVERY_* events the key is absent from the map —
    // bridges surface it as undefined/null which matches the "only
    // meaningful for dwell" semantic. Read against the same zoneEntryTimes
    // map that the dwell-check writes into, so the value is exactly the
    // time-in-zone the DWELL threshold just crossed.
    val eventMap = mutableMapOf<String, Any>(
        "zoneId" to zoneId,
        "zoneName" to zoneName,
        "eventType" to eventType,
        "timestamp" to System.currentTimeMillis(),
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "detectionTimeMs" to detectionTimeMs,
        "gpsAccuracy" to gpsAccuracy,
        "speedMps" to speedMps,
        "activityAtEvent" to activityType,
        "distanceToBoundaryM" to distanceToBoundary
    )
    if (eventType == GeofenceEngine.EVENT_DWELL) {
        geofenceEngine.getDwellDurationMs(zoneId)?.let { dwellMs ->
            eventMap["dwellDurationMs"] = dwellMs
        }
    }
    coreDelegate?.onGeofenceEvent(eventMap)

    // Terse geofence event log
    val displayName = if (zoneName.isNotEmpty()) zoneName else zoneId
    Log.i(TAG, "PF: EVENT $eventType zone=$displayName detection=${detectionTimeMs}ms speed=${speedMps}m/s activity=$activityType")

    // Show notification with proper zone name
    showGeofenceNotification(eventType, zoneId, zoneName)

}

    private fun sendLocationToDelegate(location: android.location.Location) {
        val locationData = mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracy" to location.accuracy.toDouble(),
            "timestamp" to System.currentTimeMillis(),
            "speed" to (if (location.hasSpeed()) location.speed * 3.6 else 0.0), // Convert m/s to km/h
            "activity" to currentActivity.name.lowercase() // Include current activity type
        )
        coreDelegate?.onLocationUpdate(locationData)
    }

    private fun showGeofenceNotification(eventType: String, zoneId: String, zoneName: String) {
    if (!isRunning) return
    if (!alertNotificationsEnabled) return  // Respect disableAlertNotifications config
    // Zone name leads the title so the alert names the place, not our
    // category. DWELL and RECOVERY_ENTER are inside-states — only a true
    // EXIT / RECOVERY_EXIT reads as leaving.
    val title = when (eventType) {
        "ENTER", GeofenceEngine.EVENT_RECOVERY_ENTER -> "Entered $zoneName"
        GeofenceEngine.EVENT_DWELL -> "Dwelling in $zoneName"
        else -> "Exited $zoneName"
    }
    // Body carries time-in-zone for DWELL only; ENTER/EXIT stay single-line.
    val body: String? =
        if (eventType == GeofenceEngine.EVENT_DWELL) formatDwellBody(zoneId) else null

    // Create PendingIntent to reuse existing app task when notification is tapped
    // Use dynamic package resolution instead of hardcoded class name
    val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    } ?: Intent().apply {
        setPackage(packageName)
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }

    val pendingIntent = PendingIntent.getActivity(
        this,
        0,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    val builder = NotificationCompat.Builder(this, GEOFENCE_CHANNEL_ID)
        .setContentTitle(title)
        .setSmallIcon(android.R.drawable.ic_menu_mylocation)
        .setContentIntent(pendingIntent) // Opens app on tap
        .setAutoCancel(true) // Dismisses notification on tap
        .setPriority(NotificationCompat.PRIORITY_HIGH)
        .setDefaults(NotificationCompat.DEFAULT_ALL)
    if (body != null) builder.setContentText(body)
    val notification = builder.build()

    val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    notificationManager.notify(System.currentTimeMillis().toInt(), notification)
}

    /**
     * Human-readable "time in zone" line for DWELL alerts, e.g. "Here 12 min".
     * Null when the engine has no dwell start recorded for the zone.
     */
    private fun formatDwellBody(zoneId: String): String? {
        val ms = geofenceEngine.getDwellDurationMs(zoneId) ?: return null
        val totalMinutes = (ms / 60_000L).toInt()
        return when {
            totalMinutes < 1 -> "Here under a minute"
            totalMinutes < 60 -> "Here $totalMinutes min"
            else -> {
                val h = totalMinutes / 60
                val m = totalMinutes % 60
                if (m == 0) "Here ${h}h" else "Here ${h}h ${m}min"
            }
        }
    }

    private fun createTrackingNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Polyfence Active")
            .setContentText("Monitoring geofence zones")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Tracking channel
            val trackingChannel = NotificationChannel(
                CHANNEL_ID,
                "Location Tracking",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Background location tracking"
                setSound(null, null)
            }

            // Geofence alerts (high priority)
            val alertChannel = NotificationChannel(
                GEOFENCE_CHANNEL_ID,
                "Geofence Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Zone entry and exit notifications"
                enableVibration(true)
                enableLights(true)
                setSound(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI, null)
                setVibrationPattern(longArrayOf(0, 500, 200, 500))
            }

            notificationManager.createNotificationChannel(trackingChannel)
            notificationManager.createNotificationChannel(alertChannel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        currentInstance = null  // Clear instance reference
        errorRecovery.stopMonitoring()
        healthCheckHandler?.removeCallbacksAndMessages(null)
        // Stop activity recognition and unregister receiver
        activityRecognitionManager?.stop()
        activityRecognitionManager = null
        // Ensure wake lock is released
        releaseWakeLock()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.i(TAG, "App task removed - foreground service continues tracking")
    }

    // Wake Lock Management Methods

    /**
     * Schedule health check to detect and release zombie wake locks
     * Checks if wake lock has exceeded maximum duration and force-releases if needed
     * Also handles auto-renewal if tracking continues beyond timeout
     */
    private fun scheduleWakeLockHealthCheck() {
        healthCheckHandler?.removeCallbacksAndMessages(null)

        // Check every hour, or when approaching timeout (whichever is sooner)
        val checkInterval = 60 * 60 * 1000L // 1 hour

        healthCheckHandler?.postDelayed({
            if (wakeLock?.isHeld == true && isWakeLockAcquired) {
                val wakeLockDuration = getWakeLockDuration()  // Use profile-based duration
                val age = System.currentTimeMillis() - wakeLockAcquireTime
                val remainingTime = wakeLockDuration - age

                // If wake lock is approaching expiration (within 1 hour) and tracking is still active, renew it
                if (remainingTime < 60 * 60 * 1000L && isRunning) {
                    Log.i(TAG, "Wake lock approaching timeout (${remainingTime / 1000 / 60}min remaining) - auto-renewing")

                    // Release old wake lock and re-acquire with profile-based timeout
                    releaseWakeLock()
                    acquireWakeLock()
                    return@postDelayed
                }

                // If wake lock exceeded timeout (shouldn't happen with Android's built-in timeout, but safety net)
                if (age > wakeLockDuration) {
                    Log.w(TAG, "Wake lock exceeded ${wakeLockDuration / 1000 / 60 / 60}h timeout - force releasing")

                    // Report error
                    PolyfenceErrorManager.reportError(
                        "wake_lock_timeout",
                        "Wake lock held beyond timeout - released automatically",
                        mapOf(
                            "platform" to "android",
                            "duration_hours" to (age / 1000 / 60 / 60),
                            "timestamp" to System.currentTimeMillis()
                        )
                    )

                    // Force release wake lock
                    releaseWakeLock()

                    // If tracking is still active, re-acquire wake lock (auto-renewal)
                    if (isRunning) {
                        Log.i(TAG, "Re-acquiring wake lock for continued tracking")
                        acquireWakeLock()
                    }
                } else {
                    // Wake lock still valid - schedule next check
                    val nextCheckTime = remainingTime.coerceAtMost(checkInterval)
                    healthCheckHandler?.postDelayed({
                        scheduleWakeLockHealthCheck()
                    }, nextCheckTime)
                }
            }
        }, checkInterval)
    }

    private fun acquireWakeLock() {
        try {
            // Release any existing lock first (defensive)
            releaseWakeLock()

            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Polyfence:LocationTracking"
                )
            }

            if (!isWakeLockAcquired) {
                // Acquire wake lock with profile-based timeout for battery safety
                // More aggressive profiles get shorter wake locks
                val wakeLockDuration = getWakeLockDuration()
                wakeLock?.acquire(wakeLockDuration)
                isWakeLockAcquired = true
                wakeLockAcquireTime = System.currentTimeMillis()

                Log.i(TAG, "Wake lock acquired with ${wakeLockDuration / 1000 / 60 / 60}h timeout (profile: ${smartConfig.accuracyProfile})")

                // Schedule health check to monitor wake lock age
                scheduleWakeLockHealthCheck()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock: ${e.message}")
            // Wake lock failure is not critical - service can still run
        }
    }

    private fun releaseWakeLock() {
        try {
            if (isWakeLockAcquired) {
                val holdDuration = if (wakeLockAcquireTime > 0) {
                    System.currentTimeMillis() - wakeLockAcquireTime
                } else {
                    0L
                }

                wakeLock?.release()
                isWakeLockAcquired = false
                wakeLockAcquireTime = 0L

                // Cancel health check when wake lock is released
                healthCheckHandler?.removeCallbacksAndMessages(null)

                Log.i(TAG, "Wake lock released after ${holdDuration / 1000 / 60}min")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release wake lock: ${e.message}")
        }
    }

    // Error Recovery Methods

    private fun setupLocationCallbackWithRecovery() {
    locationCallback = object : LocationCallback() {
        override fun onLocationResult(locationResult: LocationResult) {
            locationResult.lastLocation?.let { location ->
                // Guard clause: only process if tracking is active (iOS parity)
                if (!isRunning) {
                    return
                }

                // STATE RECOVERY: On first valid location after service restart,
                // reconcile persisted zone states with actual location.
                // This fires RECOVERY_ENTER/RECOVERY_EXIT for any mismatches.
                if (firstLocationAfterRestart) {
                    firstLocationAfterRestart = false
                    Log.i(TAG, "First location after restart - reconciling zone states")
                    geofenceEngine.reconcileZoneStates(location)
                }

                // After first real GPS callback, re-apply location request with the
                // profile's distance filter. Initial request uses 0m to guarantee
                // delivery on a stationary device.
                if (!hasReceivedFirstLocation) {
                    hasReceivedFirstLocation = true
                    Log.d(TAG, "First GPS fix received - applying profile distance filter")
                    updateLocationRequest()
                }

                // Update movement state for smart GPS
                updateMovementState(location)

                // Log proximity debug info
                logProximityDebugInfo(location)

                // Update GPS health tracking
                lastLocationTime = System.currentTimeMillis()
                consecutiveGpsFailures = 0
                currentGpsAccuracy = if (location.hasAccuracy()) location.accuracy else null

                // Record in centralized telemetry aggregator
                telemetryAggregator.recordGpsUpdate(
                    intervalMs = currentGpsInterval,
                    accuracyM = location.accuracy
                )

                // Check for unreliable GPS (large accuracy swings, poor accuracy)
                checkGpsReliability(location)

                // Reset error recovery attempts on successful location
                errorRecovery.resetRestartAttempts()

                // Throttle delegate callbacks when stationary to reduce overhead
                val currentTime = System.currentTimeMillis()
                val timeSinceLastCallback = currentTime - lastDelegateCallbackTime
                val shouldSendToDelegate = if (isStationary) {
                    // When stationary, only send updates every 30s
                    timeSinceLastCallback >= stationaryDelegateCallbackInterval
                } else {
                    // When moving, send every update
                    true
                }

                if (shouldSendToDelegate) {
                    sendLocationToDelegate(location)
                    lastDelegateCallbackTime = currentTime
                }

                // Only check geofences if moved significantly since last check
                val shouldCheckZones = lastZoneCheckLocation?.let { lastLoc ->
                    location.distanceTo(lastLoc) > MIN_MOVEMENT_FOR_ZONE_CHECK_METERS
                } ?: true  // Always check on first location

                if (shouldCheckZones) {
                    geofenceEngine.checkLocation(location)
                    lastZoneCheckLocation = location
                }
            }
        }

        override fun onLocationAvailability(locationAvailability: LocationAvailability) {
            if (!locationAvailability.isLocationAvailable) {
                Log.w(TAG, "Location availability lost")
                consecutiveGpsFailures++

                // Track GPS availability drop for health metrics
                val currentTime = System.currentTimeMillis()
                gpsAvailabilityDropTimestamps.add(currentTime)
                cleanupOldGpsDrops(currentTime)

                // Emit gpsUnreliable error if we've had multiple drops recently
                val drops5Min = getGpsAvailabilityDrops5Min()
                if (drops5Min >= 3) {
                    emitGpsUnreliableError(drops5Min)
                }

                // Trigger recovery for GPS failures (up to 5 consecutive failures)
                // After 5 failures, stop trying to avoid battery drain
                if (consecutiveGpsFailures <= 5) {
                    errorRecovery.handleGpsFailure()
                } else {
                    Log.w(TAG, "Too many consecutive GPS failures ($consecutiveGpsFailures), stopping recovery attempts")
                }
            }
        }
    }
}

    // Recovery Actions

    private fun handleGpsRestart() {
    Log.w(TAG, "Attempting GPS restart")

    try {
        // Stop current location updates
        locationCallback?.let { callback ->
            fusedLocationClient?.removeLocationUpdates(callback)
        }

        // Use more conservative settings on restart
        healthCheckHandler?.postDelayed({
            if (isRunning) {
                val locationRequest = LocationRequest.Builder(
                    Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                    maxOf(config.gpsIntervalMs * 2, 10000L)
                ).apply {
                    setMinUpdateIntervalMillis(maxOf(config.minUpdateIntervalMs * 2, 5000L))
                    setMaxUpdateDelayMillis(maxOf(config.maxUpdateDelayMs * 2, 15000L))
                    setWaitForAccurateLocation(false)
                    setMinUpdateDistanceMeters(10f)
                }.build()

                try {
                    val callback = locationCallback
                    if (callback == null) {
                        Log.e(TAG, "LocationCallback is null - cannot restart GPS")
                        return@postDelayed
                    }
                    fusedLocationClient?.requestLocationUpdates(
                        locationRequest,
                        callback,
                        Looper.getMainLooper()
                    )

                    // Reapply smart GPS configuration after recovery stabilizes
                    if (smartConfig.updateStrategy != SmartGpsConfig.UpdateStrategy.CONTINUOUS) {
                        pendingSmartConfigReapplyRunnable?.let {
                            healthCheckHandler?.removeCallbacks(it)
                        }
                        val runnable = Runnable {
                            pendingSmartConfigReapplyRunnable = null
                            if (isRunning) {
                                Log.d(TAG, "Reapplying smart GPS configuration after recovery")
                                updateLocationRequest()
                            }
                        }
                        pendingSmartConfigReapplyRunnable = runnable
                        Log.d(TAG, "GPS recovery: will reapply smart config in 10s")
                        healthCheckHandler?.postDelayed(runnable, 10000L)
                    }
                } catch (e: SecurityException) {
                    Log.e(TAG, "GPS restart failed - permission denied: ${e.message}")
                    PolyfenceErrorManager.reportError(
                        "permission_revoked",
                        "Location permission was revoked - SecurityException during GPS restart",
                        mapOf("platform" to "android", "error" to (e.message ?: ""), "timestamp" to System.currentTimeMillis())
                    )
                    errorRecovery.handlePermissionLoss()
                }
            }
        }, 3000L)

    } catch (e: Exception) {
        Log.e(TAG, "GPS restart failed: ${e.message}")
    }
}

    private fun handlePermissionLoss() {
        Log.e(TAG, "Location permission lost - stopping service")
        stopTracking()
    }

    private fun handleServiceRestart() {
        Log.w(TAG, "Restarting LocationTracker service")

        // Create restart intent
        val restartIntent = Intent(this, LocationTracker::class.java).apply {
            action = ACTION_START_TRACKING
        }

        try {
            startService(restartIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Service restart failed: ${e.message}")
        }
    }

    // ============================================================================
    // GPS HEALTH MONITORING
    // ============================================================================

    /**
     * Check GPS reliability based on accuracy and consistency
     */
    private fun checkGpsReliability(location: android.location.Location) {
        if (!location.hasAccuracy()) return

        val accuracy = location.accuracy

        // Detect unreliable GPS: accuracy > 150m is considered unreliable
        // Android FLP can feed locations with 500m+ accuracy during signal loss
        if (accuracy > 150.0f) {
            emitGpsUnreliableError(getGpsAvailabilityDrops5Min(), accuracy.toDouble())
        }
    }

    /**
     * Remove GPS availability drop timestamps older than 5 minutes
     */
    private fun cleanupOldGpsDrops(currentTime: Long) {
        val fiveMinutesAgo = currentTime - 300_000L
        synchronized(gpsAvailabilityDropTimestamps) {
            val iter = gpsAvailabilityDropTimestamps.iterator()
            while (iter.hasNext()) {
                if (iter.next() < fiveMinutesAgo) iter.remove()
            }
        }
    }

    /**
     * Get number of GPS availability drops in the last 5 minutes
     */
    private fun getGpsAvailabilityDrops5Min(): Int {
        val currentTime = System.currentTimeMillis()
        cleanupOldGpsDrops(currentTime)
        return gpsAvailabilityDropTimestamps.size
    }

    /**
     * Emit gpsUnreliable error (with cooldown to prevent spam)
     */
    private fun emitGpsUnreliableError(drops: Int, accuracy: Double? = null) {
        val currentTime = System.currentTimeMillis()
        if (currentTime - lastGpsUnreliableErrorTime < GPS_UNRELIABLE_ERROR_COOLDOWN_MS) {
            return // Cooldown active - don't spam errors
        }

        lastGpsUnreliableErrorTime = currentTime

        val message = if (accuracy != null) {
            "GPS signal unreliable - poor accuracy (${accuracy.toInt()}m)"
        } else {
            "GPS signal unreliable - $drops availability drops in last 5 minutes"
        }

        val context = mutableMapOf<String, Any>(
            "platform" to "android",
            "drops5Min" to drops,
            "timestamp" to currentTime
        )

        if (accuracy != null) {
            context["accuracy"] = accuracy
        }

        Log.w(TAG, "GPS unreliable: drops=$drops, accuracy=$accuracy")

        PolyfenceErrorManager.reportError(
            "gps_unreliable",
            message,
            context
        )
    }

    // ============================================================================
    // SMART GPS CONFIGURATION METHODS
    // ============================================================================

    /**
     * Update smart GPS configuration
     */
    fun updateSmartConfiguration(config: SmartGpsConfig) {
        this.smartConfig = config
        currentSmartConfig = config

        // Apply configuration immediately if tracking is active
        if (isRunning) {
            updateLocationRequest()
        }

        config.logConfiguration(TAG)
    }

    private fun updateConfigurationFromMap(configMap: Map<String, Any>) {
        try {
            val accuracyProfileRaw = configMap["accuracyProfile"] as? String
            val updateStrategyRaw = configMap["updateStrategy"] as? String

            // Deep-merge the incoming partial map with the current
            // SmartGpsConfig so any field the caller omitted keeps its
            // current value instead of resetting to the data-class
            // default. `fromMap` on a bare partial map supplies BALANCED
            // / CONTINUOUS / null for absent keys — enough to wipe an
            // earlier updateStrategy: 'intelligent' when the caller only
            // meant to flip clusteringEnabled.
            //
            // Only the SmartGpsConfig portion is merged here. The "extras"
            // handled below (gpsAccuracyThreshold / dwellSettings /
            // clusterSettings / scheduleSettings) still apply only when
            // present in the incoming map — same replace-not-merge
            // semantics as before for those, since they're stored on
            // GeofenceEngine, not on smartConfig.
            val mergedSmartConfigMap = deepMergeMaps(
                // Sparse merge base — omits null nested settings so a
                // partial update doesn't materialise a
                // default-constructed nested block the runtime treats
                // as "feature inactive". Not the same as toMap (which
                // stays full-shape for getConfiguration display).
                base = SmartGpsConfigFactory.toMergeBaseMap(this.smartConfig),
                overrides = configMap
            )
            val newConfig = SmartGpsConfigFactory.fromMap(mergedSmartConfigMap)
            updateSmartConfiguration(newConfig)
            Log.d(TAG, "Configuration updated: profile=${newConfig.accuracyProfile}, strategy=${newConfig.updateStrategy}")

            // Update GPS accuracy threshold in GeofenceEngine if provided
            val gpsAccuracyThreshold = configMap["gpsAccuracyThreshold"] as? Number
            if (gpsAccuracyThreshold != null) {
                geofenceEngine.setGpsAccuracyThreshold(gpsAccuracyThreshold.toFloat())
                config.gpsAccuracyThreshold = gpsAccuracyThreshold.toFloat()
                Log.d(TAG, "GPS accuracy threshold updated to ${gpsAccuracyThreshold}m")
            }

            // Update dwell configuration if provided
            val dwellSettings = configMap["dwellSettings"] as? Map<String, Any>
            if (dwellSettings != null) {
                val dwellEnabled = dwellSettings["enabled"] as? Boolean ?: true
                val dwellThresholdMs = (dwellSettings["dwellThresholdMs"] as? Number)?.toLong()
                    ?: GeofenceEngine.DEFAULT_DWELL_THRESHOLD_MS
                geofenceEngine.setDwellConfig(dwellEnabled, dwellThresholdMs)
                Log.d(TAG, "Dwell config updated: enabled=$dwellEnabled, threshold=${dwellThresholdMs}ms")
            }

            // Update cluster configuration if provided. Use
            // GeofenceEngine.DEFAULT_CLUSTER_* constants for the
            // omitted-field fallbacks so the write-side defaults
            // match [buildDefaultConfigurationMap] and
            // [getClusterConfigMap] on the read side — single source
            // of truth. Hardcoded literals here would silently drift
            // from the constants over time.
            val clusterSettings = configMap["clusterSettings"] as? Map<String, Any>
            if (clusterSettings != null) {
                val clusterEnabled = clusterSettings["enabled"] as? Boolean ?: false
                val activeRadiusMeters = (clusterSettings["activeRadiusMeters"] as? Number)?.toDouble()
                    ?: GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS
                val refreshDistanceMeters = (clusterSettings["refreshDistanceMeters"] as? Number)?.toDouble()
                    ?: GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS
                geofenceEngine.setClusterConfig(clusterEnabled, activeRadiusMeters, refreshDistanceMeters)
                Log.d(TAG, "Cluster config updated: enabled=$clusterEnabled, activeRadius=${activeRadiusMeters}m, refreshDistance=${refreshDistanceMeters}m")
            }

            // Update schedule configuration if provided
            val scheduleSettings = configMap["scheduleSettings"] as? Map<String, Any>
            if (scheduleSettings != null) {
                setScheduleConfig(this, scheduleSettings)
                Log.d(TAG, "Schedule config updated from configuration")
            }

            // Update activity recognition configuration if provided
            val activitySettingsMap = configMap["activitySettings"] as? Map<String, Any>
            if (activitySettingsMap != null) {
                val newActivitySettings = ActivitySettings.fromMap(activitySettingsMap)
                updateActivityRecognition(newActivitySettings)
                Log.d(TAG, "Activity config updated: enabled=${newActivitySettings.enabled}")
            }

            // Apply `disableAlertNotifications` symmetrically with the
            // read side: the composed getConfiguration map emits it and
            // buildDefaultConfigurationMap includes it, so the write
            // side must honour it too — otherwise
            // updateConfiguration({disableAlertNotifications: true})
            // silently does nothing and resetConfiguration() can't
            // restore alerts. Routes through the same companion setter
            // Polyfence.initialize wires up.
            val disableAlertNotifications = configMap["disableAlertNotifications"] as? Boolean
            if (disableAlertNotifications != null) {
                setAlertNotificationsEnabled(!disableAlertNotifications)
                Log.d(TAG, "Alert notifications flag applied via updateConfiguration: enabled=${!disableAlertNotifications}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update configuration: ${e.message}")
            // Surface via PolyfenceErrorManager so consumers observe the
            // failure through onError and errorHistory records it for
            // post-hoc inspection. The Intent path is async and can't
            // reject the caller's promise directly, but the diagnostic
            // still reaches the consumer. End-to-end promise-rejection
            // consistency would require moving off the Intent pattern.
            PolyfenceErrorManager.reportError(
                "configuration_error",
                "Failed to apply updateConfiguration: ${e.message ?: e.javaClass.simpleName}",
                mapOf(
                    "severity" to "error",
                    "platform" to "android",
                    "timestamp" to System.currentTimeMillis()
                )
            )
        }
    }

    /**
     * Update activity recognition settings
     */
    private fun updateActivityRecognition(newSettings: ActivitySettings) {
        activitySettings = newSettings

        if (newSettings.enabled) {
            // Initialize manager if needed
            if (activityRecognitionManager == null) {
                activityRecognitionManager = ActivityRecognitionManager(this)
            }

            // Start activity recognition with callback
            activityRecognitionManager?.start(newSettings) { activity, confidence ->
                Log.i(TAG, "Activity changed: $activity (confidence: $confidence%)")
                currentActivity = activity
                // Record activity change in centralized telemetry
                telemetryAggregator.recordActivityChange(activity.name.lowercase())
                // Update GPS interval when activity changes
                if (isRunning) {
                    updateLocationRequest()
                }
            }
        } else {
            // Stop activity recognition
            activityRecognitionManager?.stop()
            currentActivity = ActivityType.UNKNOWN
        }
    }

    /**
     * Initialize smart configuration from static config
     */
    private fun initializeSmartConfiguration() {
        smartConfig = getCurrentSmartConfiguration()
    }

    /**
     * Update location request based on current smart configuration
     */
    private fun updateLocationRequest() {
        val priority = smartConfig.getLocationPriority()
        val interval = calculateCurrentInterval()

        // Defer distance filter until first location is received (same as startGpsUpdates)
        val distanceFilter = if (!hasReceivedFirstLocation) 0f else smartConfig.getDistanceFilter()

        val locationRequest = LocationRequest.Builder(priority, interval)
            .setMinUpdateIntervalMillis(interval / 2)
            .setMaxUpdateDelayMillis(interval * 2)
            .setWaitForAccurateLocation(smartConfig.shouldWaitForAccurateLocation())
            .setMinUpdateDistanceMeters(distanceFilter)
            .build()

        // Stop current location updates
        locationCallback?.let { callback ->
            fusedLocationClient?.removeLocationUpdates(callback)
        }

        // Start new location updates with new configuration
        try {
            fusedLocationClient?.requestLocationUpdates(
                locationRequest,
                locationCallback ?: createLocationCallback(),
                Looper.getMainLooper()
            )

            if (interval != currentGpsInterval) {
                accumulateIntervalTime(interval)
            }
            currentGpsInterval = interval
            Log.d(TAG, "Updated GPS: priority=$priority, interval=${interval}ms")

            // Emit status after GPS configuration changes
            emitRuntimeStatus()
        } catch (e: SecurityException) {
            Log.e(TAG, "Security exception updating location request: ${e.message}")
            PolyfenceErrorManager.reportError(
                "permission_revoked",
                "Location permission was revoked - SecurityException during GPS update",
                mapOf("platform" to "android", "error" to (e.message ?: ""), "timestamp" to System.currentTimeMillis())
            )
            errorRecovery.handlePermissionLoss()
            stopSelf()
        }
    }

    /**
     * Calculate current GPS interval based on smart configuration
     */
    private fun calculateCurrentInterval(): Long {
        return when (smartConfig.updateStrategy) {
            SmartGpsConfig.UpdateStrategy.CONTINUOUS -> smartConfig.getBaseUpdateInterval()
            SmartGpsConfig.UpdateStrategy.PROXIMITY_BASED -> calculateProximityBasedInterval()
            SmartGpsConfig.UpdateStrategy.MOVEMENT_BASED -> calculateMovementBasedInterval()
            SmartGpsConfig.UpdateStrategy.INTELLIGENT -> calculateIntelligentInterval()
        }
    }

    /**
     * Calculate interval based on proximity to zones
     */
    private fun calculateProximityBasedInterval(): Long {
        val proximitySettings = smartConfig.proximitySettings ?: return smartConfig.getBaseUpdateInterval()
        val lastLocation = lastKnownLocation ?: return smartConfig.getBaseUpdateInterval()

        // Calculate distance to nearest zone
        val nearestZoneDistance = calculateDistanceToNearestZone(lastLocation)

        return when {
            nearestZoneDistance <= proximitySettings.nearZoneThresholdMeters -> {
                Log.d(TAG, "Near zone (${nearestZoneDistance}m) - using high frequency")
                proximitySettings.nearZoneUpdateIntervalMs
            }
            nearestZoneDistance >= proximitySettings.farZoneThresholdMeters -> {
                Log.d(TAG, "Far from zones (${nearestZoneDistance}m) - using low frequency")
                proximitySettings.farZoneUpdateIntervalMs
            }
            else -> {
                // Medium distance - interpolate between near and far intervals
                val ratio = (nearestZoneDistance - proximitySettings.nearZoneThresholdMeters) /
                           (proximitySettings.farZoneThresholdMeters - proximitySettings.nearZoneThresholdMeters)

                val intervalDiff = proximitySettings.farZoneUpdateIntervalMs - proximitySettings.nearZoneUpdateIntervalMs
                val interpolatedInterval = proximitySettings.nearZoneUpdateIntervalMs + (ratio * intervalDiff).toLong()

                Log.d(TAG, "Medium distance (${nearestZoneDistance}m) - using interpolated interval: ${interpolatedInterval}ms")
                interpolatedInterval
            }
        }
    }

    /**
     * Calculate interval based on movement state
     */
    private fun calculateMovementBasedInterval(): Long {
        val movementSettings = smartConfig.movementSettings ?: return smartConfig.getBaseUpdateInterval()

        return if (isStationary) {
            movementSettings.stationaryUpdateIntervalMs
        } else {
            movementSettings.movingUpdateIntervalMs
        }
    }

    /**
     * Calculate interval using intelligent combination of factors.
     *
     * HIERARCHY (fixed):
     * - When near a zone AND moving → fast proximity interval (detect entry/exit quickly)
     * - When near a zone AND stationary → respect stationary interval (save battery at home)
     * - When far from all zones → use most battery-friendly interval
     */
    private fun calculateIntelligentInterval(): Long {
        val proximitySettings = smartConfig.proximitySettings
        val lastLocation = lastKnownLocation
        var proximityInterval: Long? = null

        // Check if we're near a zone
        if (proximitySettings != null && lastLocation != null) {
            val nearestZoneDistance = calculateDistanceToNearestZone(lastLocation)

            if (nearestZoneDistance <= proximitySettings.nearZoneThresholdMeters) {
                proximityInterval = calculateProximityBasedInterval()
                Log.d(TAG, "Near zone (${nearestZoneDistance}m) - proximity interval: ${proximityInterval}ms, isStationary=$isStationary")
            }
        }

        // Collect other strategy intervals
        val movementInterval = calculateMovementBasedInterval()
        val batteryInterval = calculateBatteryBasedInterval()
        val activityInterval = calculateActivityBasedInterval()

        // Near a zone AND stationary → respect stationary interval to save battery
        if (proximityInterval != null && isStationary) {
            val stationaryInterval = smartConfig.movementSettings?.stationaryUpdateIntervalMs ?: 120_000L
            val result = maxOf(proximityInterval, stationaryInterval)
            Log.d(TAG, "Near zone but stationary - using: ${result}ms (proximity=$proximityInterval, stationary=$stationaryInterval)")
            return result
        }

        // Near a zone AND moving → proximity wins (fast updates for entry/exit detection)
        if (proximityInterval != null) {
            return proximityInterval
        }

        // Far from zones → use the most battery-friendly (longest) interval
        val result = maxOf(movementInterval, batteryInterval, activityInterval)
        Log.d(TAG, "Far from zones - using longest interval: ${result}ms (movement=$movementInterval, battery=$batteryInterval, activity=$activityInterval)")
        return result
    }

    /**
     * Calculate interval based on detected activity type
     * Only applies when activity recognition is enabled
     */
    private fun calculateActivityBasedInterval(): Long {
        if (!activitySettings.enabled) {
            return smartConfig.getBaseUpdateInterval()
        }

        return activitySettings.getIntervalForActivity(currentActivity)
    }

    /**
     * Calculate interval based on battery level
     */
    private fun calculateBatteryBasedInterval(): Long {
        val batterySettings = smartConfig.batterySettings ?: return smartConfig.getBaseUpdateInterval()

        try {
            val batteryManager = getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
            val batteryLevel = batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)

            return when {
                batteryLevel <= batterySettings.criticalBatteryThreshold && batterySettings.pauseOnCriticalBattery ->
                    Long.MAX_VALUE // Pause GPS
                batteryLevel <= batterySettings.lowBatteryThreshold ->
                    batterySettings.lowBatteryUpdateIntervalMs
                else -> smartConfig.getBaseUpdateInterval()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to get battery level: ${e.message}")
            return smartConfig.getBaseUpdateInterval()
        }
    }

    /**
     * Calculate distance to nearest zone
     */
    private fun calculateDistanceToNearestZone(location: android.location.Location): Double {
        try {
            // Get current zones from GeofenceEngine
            val zones = geofenceEngine.getCurrentZones()
            if (zones.isEmpty()) {
                return Double.MAX_VALUE // No zones configured
            }

            var nearestDistance = Double.MAX_VALUE

            for (zone in zones) {
                val distance = when {
                    zone.isCircle -> calculateDistanceToCircleZone(location, zone)
                    zone.isPolygon -> calculateDistanceToPolygonZone(location, zone)
                    else -> Double.MAX_VALUE
                }

                if (distance < nearestDistance) {
                    nearestDistance = distance
                }
            }

            Log.d(TAG, "Nearest zone distance: ${nearestDistance}m")
            return nearestDistance

        } catch (e: Exception) {
            Log.e(TAG, "Error calculating zone distance: ${e.message}")
            return Double.MAX_VALUE // Fallback to no optimization
        }
    }

    /**
     * Calculate distance to circle zone boundary
     */
    private fun calculateDistanceToCircleZone(
        location: android.location.Location,
        zone: GeofenceEngine.Zone
    ): Double {
        val center = zone.center ?: return Double.MAX_VALUE
        val radius = zone.radius ?: return Double.MAX_VALUE

        val centerLocation = android.location.Location("").apply {
            latitude = center.latitude
            longitude = center.longitude
        }

        val distanceToCenter = location.distanceTo(centerLocation).toDouble()

        // Distance to zone boundary (0 if inside zone)
        return maxOf(0.0, distanceToCenter - radius)
    }

    /**
     * Calculate distance to polygon zone boundary
     */
    private fun calculateDistanceToPolygonZone(
        location: android.location.Location,
        zone: GeofenceEngine.Zone
    ): Double {
        val currentPoint = GeoMath.LatLng(location.latitude, location.longitude)
        val points = zone.points

        if (points.isEmpty()) return Double.MAX_VALUE

        val geoVertices = points.map { GeoMath.LatLng(it.latitude, it.longitude) }

        // Check if inside polygon first
        if (GeoMath.isPointInPolygon(currentPoint, geoVertices)) {
            return 0.0 // Inside zone
        }

        // Calculate distance to nearest polygon edge
        var nearestDistance = Double.MAX_VALUE

        for (i in geoVertices.indices) {
            val p1 = geoVertices[i]
            val p2 = geoVertices[(i + 1) % geoVertices.size]

            val distance = GeoMath.pointToSegmentDistance(currentPoint, p1, p2)
            if (distance < nearestDistance) {
                nearestDistance = distance
            }
        }

        return nearestDistance
    }



    /**
     * Log proximity debug information for testing
     */
    private fun logProximityDebugInfo(location: android.location.Location) {
        if (smartConfig.enableDebugLogging) {
            val distance = calculateDistanceToNearestZone(location)
            val interval = calculateProximityBasedInterval()

            Log.i(TAG, """
                Proximity Debug:
                - Distance to nearest zone: ${distance}m
                - GPS interval: ${interval}ms
                - Update strategy: ${smartConfig.updateStrategy}
                - Zones count: ${geofenceEngine.getZoneCount()}
            """.trimIndent())
        }
    }

    // --- ML Telemetry Methods ---

    /**
     * Accumulate time spent at the previous GPS interval before switching.
     */
    private fun accumulateIntervalTime(newInterval: Long) {
        val now = System.currentTimeMillis()
        val elapsed = now - lastIntervalChangeTime
        if (elapsed > 0) {
            intervalTimeMs[lastTrackedInterval] = (intervalTimeMs[lastTrackedInterval] ?: 0L) + elapsed
        }
        lastIntervalChangeTime = now
        lastTrackedInterval = newInterval
        totalIntervalMs += newInterval
        intervalSampleCount++
    }

    /**
     * Track stationary state transitions for telemetry.
     */
    private fun updateStationaryTracking(nowStationary: Boolean) {
        if (nowStationary && stationaryStartTime == null) {
            stationaryStartTime = System.currentTimeMillis()
        } else if (!nowStationary && stationaryStartTime != null) {
            cumulativeStationaryMs += System.currentTimeMillis() - stationaryStartTime!!
            stationaryStartTime = null
        }
    }

    /**
     * Returns GPS interval distribution as proportions (0.0-1.0).
     */
    fun getGpsIntervalDistribution(): Map<String, Double> {
        // Finalize current interval segment
        val now = System.currentTimeMillis()
        val elapsed = now - lastIntervalChangeTime
        val snapshot = HashMap(intervalTimeMs)
        snapshot[lastTrackedInterval] = (snapshot[lastTrackedInterval] ?: 0L) + elapsed

        val total = snapshot.values.sum().toDouble()
        if (total <= 0) return emptyMap()
        return snapshot.mapKeys { (k, _) -> k.toString() }.mapValues { (_, ms) -> ms / total }
    }

    /**
     * Returns ratio of time spent stationary (0.0-1.0).
     */
    fun getStationaryRatio(): Double {
        val sessionDurationMs = System.currentTimeMillis() - trackingStartTime
        if (sessionDurationMs <= 0) return 0.0
        var total = cumulativeStationaryMs
        if (stationaryStartTime != null) {
            total += System.currentTimeMillis() - stationaryStartTime!!
        }
        return total.toDouble() / sessionDurationMs
    }

    /**
     * Returns average GPS interval in milliseconds.
     */
    fun getAvgGpsIntervalMs(): Int {
        return if (intervalSampleCount > 0) (totalIntervalMs / intervalSampleCount).toInt() else 0
    }

    /**
     * Reset telemetry counters for a new session.
     */
    fun resetTelemetry() {
        intervalTimeMs.clear()
        lastIntervalChangeTime = System.currentTimeMillis()
        lastTrackedInterval = currentGpsInterval
        totalIntervalMs = 0L
        intervalSampleCount = 0
        cumulativeStationaryMs = 0L
        stationaryStartTime = null
        trackingStartTime = System.currentTimeMillis()
        telemetryAggregator.resetTelemetry()
        // Re-anchor the battery snapshot to the new session-start clock —
        // telemetryAggregator.resetTelemetry() just restarted sessionStartTime
        // and nulled batteryLevelStart on the aggregator. Without refreshing
        // here, the next getSessionTelemetry() call would pair a stale start
        // (from onCreate) with a fresh end over the new (typically shorter)
        // session duration → meaningless drain.
        captureBatterySessionStart()
    }

    /**
     * Update movement state based on location changes.
     *
     * Stationary detection always runs using sensible defaults, even when
     * movementSettings is null. This ensures isStationary is always accurate,
     * which is critical for INTELLIGENT strategy and callback throttling.
     */
    private fun updateMovementState(location: android.location.Location) {
        lastKnownLocation = location
        val currentTime = System.currentTimeMillis()
        val movementSettings = smartConfig.movementSettings

        // Always compute stationary state — use defaults when movementSettings is null
        val moveThreshold = movementSettings?.movementThresholdMeters?.toFloat() ?: 50.0f
        val timeThreshold = movementSettings?.stationaryThresholdMs ?: 300_000L

        // Distance from last significant movement position (not from lastKnownLocation,
        // which was just overwritten above — comparing to itself would always yield 0)
        val distance = lastMovementLocation?.let { location.distanceTo(it) } ?: Float.MAX_VALUE

        if (distance > moveThreshold) {
            // Significant movement detected — update movement anchor
            lastMovementLocation = location
            lastMovementTime = currentTime
            if (isStationary) {
                isStationary = false
                updateStationaryTracking(false)
                Log.d(TAG, "Device started moving (moved ${String.format("%.1f", distance)}m)")
                updateLocationRequest()
                emitRuntimeStatus()
            }
        } else if (lastMovementTime > 0 && currentTime - lastMovementTime >= timeThreshold) {
            // No significant movement for threshold duration
            if (!isStationary) {
                isStationary = true
                updateStationaryTracking(true)
                Log.d(TAG, "Device is now stationary (no movement > ${moveThreshold}m in ${timeThreshold / 1000}s)")
                updateLocationRequest()
                emitRuntimeStatus()
            }
        }

        // Initialize movement tracking on first location
        if (lastMovementLocation == null) {
            lastMovementLocation = location
            lastMovementTime = currentTime
        }

        lastLocationTime = currentTime
    }

    /**
     * Create location callback for smart GPS configuration
     */
    private fun createLocationCallback(): LocationCallback {
        return object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                locationResult.lastLocation?.let { location ->
                    // Guard clause: only process if tracking is active
                    if (!isRunning) {
                        return
                    }

                    // Update movement state for smart GPS
                    updateMovementState(location)

                    // Update health tracking
                    lastLocationTime = System.currentTimeMillis()
                    consecutiveGpsFailures = 0

                    // Process location with geofence engine
                    geofenceEngine.checkLocation(location)

                    // Send location update to delegate
                    sendLocationToDelegate(location)

                    // Emit status periodically
                    emitRuntimeStatus()
                }
            }

            override fun onLocationAvailability(locationAvailability: LocationAvailability) {
                if (!locationAvailability.isLocationAvailable) {
                    Log.w(TAG, "Location availability lost")
                    consecutiveGpsFailures++

                    if (consecutiveGpsFailures >= 3) {
                        errorRecovery.handleGpsFailure()
                    }
                }
            }
        }
    }

    // ============================================================================
    // BATTERY LEVEL DETECTION
    // ============================================================================

    /**
     * Get current battery level percentage, always in [0, 100].
     *
     * BatteryManager.BATTERY_PROPERTY_CAPACITY is documented to return
     * Integer.MIN_VALUE when no battery is present / read fails / property
     * unsupported. Without a range clamp those sentinel values flow into
     * telemetry as massive negative drain (start=-2147483648 paired with
     * end=42 over 30 minutes blows past the SaaS clamp). Coerce to the
     * exception-path default (100) for any out-of-range value so the
     * fallback shape matches.
     */
    private fun getBatteryLevel(): Int {
        return try {
            val batteryManager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            val level = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            if (level in 0..100) level else 100
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get battery level: ${e.message}")
            100 // Default to full battery on error
        }
    }

    /**
     * Whether the device is currently charging (USB, AC, wireless, or full).
     * Used for the chargingDuringSession telemetry flag — when true at either
     * session-start or session-end, the SaaS knows the measured drain isn't
     * a useful proxy for battery cost.
     */
    private fun isCurrentlyCharging(): Boolean {
        return try {
            val batteryManager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            batteryManager.isCharging
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read charging state: ${e.message}")
            false
        }
    }

    /**
     * Refresh the battery start-snapshot for a new telemetry session.
     * Called from onCreate() for the first session and from resetTelemetry()
     * for every subsequent session — without the resetTelemetry path, the
     * start value goes stale after the first session while the aggregator's
     * sessionStartTime restarts, producing a meaningless drain rate over
     * sessions 2..N.
     */
    private fun captureBatterySessionStart() {
        batterySnapshotAtStart = getBatteryLevel().toDouble()
        chargingAtStart = isCurrentlyCharging()
    }

    /**
     * Get current battery mode based on level and settings
     */
    private fun getCurrentBatteryMode(): String {
        val batteryLevel = getBatteryLevel()
        val batterySettings = smartConfig.batterySettings ?: return "normal"

        return when {
            batteryLevel <= batterySettings.criticalBatteryThreshold -> "critical"
            batteryLevel <= batterySettings.lowBatteryThreshold -> "low"
            else -> "normal"
        }
    }

    // ============================================================================
    // RUNTIME STATUS EMISSION
    // ============================================================================

    /**
     * Emit runtime status via delegate performance stream
     */
    private fun emitRuntimeStatus() {
        val location = lastKnownLocation ?: return
        val currentTime = System.currentTimeMillis()

        // Calculate seconds since last GPS fix
        val secondsSinceLastFix = if (lastLocationTime > 0) {
            ((currentTime - lastLocationTime) / 1000).toInt()
        } else {
            0
        }

        // Map allows null values so every emission carries the same key
        // set — consumers can rely on a stable shape rather than checking
        // for absent vs present keys across emissions.
        val status = mutableMapOf<String, Any?>(
            "strategy" to smartConfig.updateStrategy.name,
            "intervalMs" to currentGpsInterval,
            "accuracyProfile" to smartConfig.accuracyProfile.name,
            "nearestZoneDistanceM" to calculateDistanceToNearestZone(location),
            "isStationary" to isStationary,
            "batteryMode" to getCurrentBatteryMode(),
            "gpsAccuracy" to location.accuracy,
            "timestamp" to currentTime,
            // New GPS health fields
            "secondsSinceLastGpsFix" to secondsSinceLastFix,
            "gpsAvailabilityDrops5Min" to getGpsAvailabilityDrops5Min(),
            // Always present — null until the first GPS fix.
            "currentGpsAccuracy" to currentGpsAccuracy?.toDouble()
        )

        // Only emit if status changed or 30 seconds elapsed
        val timeSinceLastEmit = currentTime - lastStatusEmitTime
        if (status != lastEmittedStatus || timeSinceLastEmit >= 30000) {
            // Send via delegate performance event
            coreDelegate?.onPerformanceEvent(mapOf(
                "type" to "runtime_status",
                "data" to status
            ))
            lastEmittedStatus = status
            lastStatusEmitTime = currentTime
            Log.d(TAG, "Runtime status emitted: $status")
        }
    }
}

/**
 * Deep-merge two configuration maps. Keys present in [overrides] win.
 * When both sides have a Map value for the same key, that nested map
 * is merged recursively (one level is enough for the SmartGpsConfig
 * shape — proximitySettings / movementSettings / batterySettings are
 * the only nested objects and they're flat scalars inside).
 *
 * Used by [LocationTracker.updateConfigurationFromMap] to preserve
 * unspecified fields across partial updateConfiguration() calls.
 */
private fun deepMergeMaps(
    base: Map<String, Any>,
    overrides: Map<String, Any>
): Map<String, Any> {
    val result = base.toMutableMap()
    for ((key, value) in overrides) {
        val existing = result[key]
        @Suppress("UNCHECKED_CAST")
        result[key] = if (existing is Map<*, *> && value is Map<*, *>) {
            deepMergeMaps(existing as Map<String, Any>, value as Map<String, Any>)
        } else {
            value
        }
    }
    return result
}

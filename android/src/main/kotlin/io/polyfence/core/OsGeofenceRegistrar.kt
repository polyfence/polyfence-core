package io.polyfence.core

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import io.polyfence.core.utils.GeoMath
import io.polyfence.core.utils.PolyfenceConfig
import kotlin.math.max

/**
 * Registers the nearest active zones with Google Play Services geofencing as an
 * OS-managed wake source. The library's own polling engine remains the primary
 * detector — the OS registration only exists so that after full process kill,
 * an OS transition can wake the app long enough to enqueue the crossing into
 * the pending-events queue for drain on next tracker boot.
 *
 * Off unless [PolyfenceConfig.osGeofenceWakeEnabled] is true. When on:
 *  - **Holds OS slots only while the app is backgrounded.** OS fences matter
 *    solely when the app is not running; while it is foregrounded the
 *    in-process engine is doing the detection anyway, so every slot is released
 *    back to the consumer, who shares the same per-app platform allocation.
 *    Registration therefore happens on the background transition and is undone
 *    on the foreground transition.
 *  - Selects up to [maxRegions] zones by centroid distance from the last-known
 *    fix, clamped to [PolyfenceConfig.DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS].
 *  - Registers via [GeofencingClient.addGeofences] with `INITIAL_TRIGGER_ENTER`
 *    only, so a user already inside a zone still receives a starting-state
 *    event. The EXIT bit is deliberately absent: it would make Play Services
 *    replay an EXIT for every fence the device is currently outside of, which
 *    is nearly all of them.
 *  - Re-registers when the zone set changes (debounced by [DEBOUNCE_MS] to
 *    absorb rapid zone churn) or when the user moves more than
 *    [MOVEMENT_RECALC_METERS] from the fix that seeded the current selection.
 *  - Emits `os_geofence_permission_denied` via `onError` (severity warning) and
 *    marks the health field with `registered=0` if ACCESS_BACKGROUND_LOCATION
 *    is missing; the in-process polling engine keeps working unchanged and
 *    the consumer app decides whether to prompt.
 *
 * Selection is purely distance-based. Weighting zones by heading — preferring
 * what is ahead of the direction of travel over what has already been passed —
 * would cover a driving corridor better for the same slot count, but heading is
 * noisy at low speed and undefined when stationary, so it is deliberately not
 * part of this selection.
 *
 * Registering on the background transition leaves a window of roughly a second
 * during which the fences are not yet armed. A process killed inside that
 * window loses wake coverage for that session. The window is inherent to
 * registering lazily and is accepted in exchange for holding zero slots while
 * the app is alive.
 *
 * Not thread-safe against external mutation — callers dispatch onto the main
 * looper handler [requestRefresh] posts its debounced work to.
 */
internal class OsGeofenceRegistrar(
    private val context: Context,
    private val geofencingClient: GeofencingClient =
        LocationServices.getGeofencingClient(context.applicationContext),
    requestedMaxRegions: Int = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
) {

    /**
     * Effective slot budget. Clamped into
     * `1..DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS` — Play Services rejects the
     * whole request when it exceeds the platform cap, so silently honouring an
     * over-large value would mean registering nothing at all.
     */
    private val maxRegions: Int = clampMaxRegions(requestedMaxRegions)

    /**
     * Snapshot of the last registration attempt — exposed via
     * [PolyfenceDebugCollector]'s `systemStatus.osGeofenceRegistrationHealth`
     * so a consumer surface can observe OS-cap hits and permission drift.
     * `null` before the first attempt; `registered=0 lastError=...` when a
     * registration was requested but the OS refused.
     */
    @Volatile
    var health: Health? = null
        private set

    /**
     * Fix that seeded the last registration. Movement-triggered recalcs
     * compare against this so a stationary GPS with jittery accuracy
     * doesn't churn the OS geofence set.
     */
    @Volatile
    private var lastRegistrationLocation: Location? = null

    private val handler = Handler(Looper.getMainLooper())
    private val debounceRunnable = Runnable { refreshRegistrationInternal() }


    @Volatile
    private var shutdownRequested = false

    @Volatile
    private var lastPermissionErrorAt: Long = 0L

    /**
     * Incremented on every registration attempt and on every release, so an
     * asynchronous Play Services callback can tell whether the attempt it
     * belongs to is still the current one.
     */
    @Volatile
    private var registrationGeneration: Int = 0

    /**
     * Request IDs currently handed to the OS. `addGeofences` replaces by ID, so
     * without this the set could only ever grow — anything dropped from a later
     * nearest-N selection would stay armed indefinitely.
     */
    @Volatile
    private var registeredZoneIds: Set<String> = emptySet()

    /**
     * Whether the consumer app currently has UI in the foreground. Slots are
     * held only while this is false. Starts from a one-shot process-importance
     * read so a registrar constructed after the app is already visible does not
     * mistake "no lifecycle callback seen yet" for "backgrounded".
     */
    @Volatile
    private var appInForeground: Boolean = isProcessInForeground(context)

    private var lifecycleMonitor: AppForegroundMonitor? = null

    /**
     * Begin tracking the consumer app's foreground/background transitions.
     * Registration is driven entirely by these: nothing is handed to the OS
     * until the app backgrounds, and everything is handed back when it returns.
     */
    fun startObservingAppLifecycle() {
        if (lifecycleMonitor != null) return
        val application = context.applicationContext as? android.app.Application ?: return
        lifecycleMonitor = AppForegroundMonitor(
            handler = handler,
            startedForegrounded = appInForeground,
            onForeground = { onAppForegrounded() },
            onBackground = { onAppBackgrounded() }
        ).also { application.registerActivityLifecycleCallbacks(it) }
    }

    /**
     * Release every slot Polyfence holds. Called when the app comes back to the
     * foreground: the in-process engine is detecting again, so the consumer
     * gets the whole platform allocation back for its own geofences.
     */
    fun onAppForegrounded() {
        appInForeground = true
        registrationGeneration++
        handler.removeCallbacks(debounceRunnable)
        removeAllOsGeofences()
        registeredZoneIds = emptySet()
        // Zero registered is the accurate reading here — it is a deliberate
        // release, not a failure, so lastError stays null.
        health = Health(requested = 0, registered = 0, lastError = null)
    }

    /** Arm the wake fences — the app is no longer detecting in-process. */
    fun onAppBackgrounded() {
        appInForeground = false
        requestRefresh()
    }

    /**
     * Ask the OS to re-evaluate the nearest-N set. Debounced by [DEBOUNCE_MS] —
     * repeated calls within the window coalesce into one registration attempt.
     * A no-op while the app is foregrounded, where holding slots would take
     * platform allocation from the consumer for no benefit. Safe to call from
     * any thread.
     */
    fun requestRefresh() {
        if (shutdownRequested || appInForeground) return
        handler.removeCallbacks(debounceRunnable)
        handler.postDelayed(debounceRunnable, DEBOUNCE_MS)
    }

    /**
     * Notify the registrar of a fresh location fix. Triggers a recalc only if
     * the user has moved [MOVEMENT_RECALC_METERS] from the fix that seeded
     * the last registration — below that, the currently registered set is
     * still the nearest and re-registering would only burn OS quota.
     */
    fun onLocationUpdate(location: Location) {
        if (shutdownRequested || appInForeground) return
        val seed = lastRegistrationLocation
        if (seed == null) {
            requestRefresh()
            return
        }
        val moved = GeoMath.haversineDistance(
            seed.latitude, seed.longitude,
            location.latitude, location.longitude
        )
        if (moved >= MOVEMENT_RECALC_METERS) {
            requestRefresh()
        }
    }

    /**
     * Remove any currently-registered OS geofences and stop accepting refresh
     * requests. Safe to call multiple times. Called from
     * [LocationTracker.onDestroy] and when the consumer flips
     * `osGeofenceWakeEnabled` back to false.
     */
    fun shutdown() {
        shutdownRequested = true
        // Supersede any in-flight registration so its success callback cannot
        // resurrect health, or leave the caller believing fences are armed,
        // after teardown.
        registrationGeneration++
        handler.removeCallbacks(debounceRunnable)
        lifecycleMonitor?.let { monitor ->
            (context.applicationContext as? android.app.Application)
                ?.unregisterActivityLifecycleCallbacks(monitor)
        }
        lifecycleMonitor = null
        removeAllOsGeofences()
        registeredZoneIds = emptySet()
        health = null
        lastRegistrationLocation = null
    }

    /**
     * Test seam — bypasses the debounce timer and invokes the registration
     * pipeline synchronously against the supplied zones + fix. Internal so
     * `@testable` Robolectric tests can reach it.
     */
    internal fun refreshNowForTest(zones: List<GeofenceEngine.Zone>, seed: Location?): Int =
        applyRegistration(zones, seed)

    /** Effective slot budget after clamping. Read by tests and by the health field. */
    internal fun effectiveMaxRegions(): Int = maxRegions

    private fun refreshRegistrationInternal() {
        // Re-checked here, not only in requestRefresh: the request can be made
        // from a bridge thread, so a foreground transition can land on the main
        // looper after the guard there passed but before this runs — and the
        // fences it would register have no later release, because release only
        // happens on the next foreground transition.
        if (shutdownRequested || appInForeground) return
        val tracker = LocationTracker.currentInstanceForOsGeofence
        val zones = tracker?.geofenceEngineForOsGeofence?.getCurrentZones().orEmpty()
        val seed = tracker?.lastKnownLocationForOsGeofence ?: lastRegistrationLocation
        applyRegistration(zones, seed)

    }

    // Permissions are verified by hasBackgroundLocationPermission() a few lines
    // in, and a SecurityException from the OS is caught below; lint cannot see
    // through the helper to the guard.
    /**
     * Returns how many fences were handed to the OS, synchronously. The health
     * field cannot answer that for a caller: it is finalised in the
     * `addGeofences` success listener, which lands on the main looper after
     * this returns, so a caller reading it back would always see the previous
     * value.
     */
    @SuppressLint("MissingPermission")
    private fun applyRegistration(
        zones: List<GeofenceEngine.Zone>,
        seed: Location?,
        onSettled: ((Boolean) -> Unit)? = null
    ): Int {
        // Advance the movement anchor on every ATTEMPT, not only on success.
        // Anchoring on success alone leaves it null whenever registration keeps
        // failing (permission denied, no zones, OS refusal), and a null anchor
        // makes onLocationUpdate treat every fix as "moved far enough" — one
        // retry and one onError per GPS fix, for as long as the failure lasts.
        lastRegistrationLocation = seed

        val candidates = selectTopNNearest(zones, seed, maxRegions)
        if (!hasBackgroundLocationPermission(context)) {
            reportPermissionDenied(zones.size)
            return 0
        }

        if (candidates.isEmpty()) {
            removeAllOsGeofences()
            health = Health(requested = zones.size, registered = 0, lastError = null)
            return 0
        }

        val fences = candidates.map { it.toOsGeofence() }
        // ENTER only. INITIAL_TRIGGER_EXIT makes Play Services fire an EXIT at
        // registration time for every fence the device is currently outside —
        // which is nearly all of them — so each registration pass would inject
        // a burst of transitions for zones that were never entered, evicting
        // genuine queued crossings to make room. The ENTER bit alone delivers
        // the intent: a user already standing inside a zone still gets a
        // starting-state event.
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofences(fences)
            .build()

        val pendingIntent = buildPendingIntent()

        // Re-check immediately before handing the set to the OS: a shutdown
        // that landed while this refresh was queued would otherwise remove the
        // fences and then have them immediately re-armed here, orphaning
        // registrations that outlive the registrar.
        if (shutdownRequested) return 0

        // Play Services resolves the request asynchronously on the main looper.
        // A release that happens in between (the user reopening the app) must
        // win, so each attempt stamps a generation and a late listener whose
        // generation has been superseded updates nothing — otherwise health
        // would report N regions monitored moments after all N were removed.
        val generation = ++registrationGeneration

        // addGeofences replaces by request ID only, so a zone that drops out of
        // the nearest-N set — on movement recalc or removal — would stay armed
        // for the life of the install. Explicitly retire what is no longer
        // selected before adding, matching the iOS registrar's full sweep.
        val newIds = candidates.map { it.zoneId }.toSet()
        val staleIds = registeredZoneIds - newIds
        if (staleIds.isNotEmpty()) {
            try {
                geofencingClient.removeGeofences(staleIds.toList())
            } catch (e: Exception) {
                Log.w(TAG, "Failed to retire stale OS geofences: ${e.message}")
            }
        }
        registeredZoneIds = newIds

        try {
            geofencingClient.addGeofences(request, pendingIntent)
                .addOnSuccessListener {
                    if (generation == registrationGeneration) {
                        health = Health(
                            requested = zones.size,
                            registered = candidates.size,
                            lastError = null
                        )
                    }
                    onSettled?.invoke(true)
                }
                .addOnFailureListener { e ->
                    val msg = e.message ?: e::class.java.simpleName
                    Log.w(TAG, "OS geofence registration failed: $msg")
                    if (generation == registrationGeneration) {
                        health = Health(
                            requested = zones.size,
                            registered = 0,
                            lastError = msg
                        )
                    }
                    onSettled?.invoke(false)
                    PolyfenceErrorManager.reportError(
                        type = "os_geofence_registration_failed",
                        message = "OS refused geofence registration: $msg",
                        context = mapOf(
                            "severity" to "warning",
                            "platform" to "android",
                            "requested" to zones.size,
                            "topN" to candidates.size
                        )
                    )
                }
        } catch (e: SecurityException) {
            reportPermissionDenied(zones.size)
            onSettled?.invoke(false)
            return 0
        }
        return candidates.size
    }

    private fun removeAllOsGeofences() {
        // Best-effort: this runs on teardown and on the flag-off transition,
        // where the caller has nothing useful to do with a failure and an
        // escaping exception would take down an unrelated lifecycle callback.
        try {
            geofencingClient.removeGeofences(buildPendingIntent())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove OS geofences: ${e.message}")
        }
    }

    private fun reportPermissionDenied(requested: Int) {
        health = Health(
            requested = requested,
            registered = 0,
            lastError = ERROR_BACKGROUND_LOCATION_DENIED
        )
        // Rate-limited: the registrar retries on zone changes and on movement,
        // so an un-throttled report would push one onError per GPS fix for as
        // long as the grant is missing, evicting every genuine entry from the
        // consumer's bounded error history.
        val now = System.currentTimeMillis()
        if (now - lastPermissionErrorAt < PERMISSION_ERROR_COOLDOWN_MS) return
        lastPermissionErrorAt = now

        PolyfenceErrorManager.reportError(
            type = "os_geofence_permission_denied",
            message = "ACCESS_BACKGROUND_LOCATION not granted — OS wake fences unavailable",
            context = mapOf(
                "severity" to "warning",
                "platform" to "android",
                "requested" to requested
            )
        )
    }

    private fun buildPendingIntent(): PendingIntent {
        val intent = Intent(context, PolyfenceGeofenceBroadcastReceiver::class.java)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(
            context.applicationContext,
            PENDING_INTENT_REQUEST_CODE,
            intent,
            flags
        )
    }

    private fun hasBackgroundLocationPermission(ctx: Context): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            ctx, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            ctx, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(
                ctx, Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        } else true
    }

    /**
     * Snapshot of the last registration attempt. Exposed as a plain map inside
     * `systemStatus.osGeofenceRegistrationHealth` so consumer surfaces can
     * observe cap-hits and permission drift without importing an SDK type.
     */
    data class Health(
        val requested: Int,
        val registered: Int,
        val lastError: String?
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "requested" to requested,
            "registered" to registered,
            "lastError" to lastError
        )
    }

    /**
     * Tracks whether any of the consumer app's activities is started, which is
     * what "the app is in the foreground" means for slot-holding purposes.
     *
     * A raw started-activity counter transiently hits zero on a configuration
     * change (rotation destroys and recreates the activity) and on any
     * activity-to-activity navigation, which would register and immediately
     * unregister the whole fence set. The background transition is therefore
     * held behind [BACKGROUND_SETTLE_MS] and cancelled if another activity
     * starts first; the foreground transition fires immediately because
     * releasing slots early is always safe.
     *
     * Implemented directly rather than via `ProcessLifecycleOwner` so consumers
     * do not inherit an `androidx.lifecycle:lifecycle-process` dependency they
     * did not ask for.
     */
    internal class AppForegroundMonitor(
        private val handler: Handler,
        startedForegrounded: Boolean,
        private val onForeground: () -> Unit,
        private val onBackground: () -> Unit
    ) : android.app.Application.ActivityLifecycleCallbacks {

        private var startedActivities = 0

        /**
         * Seeded from the caller's process-importance probe rather than from
         * `false`. `registerActivityLifecycleCallbacks` does not replay past
         * callbacks, so a monitor attached while an activity is already started
         * never sees its `onActivityStarted`. Starting this at `false` would
         * make the first `onActivityStopped` fail the settle guard below, and
         * the very first background transition — the one that arms wake fences
         * for the session most likely to be killed — would never be reported.
         */
        private var reportedForeground = startedForegrounded

        private val settleRunnable = Runnable {
            if (startedActivities == 0 && reportedForeground) {
                reportedForeground = false
                onBackground()
            }
        }

        override fun onActivityStarted(activity: android.app.Activity) {
            handler.removeCallbacks(settleRunnable)
            startedActivities++
            if (!reportedForeground) {
                reportedForeground = true
                onForeground()
            }
        }

        override fun onActivityStopped(activity: android.app.Activity) {
            startedActivities = (startedActivities - 1).coerceAtLeast(0)
            if (startedActivities == 0) {
                handler.removeCallbacks(settleRunnable)
                handler.postDelayed(settleRunnable, BACKGROUND_SETTLE_MS)
            }
        }

        override fun onActivityCreated(
            activity: android.app.Activity,
            savedInstanceState: android.os.Bundle?
        ) {}
        override fun onActivityResumed(activity: android.app.Activity) {}
        override fun onActivityPaused(activity: android.app.Activity) {}
        override fun onActivitySaveInstanceState(
            activity: android.app.Activity,
            outState: android.os.Bundle
        ) {}
        override fun onActivityDestroyed(activity: android.app.Activity) {}
    }

    /**
     * Pure-function selection result — public to internal tests so the
     * nearest-N algorithm can be unit-tested without a `GeofencingClient`.
     */
    internal data class Candidate(
        val zoneId: String,
        val centerLat: Double,
        val centerLng: Double,
        val radiusMeters: Double,
        val distanceMeters: Double
    ) {
        fun toOsGeofence(): Geofence =
            Geofence.Builder()
                .setRequestId(zoneId)
                .setCircularRegion(centerLat, centerLng, radiusMeters.toFloat())
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(
                    Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT
                )
                .build()
    }

    companion object {
        private const val TAG = "OsGeofenceRegistrar"

        /**
         * Coalesce zone-set churn — a bridge that adds N zones in a tight loop
         * on startup should produce one re-registration, not N. Window matches
         * the iOS registrar for parity.
         */
        const val DEBOUNCE_MS = 200L

        /**
         * Grace period before a zero-started-activity state counts as
         * backgrounded. Covers configuration changes and activity-to-activity
         * navigation, both of which momentarily leave no activity started.
         */
        const val BACKGROUND_SETTLE_MS = 700L

        /**
         * Recompute the top-N-nearest set only after the user moves this far
         * from the fix that seeded the last registration. Below this threshold
         * the previously-registered set is still the nearest N. Chosen for the
         * ULEZ / CCZ driving case: at motorway speed this fires roughly every
         * 40 s, matching cellular-A-GPS re-lock cadence — dense enough to keep
         * the perimeter ahead current, sparse enough to avoid registration
         * churn from GPS jitter while stationary.
         */
        const val MOVEMENT_RECALC_METERS = 1000.0

        /**
         * `PendingIntent` request code for the geofence transition intent. A
         * single stable code across process lifetimes lets `addGeofences`
         * mutation calls replace the previously-registered set atomically
         * (same PendingIntent → same delivery target).
         */
        internal const val PENDING_INTENT_REQUEST_CODE = 34_651_907

        /**
         * Health `lastError` marker for a missing background-location grant.
         * Same wire string as the iOS registrar so one consumer branch covers
         * both platforms.
         */
        const val ERROR_BACKGROUND_LOCATION_DENIED = "background_location_denied"

        /**
         * Clamps a consumer-supplied slot budget into the range the platform
         * will actually honour. Play Services rejects an `addGeofences` request
         * that exceeds its per-app cap outright, so passing an over-large value
         * straight through would register nothing rather than register more.
         */
        internal fun clampMaxRegions(requested: Int): Int {
            val clamped = PolyfenceConfig.clampOsGeofenceMaxRegions(requested)
            if (clamped != requested) {
                Log.w(TAG, "osGeofenceMaxRegions=$requested is out of range; using $clamped")
            }
            return clamped
        }

        /**
         * One-shot read of whether this process currently has UI in the
         * foreground. `IMPORTANCE_FOREGROUND` means a visible activity;
         * a running foreground service reports the weaker
         * `IMPORTANCE_FOREGROUND_SERVICE`, which is exactly the state where
         * wake fences should be armed, so the stricter comparison is correct.
         */
        internal fun isProcessInForeground(context: Context): Boolean {
            return try {
                val info = android.app.ActivityManager.RunningAppProcessInfo()
                android.app.ActivityManager.getMyMemoryState(info)
                info.importance <=
                    android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            } catch (e: Exception) {
                // Unknown importance: assume backgrounded so wake coverage is
                // armed. Over-registering is recoverable; silently never
                // registering is the failure this feature exists to prevent.
                false
            }
        }

        /**
         * Re-arms wake fences from persisted state, with no running tracker to
         * read zones from. Used after device reboot, where Play Services has
         * dropped every registration and the app is not running.
         *
         * Returns the number of zones handed to the OS, or 0 when the feature
         * was off at last shutdown, no zones are persisted, or the grant is
         * missing.
         *
         * Selection is seeded from the platform's last known fix rather than a
         * live one — no GPS is started, so at boot the nearest-N is computed
         * against wherever the device last reported being. The set is
         * recomputed properly on the first real fix after tracking resumes.
         */
        internal fun registerFromPersistedZones(
            context: Context,
            client: GeofencingClient =
                LocationServices.getGeofencingClient(context.applicationContext),
            lastKnownFix: Location? = lastKnownPlatformFix(context)
        ): Int {
            val appContext = context.applicationContext
            val config = PolyfenceConfig(appContext)
            if (!config.osGeofenceWakeEnabled) return 0

            val persistedZones = ZonePersistence(appContext).loadAllZones()
            if (persistedZones.isEmpty()) return 0

            val engine = GeofenceEngine()
            for ((_, zoneInfo) in persistedZones) {
                val (id, name, data) = zoneInfo
                try {
                    @Suppress("DEPRECATION")
                    engine.addZone(id, name, data)
                } catch (e: Exception) {
                    Log.w(TAG, "Skipping invalid persisted zone $id: ${e.message}")
                }
            }
            val zones = engine.getCurrentZones()
            if (zones.isEmpty()) return 0

            val registrar = OsGeofenceRegistrar(
                appContext,
                client,
                config.osGeofenceMaxRegions
            )
            // No app process is in the foreground at boot, and the importance
            // probe can report otherwise for a process the system just started,
            // so drive the state explicitly rather than inferring it.
            registrar.appInForeground = false

            // Block until Play Services has actually accepted the request. The
            // caller holds a BroadcastReceiver's goAsync() lease; returning as
            // soon as the request is handed over would drop the process out of
            // foreground-receiver priority while the IPC is still in flight,
            // and a freshly cold-started process at boot — peak memory
            // pressure — is readily reaped before it completes.
            val settled = java.util.concurrent.CountDownLatch(1)
            var accepted = false
            val handedOver = registrar.applyRegistration(zones, lastKnownFix) { success ->
                accepted = success
                settled.countDown()
            }
            if (handedOver == 0) return 0
            val completed = settled.await(
                BOOT_REGISTRATION_TIMEOUT_SECONDS,
                java.util.concurrent.TimeUnit.SECONDS
            )
            if (!completed) {
                Log.w(TAG, "OS geofence registration did not settle within the boot timeout")
                return 0
            }
            return if (accepted) handedOver else 0
        }

        /**
         * Freshest fix the platform already holds, without starting GPS.
         * Returns null when no provider has one or the grant is missing.
         */
        // A missing grant is the expected case here, not an error: the caller
        // wants a seed if one is cheaply available and falls back to
        // insertion-order selection otherwise. Every provider read is
        // individually guarded by its own SecurityException catch.
        @SuppressLint("MissingPermission")
        private fun lastKnownPlatformFix(context: Context): Location? {
            return try {
                val manager = context.applicationContext
                    .getSystemService(Context.LOCATION_SERVICE) as? android.location.LocationManager
                    ?: return null
                manager.allProviders
                    .mapNotNull { provider ->
                        try {
                            manager.getLastKnownLocation(provider)
                        } catch (e: SecurityException) {
                            null
                        }
                    }
                    .maxByOrNull { it.time }
            } catch (e: Exception) {
                null
            }
        }

        /**
         * How long the boot path waits for Play Services to accept the
         * registration before giving up. Generous because the geofence client
         * is often not yet connected immediately after boot, but bounded so a
         * wedged service cannot hold a broadcast lease open indefinitely.
         */
        const val BOOT_REGISTRATION_TIMEOUT_SECONDS = 20L

        /** Minimum gap between `os_geofence_permission_denied` reports. */
        const val PERMISSION_ERROR_COOLDOWN_MS = 60_000L

        /**
         * Fallback radius for polygon zones — Google Play Services' geofence
         * API accepts circles only, so a polygon is registered as a circular
         * bounding cover around its centroid with radius = the maximum vertex
         * distance. The cover is strictly larger than the polygon, so the OS
         * can wake us for a position inside the cover but outside the zone.
         * The wake carries a triggering location, so the receiver settles that
         * against the real geometry before enqueueing.
         */
        internal const val MIN_POLYGON_COVER_RADIUS_METERS = 100.0

        internal fun selectTopNNearest(
            zones: List<GeofenceEngine.Zone>,
            seed: Location?,
            topN: Int
        ): List<Candidate> {
            if (zones.isEmpty() || topN <= 0) return emptyList()
            val candidates = zones.mapNotNull { zone ->
                val center = candidateCenter(zone) ?: return@mapNotNull null
                val radius = candidateRadius(zone) ?: return@mapNotNull null
                val distance = if (seed == null) 0.0 else GeoMath.haversineDistance(
                    seed.latitude, seed.longitude, center.first, center.second
                )
                Candidate(
                    zoneId = zone.id,
                    centerLat = center.first,
                    centerLng = center.second,
                    radiusMeters = radius,
                    distanceMeters = distance
                )
            }
            return if (seed == null) candidates.take(topN)
            else candidates.sortedBy { it.distanceMeters }.take(topN)
        }

        private fun candidateCenter(zone: GeofenceEngine.Zone): Pair<Double, Double>? {
            zone.center?.let { return it.latitude to it.longitude }
            if (zone.points.isEmpty()) return null
            val lat = zone.points.sumOf { it.latitude } / zone.points.size
            val lng = zone.points.sumOf { it.longitude } / zone.points.size
            return lat to lng
        }

        private fun candidateRadius(zone: GeofenceEngine.Zone): Double? {
            zone.radius?.let { return max(it, 1.0) }
            if (zone.points.isEmpty()) return null
            val center = candidateCenter(zone) ?: return null
            val cLat = center.first
            val cLng = center.second
            val maxDist = zone.points.maxOf { p ->
                GeoMath.haversineDistance(cLat, cLng, p.latitude, p.longitude)
            }
            return max(maxDist, MIN_POLYGON_COVER_RADIUS_METERS)
        }
    }
}

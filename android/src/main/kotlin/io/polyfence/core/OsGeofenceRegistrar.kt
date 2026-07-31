package io.polyfence.core

import android.Manifest
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
import kotlin.math.max

/**
 * Registers the top-N-nearest active zones with Google Play Services geofencing
 * as an OS-managed wake source. The library's own polling engine remains the
 * primary detector — the OS registration only exists so that after full process
 * kill, an OS transition can wake the app long enough to enqueue the crossing
 * into the pending-events queue for drain on next tracker boot.
 *
 * Off unless [PolyfenceConfig.osGeofenceWakeEnabled] is true. When on:
 *  - Selects up to [TOP_N] zones by centroid distance from the last-known fix.
 *  - Registers via [GeofencingClient.addGeofences] with
 *    `INITIAL_TRIGGER_ENTER | INITIAL_TRIGGER_EXIT` so a stationary user still
 *    receives a starting-state event.
 *  - Re-registers when the zone set changes (debounced by [DEBOUNCE_MS] to
 *    absorb rapid zone churn) or when the user moves more than
 *    [MOVEMENT_RECALC_METERS] from the fix that seeded the current selection.
 *  - Emits `os_geofence_permission_denied` via `onError` (severity warning) and
 *    marks the health field with `registered=0` if ACCESS_BACKGROUND_LOCATION
 *    is missing; the in-process polling engine keeps working unchanged and
 *    the consumer app decides whether to prompt.
 *
 * Not thread-safe against external mutation — callers dispatch onto the main
 * looper handler [requestRefresh] posts its debounced work to.
 */
internal class OsGeofenceRegistrar(
    private val context: Context,
    private val geofencingClient: GeofencingClient =
        LocationServices.getGeofencingClient(context.applicationContext)
) {

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
     * Ask the OS to re-evaluate the top-N-nearest set. Debounced by
     * [DEBOUNCE_MS] — repeated calls within the window coalesce into one
     * registration attempt. Safe to call from any thread.
     */
    fun requestRefresh() {
        if (shutdownRequested) return
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
        if (shutdownRequested) return
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
        handler.removeCallbacks(debounceRunnable)
        removeAllOsGeofences()
        health = null
        lastRegistrationLocation = null
    }

    /**
     * Test seam — bypasses the debounce timer and invokes the registration
     * pipeline synchronously against the supplied zones + fix. Internal so
     * `@testable` Robolectric tests can reach it.
     */
    internal fun refreshNowForTest(zones: List<GeofenceEngine.Zone>, seed: Location?) {
        applyRegistration(zones, seed)
    }

    private fun refreshRegistrationInternal() {
        if (shutdownRequested) return
        val tracker = LocationTracker.currentInstanceForOsGeofence
        val zones = tracker?.geofenceEngineForOsGeofence?.getCurrentZones().orEmpty()
        val seed = tracker?.lastKnownLocationForOsGeofence ?: lastRegistrationLocation
        applyRegistration(zones, seed)
    }

    private fun applyRegistration(zones: List<GeofenceEngine.Zone>, seed: Location?) {
        // Advance the movement anchor on every ATTEMPT, not only on success.
        // Anchoring on success alone leaves it null whenever registration keeps
        // failing (permission denied, no zones, OS refusal), and a null anchor
        // makes onLocationUpdate treat every fix as "moved far enough" — one
        // retry and one onError per GPS fix, for as long as the failure lasts.
        lastRegistrationLocation = seed

        val candidates = selectTopNNearest(zones, seed, TOP_N)
        if (!hasBackgroundLocationPermission(context)) {
            reportPermissionDenied(zones.size)
            return
        }

        if (candidates.isEmpty()) {
            removeAllOsGeofences()
            health = Health(requested = zones.size, registered = 0, lastError = null)
            return
        }

        val fences = candidates.map { it.toOsGeofence() }
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(
                GeofencingRequest.INITIAL_TRIGGER_ENTER or
                    GeofencingRequest.INITIAL_TRIGGER_EXIT
            )
            .addGeofences(fences)
            .build()

        val pendingIntent = buildPendingIntent()

        // Re-check immediately before handing the set to the OS: a shutdown
        // that landed while this refresh was queued would otherwise remove the
        // fences and then have them immediately re-armed here, orphaning
        // registrations that outlive the registrar.
        if (shutdownRequested) return

        try {
            geofencingClient.addGeofences(request, pendingIntent)
                .addOnSuccessListener {
                    health = Health(
                        requested = zones.size,
                        registered = candidates.size,
                        lastError = null
                    )
                }
                .addOnFailureListener { e ->
                    val msg = e.message ?: e::class.java.simpleName
                    Log.w(TAG, "OS geofence registration failed: $msg")
                    health = Health(
                        requested = zones.size,
                        registered = 0,
                        lastError = msg
                    )
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
        }
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
         * Google Play Services caps at 100 geofences per app. Kept slightly
         * below the platform ceiling so a consumer app that registers its own
         * geofences via a different code path still has headroom.
         */
        const val TOP_N = 90

        /**
         * Coalesce zone-set churn — a bridge that adds N zones in a tight loop
         * on startup should produce one re-registration, not N. Window matches
         * the iOS registrar for parity.
         */
        const val DEBOUNCE_MS = 200L

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

        /** Minimum gap between `os_geofence_permission_denied` reports. */
        const val PERMISSION_ERROR_COOLDOWN_MS = 60_000L

        /**
         * Fallback radius for polygon zones — Google Play Services' geofence
         * API accepts circles only, so a polygon is registered as a circular
         * bounding cover around its centroid with radius = the maximum vertex
         * distance. The polygon's own containment math still runs in-engine
         * on the drain, so the bounding cover is only a wake trigger; false
         * positives at the wake boundary are filtered by the engine's
         * per-fix `zone.contains(location)` check.
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

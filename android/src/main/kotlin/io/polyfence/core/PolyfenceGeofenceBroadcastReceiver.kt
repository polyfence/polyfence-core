package io.polyfence.core

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import io.polyfence.core.utils.PolyfenceConfig

/**
 * Broadcast receiver for OS-managed geofence transitions registered by
 * [OsGeofenceRegistrar]. Fires when a zone perimeter is crossed while
 * polyfence-core's foreground service is dead.
 *
 * Each wake does two things, strictly in that order:
 *
 *  1. **Captures the crossing.** The event is written into the durable
 *     [PendingEventsStore], and the zone's membership is merged into persisted
 *     zone state so the crossing survives even if the queued event is later
 *     evicted. Delivery to the consumer happens through the same drain path
 *     in-process events use.
 *  2. **Resumes tracking.** The service is restarted so the in-process polling
 *     engine takes over detection for the rest of the journey.
 *
 * Step 2 is what makes the OS registration a *wake source* rather than a
 * one-shot notifier. The fences the OS holds cover a ring around wherever the
 * process happened to die; nothing re-selects that ring while the app is dead,
 * so without resuming, coverage ends at the first crossing and a user who
 * travels on is invisible. Once the engine is running it owns detection with no
 * region cap, and re-selects the OS fence set from movement as normal. iOS
 * needs no equivalent because the platform relaunches the whole app on a region
 * crossing, which runs `startTracking()` on its own.
 *
 * Resumption is conditional and never load-bearing for capture:
 *  - Skipped unless the consumer's tracking intent is still on, so a deliberate
 *    `stopTracking()` is not undone behind them.
 *  - Skipped when the engine is already running, and rate-limited by
 *    [RESUME_COOLDOWN_MS] so the burst of broadcasts Play Services delivers
 *    while a journey is under way costs one service start, not one per fence.
 *  - Skipped, with a report through the normal error channel, when the grants a
 *    background foreground-service start needs are missing.
 *  - Degrades to capture-only on any refusal by the platform. The crossing is
 *    already on disk before a resume is attempted, so a failed resume never
 *    costs an event.
 */
class PolyfenceGeofenceBroadcastReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            val code = event.errorCode
            Log.w(TAG, "OS geofence event carried error code=$code")
            reportSafely(
                type = "os_geofence_broadcast_error",
                message = "OS geofence broadcast reported error code $code",
                errorContext = mapOf(
                    "severity" to "warning",
                    "platform" to "android",
                    "errorCode" to code
                )
            )
            return
        }

        val eventType = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "ENTER"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "EXIT"
            else -> return
        }

        val zoneIds = event.triggeringGeofences.orEmpty().map { it.requestId }
        if (zoneIds.isEmpty()) return

        val appContext = context.applicationContext
        val triggeringLocation = event.triggeringLocation

        // The append does a whole-file read-modify-write with an fsync per
        // event. onReceive runs on the main thread, so doing that inline is an
        // ANR risk on a device the OS has only just cold-started for this
        // broadcast. goAsync() keeps the process alive while a worker thread
        // does the I/O.
        val pendingResult = goAsync()
        Thread {
            try {
                enqueueOsTransition(appContext, eventType, zoneIds, triggeringLocation)
            } catch (e: Exception) {
                // A broadcast is the wrong place to die: the OS started this
                // process specifically to deliver the crossing, and an escaping
                // exception here would surface to the user as a crash of the
                // consumer's app.
                Log.w(TAG, "Failed to enqueue OS geofence transition: ${e.message}")
            }
            try {
                // Separately guarded and strictly second: capturing the crossing
                // must not depend on the resume, and the resume must not be
                // skipped because an unrelated storage failure threw.
                //
                // The outcome is recorded rather than discarded: most of the
                // gates decline silently, and a wake that captured nothing and
                // resumed nothing is otherwise indistinguishable from a wake
                // that never arrived.
                val outcome = resumeTrackingIfIntended(appContext)
                Log.i(TAG, "OS wake resume: $outcome")
            } catch (e: Throwable) {
                // Throwable, not Exception: a device without Play Services
                // raises NoClassDefFoundError out of the geofencing classes this
                // path touches, and on a bare thread that would crash the
                // consumer's app rather than degrade to capture-only.
                Log.w(TAG, "Failed to resume tracking after OS geofence wake: ${e.message}")
            } finally {
                pendingResult.finish()
            }
        }.start()
    }

    /**
     * Why a wake did or did not resume tracking. Returned rather than only
     * logged so a test can assert which gate a given wake stopped at, and so a
     * caller can tell "declined" from "attempted and refused".
     */
    internal enum class ResumeOutcome {
        /** The service start was handed to the platform without refusal. */
        STARTED,

        /** OS wake fences are off; the whole path is inert. */
        FEATURE_DISABLED,

        /** The in-process engine already owns detection. */
        ALREADY_RUNNING,

        /** A resume was issued moments ago and the service is still coming up. */
        ALREADY_REQUESTED,

        /** The consumer's last call was `stopTracking()`. */
        NOT_INTENDED,

        /** A grant that a background service start requires is missing. */
        PERMISSION_DENIED,

        /** The platform refused the start. */
        REFUSED
    }

    companion object {
        private const val TAG = "PolyfenceGeofenceReceiver"

        /**
         * Marks the queued event as having originated from an OS wake fence
         * rather than the in-process polling engine. Consumers that want to
         * distinguish "the OS woke us for this" from "we detected it while
         * running" branch on this; the drain path treats both identically.
         */
        const val EVENT_SOURCE_OS_GEOFENCE = "os_geofence"

        /**
         * Persist one OS-fired transition per zone into the pending queue.
         * Returns the total number of events evicted by these appends.
         *
         * Writes to the SAME store instance the running tracker holds when the
         * Service is alive — sharing the instance means both writers go through
         * one serial executor, so the on-disk log cannot be interleaved by two
         * independent writers racing on the same file. Falls back to a transient
         * store constructed against the persisted queue size only when no
         * Service is running — the killed-process case this receiver exists
         * for.
         *
         * `GeofencingEvent` cannot be constructed outside Google Play Services,
         * so [onReceive] parses it and delegates the storage work here where a
         * unit test can reach the same code path with primitives.
         */
        internal fun enqueueOsTransition(
            context: Context,
            eventType: String,
            zoneIds: List<String>,
            triggeringLocation: Location?
        ): Int {
            if (zoneIds.isEmpty()) return 0

            val appContext = context.applicationContext
            val config = PolyfenceConfig(appContext)

            // With the flag off, behaviour must be indistinguishable from
            // before this feature existed — including for fences a previous
            // session registered that the OS is still holding.
            if (!config.osGeofenceWakeEnabled) {
                Log.i(TAG, "OS wake ignored: the feature is off; the OS still holds fences from a prior session")
                return 0
            }

            val liveTracker = LocationTracker.currentInstanceForOsGeofence

            // Gated on the in-process engine RUNNING, not on whether it could
            // deliver live. Those differ exactly where it matters: a detached
            // bridge leaves the engine polling and persisting into this same
            // queue, so gating on deliverability would let both writers record
            // one physical crossing and hand the consumer a duplicate.
            if (liveTracker?.isEngineRunningForOsGeofence == true) {
                Log.i(TAG, "OS wake ignored: the in-process engine is running and owns this crossing")
                return 0
            }

            // A queue-less wake has nowhere to deposit the crossing, so the
            // whole feature is inert. Surface it rather than losing events to a
            // silent misconfiguration.
            if (config.pendingEventsQueueSize <= 0) {
                reportSafely(
                    type = "os_geofence_queue_disabled",
                    message = "OS wake fences are enabled but pendingEventsQueueSize is 0; " +
                        "the woken crossing cannot be stored",
                    errorContext = mapOf(
                        "severity" to "warning",
                        "platform" to "android",
                        "source" to EVENT_SOURCE_OS_GEOFENCE
                    )
                )
                return 0
            }

            // One read of persisted zone state serves three purposes below:
            // resolving names, suppressing registration-time replays, and
            // rejecting bounding-cover false positives. At wake time there is
            // usually no live engine, so disk is the only source for all three.
            val persistence = ZonePersistence(appContext)
            val persistedZones = runCatching { persistence.loadAllZones() }.getOrDefault(emptyMap())
            val persistedStates = runCatching { persistence.loadZoneStates() }.getOrDefault(emptyMap())
            val impliedInside = eventType == "ENTER"

            val liveStore = liveTracker?.pendingEventsStoreForOsGeofence
            val store = liveStore ?: PendingEventsStore(
                appContext,
                config.pendingEventsQueueSize
            )

            val timestamp = System.currentTimeMillis()
            var evicted = 0
            val capturedStates = mutableMapOf<String, Boolean>()

            // A wake happens with no app running and nothing watching, so a
            // dropped crossing leaves no trace anywhere: the queue simply stays
            // empty and the next session reconciles as if nothing occurred.
            // Every decision below is therefore recorded, including the ones
            // that discard — an empty queue must be distinguishable from a
            // queue that was never offered anything.
            Log.i(
                TAG,
                "OS wake: type=$eventType zones=${zoneIds.size} " +
                    "hasFix=${triggeringLocation != null} liveStore=${liveStore != null}"
            )

            for (zoneId in zoneIds) {
                // Play Services replays the current state for every fence at
                // registration time. Anything that merely restates what we
                // already believe is not a crossing and must not reach the
                // consumer as one.
                if (persistedStates[zoneId] == impliedInside) {
                    Log.i(TAG, "OS wake: $zoneId dropped — restates believed membership ($impliedInside)")
                    continue
                }

                // A polygon is registered as a circular cover, so the OS can
                // wake us for a position inside the cover but outside the
                // polygon. When the wake carries a fix, the real geometry
                // settles it; without one the event is kept, and the engine's
                // reconcile corrects membership on the next in-process fix.
                if (impliedInside && triggeringLocation != null &&
                    isDefinitelyOutside(zoneId, persistedZones, triggeringLocation)
                ) {
                    Log.i(TAG, "OS wake: $zoneId dropped — fix lies outside the real geometry")
                    continue
                }

                Log.i(TAG, "OS wake: $zoneId captured $eventType (believed=${persistedStates[zoneId]})")

                val zoneName = liveTracker?.geofenceEngineForOsGeofence?.getZoneName(zoneId)
                    ?: persistedZones[zoneId]?.second
                    ?: zoneId
                evicted += store.append(
                    mapOf(
                        "zoneId" to zoneId,
                        "zoneName" to zoneName,
                        "eventType" to eventType,
                        "timestamp" to timestamp,
                        "detectionTimeMs" to 0.0,
                        "gpsAccuracy" to (triggeringLocation?.accuracy?.toDouble() ?: 0.0),
                        "latitude" to (triggeringLocation?.latitude ?: 0.0),
                        "longitude" to (triggeringLocation?.longitude ?: 0.0),
                        "speedMps" to (triggeringLocation?.speed?.toDouble() ?: 0.0),
                        "activityAtEvent" to "unknown",
                        "distanceToBoundaryM" to 0.0,
                        "source" to EVENT_SOURCE_OS_GEOFENCE
                    )
                )
                capturedStates[zoneId] = impliedInside
            }

            // Persisted membership is the record of where the user is; the queue
            // is only the record of what still needs delivering. Writing both
            // keeps the two agreeing across a wake, which is what stops the
            // resumed session's first reconcile from raising a RECOVERY_* for a
            // crossing already sitting in the queue — and keeps the crossing
            // reflected in state even if eviction later drops the queued event.
            // Must land before the resume below: the restarted service loads
            // persisted zone states while starting, and a write that arrived
            // after that load would be invisible to the reconcile it exists to
            // inform. mergeZoneStates commits synchronously, so returning from
            // here is the ordering guarantee.
            if (capturedStates.isNotEmpty()) {
                runCatching { persistence.mergeZoneStates(capturedStates) }
                    .onFailure { Log.w(TAG, "Failed to persist woken zone states: ${it.message}") }
            }

            // Only the transient store is ours to close; shutting down the
            // tracker's store here would stop its writer thread mid-session and
            // silently drop every subsequent in-process persist.
            if (liveStore == null) store.shutdown()

            if (evicted > 0) {
                reportSafely(
                    type = "pending_events_evicted",
                    message = "Pending events queue reached capacity; oldest events dropped",
                    errorContext = mapOf(
                        "severity" to "warning",
                        "droppedCount" to evicted,
                        "platform" to "android",
                        "source" to EVENT_SOURCE_OS_GEOFENCE
                    )
                )
            }
            return evicted
        }

        /**
         * Minimum gap between service starts issued from a wake. Play Services
         * delivers a burst of transitions as a moving user crosses the
         * registered ring, and the engine-running check alone does not absorb
         * them: the service takes a moment to come up, so every broadcast that
         * lands in that window would otherwise issue its own start. Sized to
         * the platform's own foreground-service start budget — past it, a start
         * that has not produced a running engine has failed, and the next wake
         * should be free to try again.
         */
        internal const val RESUME_COOLDOWN_MS = 10_000L

        private val resumeLock = Any()

        private var lastResumeRequestedAt = 0L

        /** Clears the resume throttle so each test case starts from a cold process. */
        internal fun resetResumeThrottleForTest() {
            synchronized(resumeLock) { lastResumeRequestedAt = 0L }
        }

        /**
         * Restart the tracker so the in-process engine resumes detection for the
         * rest of the journey. Called after the crossing has already been
         * captured, so every early return here costs coverage from this point
         * on, never the crossing that woke us.
         *
         * [now] is injectable so a test can drive the cooldown without sleeping.
         */
        internal fun resumeTrackingIfIntended(
            context: Context,
            now: Long = System.currentTimeMillis()
        ): ResumeOutcome {
            val appContext = context.applicationContext

            // With the flag off, behaviour must be indistinguishable from before
            // this feature existed — including for fences a previous session
            // registered that the OS is still holding.
            if (!PolyfenceConfig(appContext).osGeofenceWakeEnabled) {
                return ResumeOutcome.FEATURE_DISABLED
            }

            // The engine already owns detection, so a wake has nothing to add.
            // This is the steady state once a journey is under way: the fences
            // stay armed and every further broadcast settles here.
            if (LocationTracker.currentInstanceForOsGeofence
                    ?.isEngineRunningForOsGeofence == true
            ) {
                return ResumeOutcome.ALREADY_RUNNING
            }

            // Tracking intent, not tracking state. A consumer who called
            // stopTracking() must not have it restarted behind them, and the
            // persisted flag is the only record of that choice that survives the
            // process the choice was made in.
            if (!LocationTracker.isContinuousTrackingIntended(appContext)) {
                return ResumeOutcome.NOT_INTENDED
            }

            if (!hasBackgroundServiceStartPerms(appContext)) {
                reportSafely(
                    type = "os_geofence_resume_denied",
                    message = "OS wake fence fired but tracking cannot resume: " +
                        "the grants a background location service start requires are missing",
                    errorContext = mapOf(
                        "severity" to "warning",
                        "platform" to "android",
                        "source" to EVENT_SOURCE_OS_GEOFENCE
                    )
                )
                return ResumeOutcome.PERMISSION_DENIED
            }

            synchronized(resumeLock) {
                val neverRequested = lastResumeRequestedAt == 0L
                val cooledDown = now - lastResumeRequestedAt >= RESUME_COOLDOWN_MS
                if (!neverRequested && !cooledDown) return ResumeOutcome.ALREADY_REQUESTED
                lastResumeRequestedAt = now
            }

            val intent = Intent(appContext, LocationTracker::class.java).apply {
                action = LocationTracker.ACTION_START_TRACKING
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appContext.startForegroundService(intent)
                } else {
                    appContext.startService(intent)
                }
                Log.i(TAG, "Resumed tracking from an OS geofence wake")
                ResumeOutcome.STARTED
            } catch (e: Exception) {
                // A geofence transition is on the platform's exemption list for
                // background foreground-service starts, but the exemption is not
                // universal across versions and OEM builds, and the location
                // service type carries its own while-in-use rules on API 34+.
                // A refusal degrades to capture-only: the crossing is already
                // persisted, and the next tracker boot drains it as before.
                Log.w(TAG, "Platform refused the wake-driven service start: ${e.message}")
                reportSafely(
                    type = "os_geofence_resume_refused",
                    message = "The system refused to restart tracking after an OS wake fence: " +
                        (e.message ?: e.javaClass.simpleName),
                    errorContext = mapOf(
                        "severity" to "warning",
                        "platform" to "android",
                        "reason" to e.javaClass.simpleName,
                        "source" to EVENT_SOURCE_OS_GEOFENCE
                    )
                )
                ResumeOutcome.REFUSED
            }
        }

        /**
         * Grants a wake-driven service start needs, which is a strict superset
         * of what a consumer-driven `startTracking()` needs.
         *
         * The extra one is `ACCESS_BACKGROUND_LOCATION`. A `location`-typed
         * foreground service started while the process is backgrounded is
         * refused on API 34+ without it, and the refusal arrives as an exception
         * out of `startForeground` rather than as a degraded service. Checking
         * here turns that into a reported no-op. It costs nothing in practice:
         * the registrar already declines to arm fences without the same grant,
         * so any process reaching this point held it when the fences were armed.
         */
        private fun hasBackgroundServiceStartPerms(context: Context): Boolean {
            fun granted(permission: String) =
                ContextCompat.checkSelfPermission(context, permission) ==
                    PackageManager.PERMISSION_GRANTED

            val fine = granted(Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (!fine && !coarse) return false

            if (Build.VERSION.SDK_INT >= 34 &&
                !granted(Manifest.permission.FOREGROUND_SERVICE_LOCATION)
            ) {
                return false
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                !granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            ) {
                return false
            }

            return true
        }

        /**
         * True when the persisted geometry for [zoneId] definitively excludes
         * [fix]. Returns false when the zone is unknown or unparseable — the
         * event is then kept, because dropping a crossing on missing data is
         * worse than forwarding one the engine will correct on its next fix.
         */
        private fun isDefinitelyOutside(
            zoneId: String,
            persistedZones: Map<String, Triple<String, String, Map<String, Any>>>,
            fix: Location
        ): Boolean {
            val data = persistedZones[zoneId]?.third ?: return false
            return runCatching {
                val engine = GeofenceEngine()
                @Suppress("DEPRECATION")
                engine.addZone(zoneId, zoneId, data)
                !engine.isLocationInsideZone(zoneId, fix)
            }.getOrDefault(false)
        }

        /**
         * Reports through the normal error channel without letting a throwing
         * consumer handler escape. `PolyfenceErrorManager` invokes the
         * consumer's `onError` synchronously, and an exception raised there
         * would otherwise propagate out of the broadcast and crash the app.
         */
        private fun reportSafely(
            type: String,
            message: String,
            errorContext: Map<String, Any>
        ) {
            try {
                PolyfenceErrorManager.reportError(type, message, errorContext)
            } catch (e: Exception) {
                Log.w(TAG, "Consumer error handler threw while reporting $type: ${e.message}")
            }
        }
    }
}

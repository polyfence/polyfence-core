package io.polyfence.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.Location
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import io.polyfence.core.utils.PolyfenceConfig

/**
 * Broadcast receiver for OS-managed geofence transitions registered by
 * [OsGeofenceRegistrar]. Fires when a zone perimeter is crossed while
 * polyfence-core's foreground service is dead — writes the event into the
 * durable [PendingEventsStore] and returns. Delivery to the consumer happens
 * on the tracker's next boot via the same drain path in-process events use.
 *
 * The receiver deliberately does not restart the tracker service, does not
 * call the delegate, and does not attempt live reconciliation — the tracker's
 * next `startTracking()` picks up whatever is on disk.
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
            } finally {
                pendingResult.finish()
            }
        }.start()
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
            if (!config.osGeofenceWakeEnabled) return 0

            val liveTracker = LocationTracker.currentInstanceForOsGeofence

            // Gated on the in-process engine RUNNING, not on whether it could
            // deliver live. Those differ exactly where it matters: a detached
            // bridge leaves the engine polling and persisting into this same
            // queue, so gating on deliverability would let both writers record
            // one physical crossing and hand the consumer a duplicate.
            if (liveTracker?.isEngineRunningForOsGeofence == true) return 0

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
            for (zoneId in zoneIds) {
                // Play Services replays the current state for every fence at
                // registration time. Anything that merely restates what we
                // already believe is not a crossing and must not reach the
                // consumer as one.
                if (persistedStates[zoneId] == impliedInside) continue

                // A polygon is registered as a circular cover, so the OS can
                // wake us for a position inside the cover but outside the
                // polygon. When the wake carries a fix, the real geometry
                // settles it; without one the event is kept, and the engine's
                // reconcile corrects membership on the next in-process fix.
                if (impliedInside && triggeringLocation != null &&
                    isDefinitelyOutside(zoneId, persistedZones, triggeringLocation)
                ) {
                    continue
                }

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

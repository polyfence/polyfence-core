package io.polyfence.core

import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager as AndroidLocationManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.Debug
import androidx.core.app.ActivityCompat
import android.Manifest
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * Collects comprehensive debug information for developers
 * Integrates with existing analytics and error systems
 */
class PolyfenceDebugCollector {

    /**
     * Names of the payload entries that are read back by name elsewhere in
     * the library rather than only handed to a consumer.
     *
     * A reader that spells one of these differently gets null and falls back
     * to a default — and for the scored metrics the default is the *best*
     * possible value, so a typo raises the health score instead of breaking
     * it. Sharing the constant makes the two sides impossible to drift apart.
     */
    object Key {
        const val PERFORMANCE = "performance"
        const val RECENT_ERRORS = "recentErrors"
        const val AVERAGE_DETECTION_LATENCY = "averageDetectionLatency"
    }

    companion object {
        private val errorHistory = ConcurrentLinkedDeque<Map<String, Any>>()
        private var sessionStartTime = System.currentTimeMillis()
        private var pluginVersion: String? = null // Stored during initialization

        /**
         * Guards the session counters below. They are written from the
         * location and geofence callback threads and read from whichever
         * background thread serves [collectDebugInfo], so every access is
         * taken under this monitor. Readers snapshot the values and release
         * before doing anything else with them, so a debug poll can never
         * hold the monitor across work that would stall an incoming GPS fix.
         */
        private val metricsLock = Any()
        private var lastLocationUpdateTime = 0L
        private var lastKnownAccuracy = -1.0
        private var locationUpdateCount = 0
        private var zoneDetectionCount = 0
        private var timedDetectionCount = 0
        private var totalDetectionLatencyMs = 0.0
        private var restartCount = 0

        fun collectDebugInfo(context: Context): Map<String, Any> {
            return mapOf(
                "systemStatus" to collectSystemStatus(context),
                Key.PERFORMANCE to collectPerformanceMetrics(),
                "battery" to collectBatteryMetrics(context),
                "zones" to collectZoneStatus(),
                Key.RECENT_ERRORS to getRecentErrors()
            )
        }

        private fun collectSystemStatus(context: Context): Map<String, Any?> {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as AndroidLocationManager

            val accuracy: Double
            val lastUpdate: Long
            synchronized(metricsLock) {
                accuracy = lastKnownAccuracy
                lastUpdate = lastLocationUpdateTime
            }

            return mapOf(
                "isLocationPermissionGranted" to hasLocationPermission(context),
                "isBackgroundLocationEnabled" to hasBackgroundLocationPermission(context),
                "isBatteryOptimizationDisabled" to powerManager.isIgnoringBatteryOptimizations(context.packageName),
                "isGpsEnabled" to isGpsEnabled(locationManager),
                "isWakeLockAcquired" to LocationTracker.currentWakeLockHeld(),
                "lastKnownAccuracy" to accuracy,
                "lastLocationUpdate" to lastUpdate,
                "platformVersion" to Build.VERSION.RELEASE,
                "pluginVersion" to getPluginVersion(),
                // Null when osGeofenceWakeEnabled = false. Present as a
                // { requested, registered, lastError } map when opted in so a
                // consumer surface can observe OS-cap hits (requested >
                // registered) or permission drift (lastError set to a
                // background_location_denied-shaped string).
                "osGeofenceRegistrationHealth" to
                    (LocationTracker.osGeofenceRegistrationHealth())
            )
        }

        private fun collectPerformanceMetrics(): Map<String, Any?> {
            val runtime = Runtime.getRuntime()
            val usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / 1024 / 1024

            val updates: Int
            val detections: Int
            val averageLatency: Double?
            val timed: Int
            val restarts: Int
            synchronized(metricsLock) {
                updates = locationUpdateCount
                detections = zoneDetectionCount
                // Absent until a crossing has been *timed*: a synthesised
                // one raises totalZoneDetections without contributing a
                // sample. Zero is the best possible latency, so reporting it
                // for "no samples" makes an unmeasured device look perfect.
                timed = timedDetectionCount
                averageLatency = if (timedDetectionCount > 0) {
                    totalDetectionLatencyMs / timedDetectionCount
                } else {
                    null
                }
                restarts = restartCount
            }

            return mapOf(
                "uptime" to (System.currentTimeMillis() - sessionStartTime),
                "totalLocationUpdates" to updates,
                "totalZoneDetections" to detections,
                // How many of those were timed, and so how many samples the
                // mean below covers. Without it a consumer would assume the
                // mean spans every crossing, which it cannot when the engine
                // synthesises one outside a timed evaluation.
                "timedZoneDetections" to timed,
                Key.AVERAGE_DETECTION_LATENCY to averageLatency,
                // Java heap only. iOS reports whole-process resident size, so
                // the two are not comparable across platforms.
                "memoryUsageMB" to usedMemory.toInt(),
                "restartCount" to restarts
            )
        }

        private fun collectBatteryMetrics(context: Context): Map<String, Any> {
            val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager

            return mapOf(
                "isCharging" to isCharging(batteryManager),
                "batteryLevel" to getBatteryLevel(batteryManager),
                "totalActiveTime" to (System.currentTimeMillis() - sessionStartTime)
            )
        }

        private fun collectZoneStatus(): Map<String, Any> {
            // Read through the running service rather than holding a
            // reference: once the service is destroyed there is nothing being
            // monitored, and a retained engine would keep reporting the zones
            // of a session that has ended.
            val engine = LocationTracker.currentGeofenceEngine()
            if (engine == null) {
                return mapOf(
                    "activeZones" to 0,
                    "circleZones" to 0,
                    "polygonZones" to 0
                )
            }

            val zones = engine.getCurrentZones()
            val circleCount = zones.count { it.isCircle }
            val polygonCount = zones.count { it.isPolygon }

            return mapOf(
                "activeZones" to zones.size,
                "circleZones" to circleCount,
                "polygonZones" to polygonCount
            )
        }

        private fun getRecentErrors(): List<Map<String, Any>> {
            return errorHistory.toList().takeLast(10)
        }

        fun recordLocationUpdate(accuracy: Double) {
            synchronized(metricsLock) {
                lastKnownAccuracy = accuracy
                lastLocationUpdateTime = System.currentTimeMillis()
                locationUpdateCount++
            }
        }

        /**
         * Record one zone crossing, and the time the engine spent producing
         * it where that was measured.
         *
         * A null latency means the crossing was real but never timed — the
         * engine synthesises some outside a location evaluation. Those still
         * count as crossings, because the consumer received them; they are
         * simply left out of the mean rather than folded in as zero, which
         * would drag it toward a speed nothing achieved.
         *
         * Latency is fractional milliseconds: a point-in-zone evaluation
         * routinely completes in well under a millisecond, so the sum is kept
         * and the mean derived at read time.
         */
        fun recordZoneDetection(latencyMs: Double?) {
            synchronized(metricsLock) {
                zoneDetectionCount++
                if (latencyMs != null) {
                    timedDetectionCount++
                    totalDetectionLatencyMs += latencyMs
                }
            }
        }

        fun recordError(errorType: String, message: String, context: Map<String, Any> = emptyMap()) {
            recordError(mapOf(
                "type" to errorType,
                "message" to message,
                "timestamp" to System.currentTimeMillis(),
                "context" to context
            ))
        }

        /**
         * Overload that stores the caller-supplied map verbatim.
         * PolyfenceErrorManager uses this to preserve correlationId and
         * share the exact timestamp between the real-time callback and
         * the persisted entry — matching iOS's addErrorToHistory
         * semantics.
         */
        fun recordError(errorEntry: Map<String, Any>) {
            errorHistory.addLast(errorEntry)

            // Keep only last 100 errors
            while (errorHistory.size > 100) {
                errorHistory.removeFirst()
            }
        }

        /**
         * Record that the tracking service was created again inside a process
         * that had already created it once. Counting is scoped to the process:
         * a restart that follows process death takes this state with it, so
         * the figure reads alongside `uptime`, which has the same scope.
         */
        fun recordRestart() {
            synchronized(metricsLock) {
                restartCount++
            }
        }

        fun getErrorHistory(timeRangeMs: Long?, errorTypes: List<String>?): List<Map<String, Any>> {
            var filteredErrors = errorHistory.toList()

            // Filter by time range
            if (timeRangeMs != null) {
                val cutoffTime = System.currentTimeMillis() - timeRangeMs
                filteredErrors = filteredErrors.filter {
                    (it["timestamp"] as Long) >= cutoffTime
                }
            }

            // Filter by error types
            if (errorTypes != null && errorTypes.isNotEmpty()) {
                filteredErrors = filteredErrors.filter {
                    errorTypes.contains(it["type"])
                }
            }

            return filteredErrors
        }

        // Helper methods

        private fun hasLocationPermission(context: Context): Boolean {
            return ActivityCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
            ActivityCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }

        private fun hasBackgroundLocationPermission(context: Context): Boolean {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ActivityCompat.checkSelfPermission(
                    context, Manifest.permission.ACCESS_BACKGROUND_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
            } else {
                true
            }
        }

        private fun isGpsEnabled(locationManager: AndroidLocationManager): Boolean {
            return locationManager.isProviderEnabled(AndroidLocationManager.GPS_PROVIDER) ||
                   locationManager.isProviderEnabled(AndroidLocationManager.NETWORK_PROVIDER)
        }

        /**
         * Set plugin version (called during initialization)
         */
        fun setPluginVersion(version: String) {
            pluginVersion = version
        }

        private fun getPluginVersion(): String {
            return pluginVersion ?: "unknown"
        }

        private fun isCharging(batteryManager: android.os.BatteryManager): Boolean {
            return batteryManager.isCharging
        }

        private fun getBatteryLevel(batteryManager: android.os.BatteryManager): Int {
            return batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        }
    }
}

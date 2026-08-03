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
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * Collects comprehensive debug information for developers
 * Integrates with existing analytics and error systems
 */
class PolyfenceDebugCollector {
    companion object {
        private val errorHistory = ConcurrentLinkedDeque<Map<String, Any>>()
        private var sessionStartTime = System.currentTimeMillis()
        private var pluginVersion: String? = null // Stored during initialization

        /**
         * Guards the session counters below. They are written from the
         * location and geofence callback threads and read from whichever
         * background thread serves [collectDebugInfo], so every access is
         * taken under this monitor. Readers snapshot and release before any
         * blocking work — [getCpuUsage] sleeps for roughly a third of a
         * second and must never run while the monitor is held, or a GPS fix
         * would stall behind a debug poll.
         */
        private val metricsLock = Any()
        private var lastLocationUpdateTime = 0L
        private var lastKnownAccuracy = -1.0
        private var locationUpdateCount = 0
        private var zoneDetectionCount = 0
        private var totalDetectionLatencyMs = 0.0
        private var restartCount = 0

        fun collectDebugInfo(context: Context): Map<String, Any> {
            return mapOf(
                "systemStatus" to collectSystemStatus(context),
                "performance" to collectPerformanceMetrics(),
                "battery" to collectBatteryMetrics(context),
                "zones" to collectZoneStatus(),
                "recentErrors" to getRecentErrors()
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
                "isWakeLockAcquired" to isWakeLockAcquired(),
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

        private fun collectPerformanceMetrics(): Map<String, Any> {
            val runtime = Runtime.getRuntime()
            val usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / 1024 / 1024

            val updates: Int
            val detections: Int
            val averageLatency: Double
            val restarts: Int
            synchronized(metricsLock) {
                updates = locationUpdateCount
                detections = zoneDetectionCount
                averageLatency = if (zoneDetectionCount > 0) {
                    totalDetectionLatencyMs / zoneDetectionCount
                } else {
                    0.0
                }
                restarts = restartCount
            }

            return mapOf(
                "uptime" to (System.currentTimeMillis() - sessionStartTime),
                "totalLocationUpdates" to updates,
                "totalZoneDetections" to detections,
                "averageDetectionLatency" to averageLatency,
                "memoryUsageMB" to usedMemory.toInt(),
                "cpuUsagePercent" to getCpuUsage(),
                "restartCount" to restarts
            )
        }

        private fun collectBatteryMetrics(context: Context): Map<String, Any> {
            val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager

            return mapOf(
                "estimatedHourlyDrain" to estimateBatteryDrain(),
                "gpsActiveTimePercent" to calculateGpsActiveTimePercent(),
                "wakeUpCount" to getWakeUpCount(),
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
                    "polygonZones" to 0,
                    "lastZoneUpdate" to System.currentTimeMillis(),
                    "zoneEventCounts" to emptyMap<String, Int>()
                )
            }

            val zones = engine.getCurrentZones()
            val circleCount = zones.count { it.isCircle }
            val polygonCount = zones.count { it.isPolygon }

            return mapOf(
                "activeZones" to zones.size,
                "circleZones" to circleCount,
                "polygonZones" to polygonCount,
                "lastZoneUpdate" to System.currentTimeMillis(),
                "zoneEventCounts" to emptyMap<String, Int>()
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
         * Record one geofence detection and the time the engine spent
         * producing it.
         *
         * Latency is fractional milliseconds: a point-in-zone evaluation
         * routinely completes in well under a millisecond, so the sum is kept
         * and the mean derived at read time.
         */
        fun recordZoneDetection(latencyMs: Double) {
            synchronized(metricsLock) {
                zoneDetectionCount++
                totalDetectionLatencyMs += latencyMs
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
         * semantics. BUG-016 parity nit.
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

        private fun isWakeLockAcquired(): Boolean {
            // This would check if our wake lock is currently held
            // For now, return false as we don't have direct access to the wake lock instance
            return false
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

        /**
         * Measures CPU usage by reading /proc/stat before and after a 360ms interval.
         * Must be called from a background thread — blocks for ~360ms to measure CPU usage.
         * Do not call from the main thread.
         */
        private fun getCpuUsage(): Double {
            require(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
                "getCpuUsage() blocks for ~360ms and must not be called on the main thread"
            }
            return try {
                val reader = RandomAccessFile("/proc/stat", "r")
                val load = reader.readLine()
                reader.close()

                val toks = load.split(" ".toRegex()).dropLastWhile { it.isEmpty() }.toTypedArray()
                val idle1 = toks[4].toLong()
                val cpu1 = toks[1].toLong() + toks[2].toLong() + toks[3].toLong() + toks[5].toLong() + toks[6].toLong() + toks[7].toLong() + toks[8].toLong()

                Thread.sleep(360)

                val reader2 = RandomAccessFile("/proc/stat", "r")
                val load2 = reader2.readLine()
                reader2.close()

                val toks2 = load2.split(" ".toRegex()).dropLastWhile { it.isEmpty() }.toTypedArray()
                val idle2 = toks2[4].toLong()
                val cpu2 = toks2[1].toLong() + toks2[2].toLong() + toks2[3].toLong() + toks2[5].toLong() + toks2[6].toLong() + toks2[7].toLong() + toks2[8].toLong()

                val cpuUsage = (cpu2 - cpu1).toDouble() / ((cpu2 + idle2) - (cpu1 + idle1)) * 100.0
                cpuUsage.coerceIn(0.0, 100.0)
            } catch (e: Exception) {
                0.0
            }
        }

        private fun estimateBatteryDrain(): Double {
            // Simple estimation based on GPS usage
            val gpsActiveTime = (System.currentTimeMillis() - sessionStartTime) / 1000.0 / 3600.0 // hours
            return gpsActiveTime * 5.0 // Estimated 5% per hour for GPS
        }

        private fun calculateGpsActiveTimePercent(): Int {
            val totalTime = System.currentTimeMillis() - sessionStartTime
            val gpsActiveTime = totalTime // Assume GPS is always active when tracking
            return ((gpsActiveTime.toDouble() / totalTime) * 100).toInt()
        }

        private fun getWakeUpCount(): Int {
            // This would track wake-up events
            return 0
        }

        private fun isCharging(batteryManager: android.os.BatteryManager): Boolean {
            return batteryManager.isCharging
        }

        private fun getBatteryLevel(batteryManager: android.os.BatteryManager): Int {
            return batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
        }
    }
}

package io.polyfence.core

import android.os.Build
import java.util.concurrent.ConcurrentHashMap

/**
 * Aggregates all session telemetry in the native layer (D016).
 * Each platform bridge (Flutter, RN, future) only calls getSessionTelemetry()
 * and POSTs the result — no per-bridge telemetry reimplementation needed.
 *
 * Thread-safe: all mutable state is accessed under a single lock object,
 * matching the Swift implementation's DispatchQueue(attributes: .concurrent)
 * with barrier writes and sync reads.
 */
internal class TelemetryAggregator {

    private val lock = Any()

    // --- Activity distribution ---
    private val activityTimeMs = mutableMapOf<String, Long>()
    private var lastActivityChangeTime: Long = System.currentTimeMillis()
    private var lastTrackedActivity: String = "unknown"

    // --- GPS interval distribution ---
    private val intervalTimeMs = mutableMapOf<Long, Long>()
    private var lastIntervalChangeTime: Long = System.currentTimeMillis()
    private var lastTrackedInterval: Long = 10_000L
    private var totalIntervalMs: Long = 0L
    private var intervalSampleCount: Int = 0

    // --- Stationary tracking ---
    private var cumulativeStationaryMs: Long = 0L
    private var stationaryStartTime: Long? = null

    // --- GPS accuracy at events ---
    private val eventAccuracies = mutableListOf<Double>()
    private val eventSpeeds = mutableListOf<Double>()
    private val eventDistances = mutableListOf<Double>()
    private var boundaryEventsCount: Int = 0
    private val BOUNDARY_THRESHOLD_M = 50.0

    // --- False event tracking ---
    private val lastEventPerZone = ConcurrentHashMap<String, Pair<String, Long>>()
    private var falseEventCount: Int = 0

    // --- Detection timing ---
    private val detectionTimesMs = mutableListOf<Double>()
    private var firstDetectionTimeMs: Long? = null
    private var sessionStartTime: Long = System.currentTimeMillis()
    private var sessionStartHour: Int = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)

    // --- Zone metrics ---
    private var zoneTransitionCount: Int = 0
    private val dwellDurations = mutableListOf<Double>()

    // --- GPS health ---
    private var totalGpsReadings: Int = 0
    private var goodGpsReadings: Int = 0

    // --- Error tracking ---
    private val errorCounts = mutableMapOf<String, Int>()

    // --- Device & config info ---
    private var deviceCategory: String? = null
    private var osVersionMajor: Int = Build.VERSION.SDK_INT
    private var batteryLevelStart: Double? = null
    private var batteryLevelEnd: Double? = null
    private var chargingDuringSession: Boolean = false
    private var accuracyProfile: String? = null
    private var updateStrategy: String? = null

    // ========================================================================
    // RECORDING METHODS — called by engines during session
    // ========================================================================

    /**
     * Record an activity change. Accumulates time spent in each activity type.
     * Call BEFORE updating the current activity.
     */
    fun recordActivityChange(activityType: String) {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            val elapsed = now - lastActivityChangeTime
            if (elapsed > 0) {
                activityTimeMs[lastTrackedActivity] =
                    (activityTimeMs[lastTrackedActivity] ?: 0L) + elapsed
            }
            lastActivityChangeTime = now
            lastTrackedActivity = activityType.lowercase()
        }
    }

    /**
     * Finalize the last activity segment. Useful for callers who want to
     * explicitly close the current activity window. Note: getSessionTelemetry()
     * snapshots activity data without calling this, so it is safe to call
     * getSessionTelemetry() without finalizing first.
     */
    fun finalizeActivityTracking() {
        recordActivityChange(lastTrackedActivity)
    }

    /**
     * Record a GPS update with the current interval and accuracy.
     */
    fun recordGpsUpdate(intervalMs: Long, accuracyM: Float) {
        synchronized(lock) {
            // Interval histogram
            val now = System.currentTimeMillis()
            val elapsed = now - lastIntervalChangeTime
            if (elapsed > 0) {
                intervalTimeMs[lastTrackedInterval] =
                    (intervalTimeMs[lastTrackedInterval] ?: 0L) + elapsed
            }
            lastIntervalChangeTime = now
            lastTrackedInterval = intervalMs
            totalIntervalMs += intervalMs
            intervalSampleCount++

            // GPS health
            totalGpsReadings++
            if (accuracyM <= 100.0f) {
                goodGpsReadings++
            }
        }
    }

    /**
     * Record a geofence event with context.
     * @param zoneId zone identifier
     * @param eventType ENTER or EXIT
     * @param distanceM distance to zone boundary in meters
     * @param speedMps device speed in m/s at event time
     * @param accuracyM GPS accuracy in meters at event time
     * @param detectionTimeMs time taken for detection in milliseconds
     */
    fun recordGeofenceEvent(
        zoneId: String,
        eventType: String,
        distanceM: Double,
        speedMps: Double,
        accuracyM: Double,
        detectionTimeMs: Double
    ) {
        synchronized(lock) {
            zoneTransitionCount++

            // Detection timing
            this.detectionTimesMs.add(detectionTimeMs)
            if (firstDetectionTimeMs == null) {
                firstDetectionTimeMs = System.currentTimeMillis() - sessionStartTime
            }

            // Event context
            eventAccuracies.add(accuracyM)
            eventSpeeds.add(speedMps)
            if (distanceM >= 0) {
                eventDistances.add(distanceM)
            }

            // Boundary events
            if (distanceM >= 0 && distanceM < BOUNDARY_THRESHOLD_M) {
                boundaryEventsCount++
            }

            // False event detection (reversal within 30s on same zone)
            val lastEvent = lastEventPerZone[zoneId]
            if (lastEvent != null) {
                val (lastType, lastTime) = lastEvent
                val timeSince = System.currentTimeMillis() - lastTime
                if (timeSince <= 30_000L && lastType != eventType) {
                    falseEventCount++
                }
            }
            lastEventPerZone[zoneId] = Pair(eventType, System.currentTimeMillis())
        }
    }

    /**
     * Record dwell completion (on EXIT, with how long device stayed inside).
     */
    fun recordDwellComplete(durationMinutes: Double) {
        synchronized(lock) { dwellDurations.add(durationMinutes) }
    }

    /**
     * Record stationary state change.
     */
    fun recordStationaryChange(isStationary: Boolean) {
        synchronized(lock) {
            if (isStationary && stationaryStartTime == null) {
                stationaryStartTime = System.currentTimeMillis()
            } else if (!isStationary && stationaryStartTime != null) {
                cumulativeStationaryMs += System.currentTimeMillis() - stationaryStartTime!!
                stationaryStartTime = null
            }
        }
    }

    /**
     * Record an error occurrence.
     */
    fun recordError(errorType: String) {
        synchronized(lock) {
            errorCounts[errorType] = (errorCounts[errorType] ?: 0) + 1
        }
    }

    /**
     * Set device info (call once at session start).
     */
    fun setDeviceInfo(category: String, osVersion: Int) {
        synchronized(lock) {
            deviceCategory = category
            osVersionMajor = osVersion
        }
    }

    /**
     * Set battery info.
     */
    fun setBatteryInfo(startPercent: Double?, endPercent: Double?, chargingDuring: Boolean) {
        synchronized(lock) {
            if (startPercent != null) batteryLevelStart = startPercent
            if (endPercent != null) batteryLevelEnd = endPercent
            chargingDuringSession = chargingDuring
        }
    }

    /**
     * Set configuration context.
     */
    fun setConfig(accuracyProfile: String, updateStrategy: String) {
        synchronized(lock) {
            this.accuracyProfile = accuracyProfile
            this.updateStrategy = updateStrategy
        }
    }

    // ========================================================================
    // OUTPUT — returns complete v2 enhanced payload (snapshot, no mutation)
    // ========================================================================

    /**
     * Returns the complete v2 enhanced session telemetry payload.
     * This matches the schema defined in intelligence/DATA_STRATEGY.md.
     *
     * This method takes a consistent snapshot of all mutable state under the lock,
     * then computes derived values outside the lock. Calling this method does NOT
     * mutate any aggregator state — safe to call multiple times.
     */
    fun getSessionTelemetry(
        geofenceEngine: GeofenceEngine? = null
    ): Map<String, Any?> {
        // Snapshot all mutable state under lock
        val now: Long
        val activitySnapshot: Map<String, Long>
        val intervalSnapshot: Map<Long, Long>
        val snapshotLastIntervalChangeTime: Long
        val snapshotLastTrackedInterval: Long
        val snapshotTotalIntervalMs: Long
        val snapshotIntervalSampleCount: Int
        val snapshotTotalStationary: Long
        val detTimesSnapshot: List<Double>
        val accuraciesSnapshot: List<Double>
        val speedsSnapshot: List<Double>
        val distancesSnapshot: List<Double>
        val dwellsSnapshot: List<Double>
        val snapshotSessionStartTime: Long
        val snapshotFirstDetectionTimeMs: Long?
        val snapshotTotalGpsReadings: Int
        val snapshotGoodGpsReadings: Int
        val snapshotFalseEventCount: Int
        val snapshotZoneTransitionCount: Int
        val snapshotBoundaryEventsCount: Int
        val snapshotErrorCounts: Map<String, Int>
        val snapshotDeviceCategory: String?
        val snapshotOsVersionMajor: Int
        val snapshotBatteryLevelStart: Double?
        val snapshotBatteryLevelEnd: Double?
        val snapshotChargingDuringSession: Boolean
        val snapshotAccuracyProfile: String?
        val snapshotUpdateStrategy: String?
        val snapshotSessionStartHour: Int

        synchronized(lock) {
            now = System.currentTimeMillis()

            // Snapshot activity distribution (finalize last segment without mutating state)
            val actSnap = HashMap(activityTimeMs)
            val actElapsed = now - lastActivityChangeTime
            if (actElapsed > 0) {
                actSnap[lastTrackedActivity] = (actSnap[lastTrackedActivity] ?: 0L) + actElapsed
            }
            activitySnapshot = actSnap

            // Snapshot interval distribution
            val intSnap = HashMap(intervalTimeMs)
            val intElapsed = now - lastIntervalChangeTime
            if (intElapsed > 0) {
                intSnap[lastTrackedInterval] = (intSnap[lastTrackedInterval] ?: 0L) + intElapsed
            }
            intervalSnapshot = intSnap
            snapshotLastIntervalChangeTime = lastIntervalChangeTime
            snapshotLastTrackedInterval = lastTrackedInterval
            snapshotTotalIntervalMs = totalIntervalMs
            snapshotIntervalSampleCount = intervalSampleCount

            // Snapshot stationary
            var totalStat = cumulativeStationaryMs
            stationaryStartTime?.let { totalStat += now - it }
            snapshotTotalStationary = totalStat

            // Snapshot lists
            detTimesSnapshot = detectionTimesMs.toList()
            accuraciesSnapshot = eventAccuracies.toList()
            speedsSnapshot = eventSpeeds.toList()
            distancesSnapshot = eventDistances.toList()
            dwellsSnapshot = dwellDurations.toList()

            // Snapshot scalars
            snapshotSessionStartTime = sessionStartTime
            snapshotFirstDetectionTimeMs = firstDetectionTimeMs
            snapshotTotalGpsReadings = totalGpsReadings
            snapshotGoodGpsReadings = goodGpsReadings
            snapshotFalseEventCount = falseEventCount
            snapshotZoneTransitionCount = zoneTransitionCount
            snapshotBoundaryEventsCount = boundaryEventsCount
            snapshotErrorCounts = errorCounts.toMap()
            snapshotDeviceCategory = deviceCategory
            snapshotOsVersionMajor = osVersionMajor
            snapshotBatteryLevelStart = batteryLevelStart
            snapshotBatteryLevelEnd = batteryLevelEnd
            snapshotChargingDuringSession = chargingDuringSession
            snapshotAccuracyProfile = accuracyProfile
            snapshotUpdateStrategy = updateStrategy
            snapshotSessionStartHour = sessionStartHour
        }

        // Compute derived values from snapshot (no lock needed)
        val sessionDurationMs = now - snapshotSessionStartTime
        val sessionDurationMinutes = sessionDurationMs / 60_000.0

        // Activity distribution
        val totalActivityMs = activitySnapshot.values.sum().toDouble()
        val activityDist = if (totalActivityMs > 0) {
            activitySnapshot.mapValues { (_, ms) -> ms / totalActivityMs }
        } else emptyMap()

        // GPS interval distribution
        val totalIntervalTimeMs = intervalSnapshot.values.sum().toDouble()
        val intervalDist = if (totalIntervalTimeMs > 0) {
            intervalSnapshot.mapKeys { (k, _) -> k.toString() }
                .mapValues { (_, ms) -> ms / totalIntervalTimeMs }
        } else emptyMap()

        // Detection stats
        val detAvg = if (detTimesSnapshot.isNotEmpty()) detTimesSnapshot.average() else 0.0
        val detP95 = if (detTimesSnapshot.isNotEmpty()) {
            val sorted = detTimesSnapshot.sorted()
            sorted[(sorted.size * 0.95).toInt().coerceAtMost(sorted.size - 1)]
        } else 0.0

        // Event context averages
        val avgAccuracyAtEvent = if (accuraciesSnapshot.isNotEmpty()) accuraciesSnapshot.average() else 0.0
        val avgSpeedAtEvent = if (speedsSnapshot.isNotEmpty()) speedsSnapshot.average() else 0.0
        val avgDistanceToBoundary = if (distancesSnapshot.isNotEmpty()) distancesSnapshot.average() else 0.0

        // False event ratio
        val totalDetections = detTimesSnapshot.size
        val falseRatio = if (totalDetections > 0) {
            snapshotFalseEventCount.toDouble() / totalDetections
        } else 0.0

        // Dwell statistics
        val avgDwell = if (dwellsSnapshot.isNotEmpty()) dwellsSnapshot.average() else 0.0
        val maxDwell = if (dwellsSnapshot.isNotEmpty()) dwellsSnapshot.max() else 0.0

        // Stationary ratio
        val stationaryRatio = if (sessionDurationMs > 0) {
            snapshotTotalStationary.toDouble() / sessionDurationMs
        } else 0.0

        // Average GPS interval
        val avgInterval = if (snapshotIntervalSampleCount > 0) {
            (snapshotTotalIntervalMs / snapshotIntervalSampleCount).toInt()
        } else 0

        // GPS OK ratio
        val gpsOk = if (snapshotTotalGpsReadings > 0) {
            snapshotGoodGpsReadings.toDouble() / snapshotTotalGpsReadings
        } else 0.0

        // Zone metrics from engine (outside lock to avoid deadlock)
        val zoneCount = geofenceEngine?.getZoneCount() ?: 0
        val zoneSizeDist = geofenceEngine?.getZoneSizeDistribution() ?: emptyMap()

        // Build the session telemetry object
        val telemetry = SessionTelemetry(
            detectionsTotal = totalDetections,
            detectionTimeAvgMs = detAvg,
            detectionTimeP95Ms = detP95,
            gpsAccuracyAvgM = avgAccuracyAtEvent,
            sessionDurationMinutes = sessionDurationMinutes,
            errorCounts = snapshotErrorCounts,
            ttfdMs = snapshotFirstDetectionTimeMs ?: 0L,
            hadDetection = totalDetections > 0,
            gpsOkRatio = gpsOk,
            sampleEvents = snapshotTotalGpsReadings,
            batteryLevelStart = snapshotBatteryLevelStart,
            batteryLevelEnd = snapshotBatteryLevelEnd,
            accuracyProfile = snapshotAccuracyProfile,
            updateStrategy = snapshotUpdateStrategy,
            activityDistribution = activityDist,
            gpsIntervalDistribution = intervalDist,
            stationaryRatio = stationaryRatio,
            avgGpsIntervalMs = avgInterval,
            falseEventCount = snapshotFalseEventCount,
            falseEventRatio = falseRatio,
            avgGpsAccuracyAtEvent = avgAccuracyAtEvent,
            avgSpeedAtEventMps = avgSpeedAtEvent,
            boundaryEventsCount = snapshotBoundaryEventsCount,
            distanceToBoundaryAvgM = avgDistanceToBoundary,
            zoneCount = zoneCount,
            zoneSizeDistribution = zoneSizeDist,
            zoneTransitionCount = snapshotZoneTransitionCount,
            avgDwellMinutes = avgDwell,
            maxDwellMinutes = maxDwell,
            dwellDurationsMinutes = dwellsSnapshot,
            deviceCategory = snapshotDeviceCategory,
            osVersionMajor = snapshotOsVersionMajor,
            chargingDuringSession = snapshotChargingDuringSession,
            sessionStartHour = snapshotSessionStartHour
        )

        return telemetry.toMap()
    }

    /**
     * Reset all telemetry for a new session.
     */
    fun resetTelemetry() {
        synchronized(lock) {
            activityTimeMs.clear()
            lastActivityChangeTime = System.currentTimeMillis()
            lastTrackedActivity = "unknown"

            intervalTimeMs.clear()
            lastIntervalChangeTime = System.currentTimeMillis()
            lastTrackedInterval = 10_000L
            totalIntervalMs = 0L
            intervalSampleCount = 0

            cumulativeStationaryMs = 0L
            stationaryStartTime = null

            eventAccuracies.clear()
            eventSpeeds.clear()
            eventDistances.clear()
            boundaryEventsCount = 0

            lastEventPerZone.clear()
            falseEventCount = 0

            detectionTimesMs.clear()
            firstDetectionTimeMs = null
            sessionStartTime = System.currentTimeMillis()
            sessionStartHour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)

            zoneTransitionCount = 0
            dwellDurations.clear()

            totalGpsReadings = 0
            goodGpsReadings = 0

            errorCounts.clear()

            batteryLevelStart = null
            batteryLevelEnd = null
            chargingDuringSession = false
        }
    }

    // ========================================================================
    // DEVICE CATEGORY HELPERS
    // ========================================================================

    companion object {
        /**
         * Determine device category from manufacturer and model.
         * Returns a bucketed category — NOT the exact device model (privacy).
         */
        fun getDeviceCategory(): String {
            val manufacturer = Build.MANUFACTURER.lowercase()
            val model = Build.MODEL.lowercase()

            return when {
                manufacturer.contains("samsung") -> when {
                    model.contains("sm-s9") || model.contains("sm-s24") ||
                    model.contains("sm-s23") || model.contains("sm-f") -> "samsung_flagship"
                    model.contains("sm-a5") || model.contains("sm-a7") ||
                    model.contains("sm-a3") -> "samsung_mid"
                    else -> "samsung_budget"
                }
                manufacturer.contains("google") || manufacturer.contains("pixel") -> "google_pixel"
                manufacturer.contains("xiaomi") || manufacturer.contains("redmi") -> "xiaomi"
                manufacturer.contains("huawei") -> "huawei"
                manufacturer.contains("oneplus") -> "oneplus"
                manufacturer.contains("oppo") -> "oppo"
                manufacturer.contains("vivo") -> "vivo"
                else -> "android_other"
            }
        }
    }
}

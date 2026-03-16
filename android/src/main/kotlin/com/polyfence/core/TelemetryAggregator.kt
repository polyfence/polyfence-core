package com.polyfence.core

import android.os.Build
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs

/**
 * Aggregates all session telemetry in the native layer (D016).
 * Each platform bridge (Flutter, RN, future) only calls getSessionTelemetry()
 * and POSTs the result — no per-bridge telemetry reimplementation needed.
 *
 * Thread-safe: all mutable state uses ConcurrentHashMap or synchronized blocks.
 */
class TelemetryAggregator {

    // --- Activity distribution ---
    private val activityTimeMs = ConcurrentHashMap<String, Long>()
    private var lastActivityChangeTime: Long = System.currentTimeMillis()
    private var lastTrackedActivity: String = "unknown"

    // --- GPS interval distribution ---
    private val intervalTimeMs = ConcurrentHashMap<Long, Long>()
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
    private var boundaryEventsCount: Int = 0
    private val BOUNDARY_THRESHOLD_M = 50.0

    // --- False event tracking ---
    private val lastEventPerZone = ConcurrentHashMap<String, Pair<String, Long>>()
    private var falseEventCount: Int = 0

    // --- Detection timing ---
    private val detectionTimesMs = mutableListOf<Double>()
    private var firstDetectionTimeMs: Long? = null
    private var sessionStartTime: Long = System.currentTimeMillis()

    // --- Zone metrics ---
    private var zoneTransitionCount: Int = 0
    private val dwellDurations = mutableListOf<Double>()

    // --- GPS health ---
    private var totalGpsReadings: Int = 0
    private var goodGpsReadings: Int = 0

    // --- Error tracking ---
    private val errorCounts = ConcurrentHashMap<String, Int>()

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
        val now = System.currentTimeMillis()
        val elapsed = now - lastActivityChangeTime
        if (elapsed > 0) {
            activityTimeMs[lastTrackedActivity] =
                (activityTimeMs[lastTrackedActivity] ?: 0L) + elapsed
        }
        lastActivityChangeTime = now
        lastTrackedActivity = activityType.lowercase()
    }

    /**
     * Finalize the last activity segment. Must be called before reading distribution.
     */
    fun finalizeActivityTracking() {
        recordActivityChange(lastTrackedActivity)
    }

    /**
     * Record a GPS update with the current interval and accuracy.
     */
    fun recordGpsUpdate(intervalMs: Long, accuracyM: Float) {
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

    /**
     * Record a geofence event with context.
     * @param isEntry true for ENTER, false for EXIT
     * @param isFalse true if this is a detected false event (reversal within 30s)
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
        zoneTransitionCount++

        // Detection timing
        synchronized(detectionTimesMs) { detectionTimesMs.add(detectionTimeMs) }
        if (firstDetectionTimeMs == null) {
            firstDetectionTimeMs = System.currentTimeMillis() - sessionStartTime
        }

        // Event context
        synchronized(eventAccuracies) { eventAccuracies.add(accuracyM) }
        synchronized(eventSpeeds) { eventSpeeds.add(speedMps) }

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

    /**
     * Record zone info for zone metrics.
     */
    fun recordZoneInfo(zoneCount: Int, zoneSizes: List<Double>) {
        // Zone sizes are recorded at session end via getSessionTelemetry
    }

    /**
     * Record dwell completion (on EXIT, with how long device stayed inside).
     */
    fun recordDwellComplete(durationMinutes: Double) {
        synchronized(dwellDurations) { dwellDurations.add(durationMinutes) }
    }

    /**
     * Record stationary state change.
     */
    fun recordStationaryChange(isStationary: Boolean) {
        if (isStationary && stationaryStartTime == null) {
            stationaryStartTime = System.currentTimeMillis()
        } else if (!isStationary && stationaryStartTime != null) {
            cumulativeStationaryMs += System.currentTimeMillis() - stationaryStartTime!!
            stationaryStartTime = null
        }
    }

    /**
     * Record an error occurrence.
     */
    fun recordError(errorType: String) {
        errorCounts[errorType] = (errorCounts[errorType] ?: 0) + 1
    }

    /**
     * Set device info (call once at session start).
     */
    fun setDeviceInfo(category: String, osVersion: Int) {
        deviceCategory = category
        osVersionMajor = osVersion
    }

    /**
     * Set battery info.
     */
    fun setBatteryInfo(startPercent: Double?, endPercent: Double?, chargingDuring: Boolean) {
        if (startPercent != null) batteryLevelStart = startPercent
        if (endPercent != null) batteryLevelEnd = endPercent
        chargingDuringSession = chargingDuring
    }

    /**
     * Set configuration context.
     */
    fun setConfig(accuracyProfile: String, updateStrategy: String) {
        this.accuracyProfile = accuracyProfile
        this.updateStrategy = updateStrategy
    }

    // ========================================================================
    // OUTPUT — returns complete v2 enhanced payload
    // ========================================================================

    /**
     * Returns the complete v2 enhanced session telemetry payload.
     * This matches the schema defined in intelligence/DATA_STRATEGY.md.
     *
     * Call finalizeActivityTracking() before this to capture the last activity segment.
     */
    fun getSessionTelemetry(
        geofenceEngine: GeofenceEngine? = null
    ): Map<String, Any?> {
        // Finalize activity tracking
        finalizeActivityTracking()

        // Finalize stationary tracking
        var totalStationary = cumulativeStationaryMs
        stationaryStartTime?.let {
            totalStationary += System.currentTimeMillis() - it
        }

        val sessionDurationMs = System.currentTimeMillis() - sessionStartTime
        val sessionDurationMinutes = sessionDurationMs / 60_000.0

        // Compute activity distribution
        val totalActivityMs = activityTimeMs.values.sum().toDouble()
        val activityDist = if (totalActivityMs > 0) {
            activityTimeMs.mapValues { (_, ms) -> ms / totalActivityMs }
        } else emptyMap()

        // Compute GPS interval distribution
        val finalIntervalTimeMs = HashMap(intervalTimeMs)
        val elapsed = System.currentTimeMillis() - lastIntervalChangeTime
        if (elapsed > 0) {
            finalIntervalTimeMs[lastTrackedInterval] =
                (finalIntervalTimeMs[lastTrackedInterval] ?: 0L) + elapsed
        }
        val totalIntervalTimeMs = finalIntervalTimeMs.values.sum().toDouble()
        val intervalDist = if (totalIntervalTimeMs > 0) {
            finalIntervalTimeMs.mapKeys { (k, _) -> k.toString() }
                .mapValues { (_, ms) -> ms / totalIntervalTimeMs }
        } else emptyMap()

        // Compute detection stats
        val detTimes = synchronized(detectionTimesMs) { detectionTimesMs.toList() }
        val detAvg = if (detTimes.isNotEmpty()) detTimes.average() else 0.0
        val detP95 = if (detTimes.isNotEmpty()) {
            val sorted = detTimes.sorted()
            sorted[(sorted.size * 0.95).toInt().coerceAtMost(sorted.size - 1)]
        } else 0.0

        // Compute event context averages
        val accuracies = synchronized(eventAccuracies) { eventAccuracies.toList() }
        val speeds = synchronized(eventSpeeds) { eventSpeeds.toList() }
        val avgAccuracyAtEvent = if (accuracies.isNotEmpty()) accuracies.average() else 0.0
        val avgSpeedAtEvent = if (speeds.isNotEmpty()) speeds.average() else 0.0

        // Compute false event ratio
        val totalDetections = detTimes.size
        val falseRatio = if (totalDetections > 0) {
            falseEventCount.toDouble() / totalDetections
        } else 0.0

        // Compute dwell average
        val dwells = synchronized(dwellDurations) { dwellDurations.toList() }
        val avgDwell = if (dwells.isNotEmpty()) dwells.average() else 0.0

        // GPS accuracy average
        val gpsAccAvg = if (accuracies.isNotEmpty()) accuracies.average() else 0.0

        // Stationary ratio
        val stationaryRatio = if (sessionDurationMs > 0) {
            totalStationary.toDouble() / sessionDurationMs
        } else 0.0

        // Average GPS interval
        val avgInterval = if (intervalSampleCount > 0) {
            (totalIntervalMs / intervalSampleCount).toInt()
        } else 0

        // Zone metrics from engine
        val zoneCount = geofenceEngine?.getZoneCount() ?: 0
        val zoneSizeDist = geofenceEngine?.getZoneSizeDistribution() ?: emptyMap()

        // Build the session telemetry object
        val telemetry = SessionTelemetry(
            detectionsTotal = totalDetections,
            detectionTimeAvgMs = detAvg,
            detectionTimeP95Ms = detP95,
            gpsAccuracyAvgM = gpsAccAvg,
            sessionDurationMinutes = sessionDurationMinutes,
            errorCounts = errorCounts.toMap(),
            ttfdMs = firstDetectionTimeMs ?: 0L,
            hadDetection = totalDetections > 0,
            gpsOkRatio = if (totalGpsReadings > 0) {
                goodGpsReadings.toDouble() / totalGpsReadings
            } else 0.0,
            sampleEvents = totalGpsReadings,
            batteryLevelStart = batteryLevelStart,
            batteryLevelEnd = batteryLevelEnd,
            accuracyProfile = accuracyProfile,
            updateStrategy = updateStrategy,
            activityDistribution = activityDist,
            gpsIntervalDistribution = intervalDist,
            stationaryRatio = stationaryRatio,
            avgGpsIntervalMs = avgInterval,
            falseEventCount = falseEventCount,
            falseEventRatio = falseRatio,
            avgGpsAccuracyAtEvent = avgAccuracyAtEvent,
            avgSpeedAtEventMps = avgSpeedAtEvent,
            boundaryEventsCount = boundaryEventsCount,
            zoneCount = zoneCount,
            zoneSizeDistribution = zoneSizeDist,
            zoneTransitionCount = zoneTransitionCount,
            avgDwellMinutes = avgDwell,
            deviceCategory = deviceCategory,
            osVersionMajor = osVersionMajor,
            chargingDuringSession = chargingDuringSession
        )

        return telemetry.toMap()
    }

    /**
     * Reset all telemetry for a new session.
     */
    fun resetTelemetry() {
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

        synchronized(eventAccuracies) { eventAccuracies.clear() }
        synchronized(eventSpeeds) { eventSpeeds.clear() }
        boundaryEventsCount = 0

        lastEventPerZone.clear()
        falseEventCount = 0

        synchronized(detectionTimesMs) { detectionTimesMs.clear() }
        firstDetectionTimeMs = null
        sessionStartTime = System.currentTimeMillis()

        zoneTransitionCount = 0
        synchronized(dwellDurations) { dwellDurations.clear() }

        totalGpsReadings = 0
        goodGpsReadings = 0

        errorCounts.clear()

        batteryLevelStart = null
        batteryLevelEnd = null
        chargingDuringSession = false
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

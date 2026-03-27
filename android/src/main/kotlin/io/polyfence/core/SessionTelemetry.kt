package io.polyfence.core

/**
 * Data class representing a complete session telemetry snapshot.
 * Output of TelemetryAggregator.getSessionTelemetry().
 * Matches the v2 enhanced telemetry payload schema from DATA_STRATEGY.md.
 */
data class SessionTelemetry(
    // --- Existing v1 fields (populated by bridge layer) ---
    // These are set by the bridge before calling toMap()
    var appIdentifier: String? = null,
    var platform: String? = null,
    var pluginVersion: String? = null,
    var industryCategory: String? = null,
    var useCase: String? = null,
    var bridgePlatform: String? = null,

    // --- Core metrics (accumulated by TelemetryAggregator) ---
    var detectionsTotal: Int = 0,
    var detectionTimeAvgMs: Double = 0.0,
    var detectionTimeP95Ms: Double = 0.0,
    var gpsAccuracyAvgM: Double = 0.0,
    var sessionDurationMinutes: Double = 0.0,

    // Zone usage
    var zoneUsage: Map<String, Int> = emptyMap(),

    // Error counts
    var errorCounts: Map<String, Int> = emptyMap(),

    // Performance
    var ttfdMs: Long = 0,
    var hadDetection: Boolean = false,
    var serviceInterruptions: Int = 0,
    var gpsOkRatio: Double = 0.0,
    var sampleEvents: Int = 0,

    // Battery
    var batteryOptimizationDisabled: Boolean = false,
    var batteryLevelStart: Double? = null,
    var batteryLevelEnd: Double? = null,

    // --- v2 Enhanced fields (D016 — accumulated in native layer) ---

    // Config context
    var accuracyProfile: String? = null,
    var updateStrategy: String? = null,

    // Activity distribution (proportions summing to ~1.0)
    var activityDistribution: Map<String, Double> = emptyMap(),

    // GPS interval distribution (interval_ms_string -> proportion)
    var gpsIntervalDistribution: Map<String, Double> = emptyMap(),
    var stationaryRatio: Double = 0.0,
    var avgGpsIntervalMs: Int = 0,

    // False event tracking
    var falseEventCount: Int = 0,
    var falseEventRatio: Double = 0.0,
    var avgGpsAccuracyAtEvent: Double = 0.0,
    var avgSpeedAtEventMps: Double = 0.0,
    var boundaryEventsCount: Int = 0,
    var distanceToBoundaryAvgM: Double = 0.0,

    // Zone metrics
    var zoneCount: Int = 0,
    var zoneSizeDistribution: Map<String, Int> = emptyMap(),
    var zoneTransitionCount: Int = 0,
    var avgDwellMinutes: Double = 0.0,
    var maxDwellMinutes: Double = 0.0,
    var dwellDurationsMinutes: List<Double> = emptyList(),

    // Device info
    var deviceCategory: String? = null,
    var osVersionMajor: Int = 0,
    var chargingDuringSession: Boolean = false,
    var sessionStartHour: Int = 0
) {
    /**
     * Convert to Map for JSON serialization.
     * Returns the complete v2 enhanced payload matching DATA_STRATEGY.md schema.
     */
    fun toMap(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()

        // v1 fields
        appIdentifier?.let { map["app_identifier"] = it }
        platform?.let { map["platform"] = it }
        pluginVersion?.let { map["plugin_version"] = it }
        industryCategory?.let { map["industry_category"] = it }
        useCase?.let { map["use_case"] = it }
        bridgePlatform?.let { map["bridge_platform"] = it }

        map["detections_total"] = detectionsTotal
        map["detection_time_avg_ms"] = detectionTimeAvgMs
        map["detection_time_p95_ms"] = detectionTimeP95Ms
        map["gps_accuracy_avg_m"] = gpsAccuracyAvgM
        map["session_duration_minutes"] = sessionDurationMinutes

        map["zone_usage"] = zoneUsage
        map["error_counts"] = errorCounts

        map["ttfd_ms"] = ttfdMs
        map["had_detection"] = hadDetection
        map["service_interruptions"] = serviceInterruptions
        map["gps_ok_ratio"] = gpsOkRatio
        map["sample_events"] = sampleEvents

        map["battery_optimization_disabled"] = batteryOptimizationDisabled
        batteryLevelStart?.let { map["battery_level_start"] = it }
        batteryLevelEnd?.let { map["battery_level_end"] = it }

        // v2 enhanced fields
        accuracyProfile?.let { map["accuracy_profile"] = it }
        updateStrategy?.let { map["update_strategy"] = it }

        if (activityDistribution.isNotEmpty()) {
            map["activity_distribution"] = activityDistribution
        }
        if (gpsIntervalDistribution.isNotEmpty()) {
            map["gps_interval_distribution"] = gpsIntervalDistribution
        }
        map["stationary_ratio"] = stationaryRatio
        map["avg_gps_interval_ms"] = avgGpsIntervalMs

        map["false_event_count"] = falseEventCount
        map["false_event_ratio"] = falseEventRatio
        map["avg_gps_accuracy_at_event"] = avgGpsAccuracyAtEvent
        map["avg_speed_at_event_mps"] = avgSpeedAtEventMps
        map["boundary_events_count"] = boundaryEventsCount
        map["distance_to_boundary_avg_m"] = distanceToBoundaryAvgM

        map["zone_count"] = zoneCount
        if (zoneSizeDistribution.isNotEmpty()) {
            map["zone_size_distribution"] = zoneSizeDistribution
        }
        map["zone_transition_count"] = zoneTransitionCount
        map["avg_dwell_duration_minutes"] = avgDwellMinutes
        map["max_dwell_duration_minutes"] = maxDwellMinutes
        if (dwellDurationsMinutes.isNotEmpty()) {
            map["dwell_durations_minutes"] = dwellDurationsMinutes
        }

        deviceCategory?.let { map["device_category"] = it }
        map["os_version_major"] = osVersionMajor
        map["charging_during_session"] = chargingDuringSession
        map["session_start_hour"] = sessionStartHour

        return map
    }
}

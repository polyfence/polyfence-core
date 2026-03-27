import Foundation

/// Data model for a complete session telemetry snapshot.
/// Output of TelemetryAggregator.getSessionTelemetry().
/// Matches the v2 enhanced telemetry payload schema from DATA_STRATEGY.md.
struct SessionTelemetry {
    // --- Existing v1 fields (populated by bridge layer) ---
    var appIdentifier: String? = nil
    var platform: String? = nil
    var pluginVersion: String? = nil
    var industryCategory: String? = nil
    var useCase: String? = nil
    var bridgePlatform: String? = nil

    // --- Core metrics ---
    var detectionsTotal: Int = 0
    var detectionTimeAvgMs: Double = 0.0
    var detectionTimeP95Ms: Double = 0.0
    var gpsAccuracyAvgM: Double = 0.0
    var sessionDurationMinutes: Double = 0.0

    var zoneUsage: [String: Int] = [:]
    var errorCounts: [String: Int] = [:]

    var ttfdMs: Int64 = 0
    var hadDetection: Bool = false
    var serviceInterruptions: Int = 0
    var gpsOkRatio: Double = 0.0
    var sampleEvents: Int = 0

    var batteryOptimizationDisabled: Bool = false
    var batteryLevelStart: Double? = nil
    var batteryLevelEnd: Double? = nil

    // --- v2 Enhanced fields (D016) ---
    var accuracyProfile: String? = nil
    var updateStrategy: String? = nil

    var activityDistribution: [String: Double] = [:]
    var gpsIntervalDistribution: [String: Double] = [:]
    var stationaryRatio: Double = 0.0
    var avgGpsIntervalMs: Int = 0

    var falseEventCount: Int = 0
    var falseEventRatio: Double = 0.0
    var avgGpsAccuracyAtEvent: Double = 0.0
    var avgSpeedAtEventMps: Double = 0.0
    var boundaryEventsCount: Int = 0
    var distanceToBoundaryAvgM: Double = 0.0

    var zoneCount: Int = 0
    var zoneSizeDistribution: [String: Int] = [:]
    var zoneTransitionCount: Int = 0
    var avgDwellMinutes: Double = 0.0
    var maxDwellMinutes: Double = 0.0
    var dwellDurationsMinutes: [Double] = []

    var deviceCategory: String? = nil
    var osVersionMajor: Int = 0
    var chargingDuringSession: Bool = false
    var sessionStartHour: Int = 0

    /// Convert to dictionary for JSON serialization.
    /// Returns the complete v2 enhanced payload matching DATA_STRATEGY.md schema.
    func toMap() -> [String: Any] {
        var map: [String: Any] = [:]

        if let v = appIdentifier { map["app_identifier"] = v }
        if let v = platform { map["platform"] = v }
        if let v = pluginVersion { map["plugin_version"] = v }
        if let v = industryCategory { map["industry_category"] = v }
        if let v = useCase { map["use_case"] = v }
        if let v = bridgePlatform { map["bridge_platform"] = v }

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
        if let v = batteryLevelStart { map["battery_level_start"] = v }
        if let v = batteryLevelEnd { map["battery_level_end"] = v }

        if let v = accuracyProfile { map["accuracy_profile"] = v }
        if let v = updateStrategy { map["update_strategy"] = v }

        if !activityDistribution.isEmpty { map["activity_distribution"] = activityDistribution }
        if !gpsIntervalDistribution.isEmpty { map["gps_interval_distribution"] = gpsIntervalDistribution }
        map["stationary_ratio"] = stationaryRatio
        map["avg_gps_interval_ms"] = avgGpsIntervalMs

        map["false_event_count"] = falseEventCount
        map["false_event_ratio"] = falseEventRatio
        map["avg_gps_accuracy_at_event"] = avgGpsAccuracyAtEvent
        map["avg_speed_at_event_mps"] = avgSpeedAtEventMps
        map["boundary_events_count"] = boundaryEventsCount

        map["zone_count"] = zoneCount
        if !zoneSizeDistribution.isEmpty { map["zone_size_distribution"] = zoneSizeDistribution }
        map["zone_transition_count"] = zoneTransitionCount
        map["avg_dwell_duration_minutes"] = avgDwellMinutes
        map["max_dwell_duration_minutes"] = maxDwellMinutes
        if !dwellDurationsMinutes.isEmpty { map["dwell_durations_minutes"] = dwellDurationsMinutes }

        map["distance_to_boundary_avg_m"] = distanceToBoundaryAvgM

        if let v = deviceCategory { map["device_category"] = v }
        map["os_version_major"] = osVersionMajor
        map["charging_during_session"] = chargingDuringSession
        map["session_start_hour"] = sessionStartHour

        return map
    }
}

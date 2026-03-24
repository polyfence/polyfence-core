import Foundation

/// Data model for a complete session telemetry snapshot.
/// Output of TelemetryAggregator.getSessionTelemetry().
/// Matches the v2 enhanced telemetry payload schema from DATA_STRATEGY.md.
struct SessionTelemetry {
    // --- Existing v1 fields (populated by bridge layer) ---
    let appIdentifier: String?
    let platform: String?
    let pluginVersion: String?
    let industryCategory: String?
    let useCase: String?

    // --- Core metrics ---
    let detectionsTotal: Int
    let detectionTimeAvgMs: Double
    let detectionTimeP95Ms: Double
    let gpsAccuracyAvgM: Double
    let sessionDurationMinutes: Double

    let zoneUsage: [String: Int]
    let errorCounts: [String: Int]

    let ttfdMs: Int64
    let hadDetection: Bool
    let serviceInterruptions: Int
    let gpsOkRatio: Double
    let sampleEvents: Int

    let batteryOptimizationDisabled: Bool
    let batteryLevelStart: Double?
    let batteryLevelEnd: Double?

    // --- v2 Enhanced fields (D016) ---
    let accuracyProfile: String?
    let updateStrategy: String?

    let activityDistribution: [String: Double]
    let gpsIntervalDistribution: [String: Double]
    let stationaryRatio: Double
    let avgGpsIntervalMs: Int

    let falseEventCount: Int
    let falseEventRatio: Double
    let avgGpsAccuracyAtEvent: Double
    let avgSpeedAtEventMps: Double
    let boundaryEventsCount: Int

    let zoneCount: Int
    let zoneSizeDistribution: [String: Int]
    let zoneTransitionCount: Int
    let avgDwellMinutes: Double

    let deviceCategory: String?
    let osVersionMajor: Int
    let chargingDuringSession: Bool

    /// Convert to dictionary for JSON serialization.
    /// Returns the complete v2 enhanced payload matching DATA_STRATEGY.md schema.
    func toMap() -> [String: Any] {
        var map: [String: Any] = [:]

        if let v = appIdentifier { map["app_identifier"] = v }
        if let v = platform { map["platform"] = v }
        if let v = pluginVersion { map["plugin_version"] = v }
        if let v = industryCategory { map["industry_category"] = v }
        if let v = useCase { map["use_case"] = v }

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
        map["avg_dwell_minutes"] = avgDwellMinutes

        if let v = deviceCategory { map["device_category"] = v }
        map["os_version_major"] = osVersionMajor
        map["charging_during_session"] = chargingDuringSession

        return map
    }
}

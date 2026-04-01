import Foundation

/**
 * Centralized configuration management for Polyfence iOS
 * Single responsibility: Runtime configuration and persistence
 * iOS counterpart of Android PolyfenceConfig.kt
 */
public class PolyfenceConfig {

    private static let TAG = "PolyfenceConfig"
    private static let suiteName = "polyfence_config"

    // MARK: - Default GPS Configuration
    public static let DEFAULT_GPS_INTERVAL_MS: Int = 5000
    public static let DEFAULT_GPS_ACCURACY_THRESHOLD: Double = 100.0
    public static let DEFAULT_MIN_UPDATE_INTERVAL_MS: Int = 1000
    public static let DEFAULT_MAX_UPDATE_DELAY_MS: Int = 6000
    public static let MIN_UPDATE_DISTANCE_METERS: Double = 10.0

    // MARK: - Zone Validation Configuration
    static let DEFAULT_CONFIDENCE_POINTS: Int = 2
    static let DEFAULT_CONFIDENCE_TIMEOUT_MS: Int = 10000
    static let DEFAULT_REQUIRE_CONFIRMATION: Bool = true
    static let LARGE_ZONE_RADIUS_THRESHOLD_METERS: Double = 200.0
    static let MIN_SINGLE_POINT_ZONE_RADIUS_METERS: Double = 50.0
    static let MIN_POLYGON_POINTS: Int = 3

    // MARK: - Speed and Movement Thresholds
    static let HIGH_SPEED_THRESHOLD_KMH: Double = 40.0
    static let SPEED_MS_TO_KMH_MULTIPLIER: Double = 3.6

    // MARK: - GPS Health and Recovery
    static let MAX_GPS_FAILURES_BEFORE_COOLDOWN: Int = 2
    static let MIN_GPS_FAILURES_FOR_RECOVERY: Int = 3
    static let MAX_GPS_FAILURES_FOR_RECOVERY: Int = 5
    static let GPS_HEALTH_CHECK_TIMEOUT_MS: Int = 120000
    static let HEALTH_CHECK_INTERVAL_MS: Int = 30000
    static let GPS_RESTART_DELAY_MS: Int = 3000
    static let SERVICE_RESTART_DELAY_MS: Int = 5000

    // MARK: - GPS Restart Configuration
    static let MIN_GPS_RESTART_INTERVAL_MS: Int = 10000
    static let MIN_UPDATE_RESTART_INTERVAL_MS: Int = 5000
    static let MAX_UPDATE_RESTART_DELAY_MS: Int = 15000

    // MARK: - Validation Ranges
    static let MIN_GPS_INTERVAL_MS: Int = 1000
    static let MAX_GPS_INTERVAL_MS: Int = 60000
    static let MIN_ACCURACY_THRESHOLD: Double = 1.0
    static let MAX_ACCURACY_THRESHOLD: Double = 500.0
    static let MIN_CONFIDENCE_POINTS_RANGE: Int = 1
    static let MAX_CONFIDENCE_POINTS_RANGE: Int = 5

    // MARK: - Persistence

    private let defaults: UserDefaults

    public init() {
        self.defaults = UserDefaults(suiteName: PolyfenceConfig.suiteName) ?? UserDefaults.standard
    }

    // MARK: - GPS Configuration Properties

    public var gpsIntervalMs: Int {
        get {
            let val = defaults.integer(forKey: "gps_interval_ms")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_GPS_INTERVAL_MS
        }
        set { defaults.set(newValue, forKey: "gps_interval_ms") }
    }

    public var gpsAccuracyThreshold: Double {
        get {
            let val = defaults.double(forKey: "gps_accuracy_threshold")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_GPS_ACCURACY_THRESHOLD
        }
        set { defaults.set(newValue, forKey: "gps_accuracy_threshold") }
    }

    public var minUpdateIntervalMs: Int {
        get {
            let val = defaults.integer(forKey: "min_update_interval_ms")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_MIN_UPDATE_INTERVAL_MS
        }
        set { defaults.set(newValue, forKey: "min_update_interval_ms") }
    }

    public var maxUpdateDelayMs: Int {
        get {
            let val = defaults.integer(forKey: "max_update_delay_ms")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_MAX_UPDATE_DELAY_MS
        }
        set { defaults.set(newValue, forKey: "max_update_delay_ms") }
    }

    // MARK: - Validation Configuration Properties

    public var requireConfirmation: Bool {
        get {
            if defaults.object(forKey: "require_confirmation") != nil {
                return defaults.bool(forKey: "require_confirmation")
            }
            return PolyfenceConfig.DEFAULT_REQUIRE_CONFIRMATION
        }
        set { defaults.set(newValue, forKey: "require_confirmation") }
    }

    public var confidencePoints: Int {
        get {
            let val = defaults.integer(forKey: "confidence_points")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_CONFIDENCE_POINTS
        }
        set { defaults.set(newValue, forKey: "confidence_points") }
    }

    public var confidenceTimeoutMs: Int {
        get {
            let val = defaults.integer(forKey: "confidence_timeout_ms")
            return val != 0 ? val : PolyfenceConfig.DEFAULT_CONFIDENCE_TIMEOUT_MS
        }
        set { defaults.set(newValue, forKey: "confidence_timeout_ms") }
    }

    // MARK: - Operations

    public func resetToDefaults() {
        guard let suiteName = defaults.persistentDomain(forName: PolyfenceConfig.suiteName) else { return }
        for key in suiteName.keys {
            defaults.removeObject(forKey: key)
        }
    }

    public func getConfigurationMap() -> [String: Any] {
        return [
            "gps_interval_ms": gpsIntervalMs,
            "gps_accuracy_threshold": gpsAccuracyThreshold,
            "min_update_interval_ms": minUpdateIntervalMs,
            "max_update_delay_ms": maxUpdateDelayMs,
            "require_confirmation": requireConfirmation,
            "confidence_points": confidencePoints,
            "confidence_timeout_ms": confidenceTimeoutMs
        ]
    }

    public func updateFromMap(_ configMap: [String: Any]) {
        if let val = configMap["gps_interval_ms"] as? Int { gpsIntervalMs = val }
        if let val = configMap["gps_accuracy_threshold"] as? Double { gpsAccuracyThreshold = val }
        if let val = configMap["min_update_interval_ms"] as? Int { minUpdateIntervalMs = val }
        if let val = configMap["max_update_delay_ms"] as? Int { maxUpdateDelayMs = val }
        if let val = configMap["require_confirmation"] as? Bool { requireConfirmation = val }
        if let val = configMap["confidence_points"] as? Int { confidencePoints = val }
        if let val = configMap["confidence_timeout_ms"] as? Int { confidenceTimeoutMs = val }
    }
}

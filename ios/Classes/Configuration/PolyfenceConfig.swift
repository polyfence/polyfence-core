import Foundation

/**
 * Centralized configuration management for Polyfence iOS
 * Single responsibility: Runtime configuration and persistence
 * iOS counterpart of Android PolyfenceConfig.kt
 *
 * ## Every field here must be written by updateConfigurationFromMap
 *
 * This class is the only thing that survives process death. The OS can
 * relaunch a killed process — on a region crossing, on a significant location
 * change — and run library code before any bridge has had the chance to
 * re-apply configuration. Whatever is not persisted here reads as its
 * compile-time default in that window.
 *
 * A field that is applied to an in-memory property but not written back here
 * therefore appears to work in every test and in every foreground session, and
 * silently reverts in exactly the scenario the durable-queue and wake-fence
 * features exist for. Adding a config field means adding it in three places:
 * this class, the write path in `LocationTracker.updateConfigurationFromMap`,
 * and the read path in `setupGeofenceEngine`. The Android `PolyfenceConfig`
 * carries the same rule.
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

    // MARK: - OS Wake-Fence Slot Allocation
    // Apple monitors at most 20 CLCircularRegions per app. Default and ceiling
    // are the same value because there is no headroom to hand out.
    public static let DEFAULT_OS_GEOFENCE_MAX_REGIONS: Int = 20
    public static let DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS: Int = 20

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

    // Degraded-GPS handling. 0 = off (default). When > 0, a low-accuracy fix may
    // drive EXITs (Option D) and, after this many ms with no valid fix while
    // inside a zone, the staleness watchdog emits SIGNAL_LOST. One knob gates
    // both behaviours.
    public var gpsStalenessTimeoutMs: Double {
        get { return defaults.double(forKey: "gps_staleness_timeout_ms") }
        set { defaults.set(newValue, forKey: "gps_staleness_timeout_ms") }
    }

    // Durable pending-events queue cap. 0 = off (default). When > 0, geofence
    // events fired while the bridge sink is not receiving are persisted to disk
    // in a bounded ring buffer; oldest events evict on overflow. Drained by the
    // consumer via LocationTracker.drainPendingEvents.
    public var pendingEventsQueueSize: Int {
        get { return defaults.integer(forKey: "pending_events_queue_size") }
        set { defaults.set(newValue, forKey: "pending_events_queue_size") }
    }

    // Automatic delivery of queued events. true = on (default) — the moment a
    // consumer signals a live event listener, the queue is drained and replayed
    // through the normal event callback. false leaves the queue pull-only, so
    // nothing is delivered until the consumer calls
    // LocationTracker.drainPendingEvents itself. Only has an effect while
    // pendingEventsQueueSize > 0.
    // Reads through `object(forKey:)` because `bool(forKey:)` cannot tell an
    // absent key from a stored `false`, and this default is `true`.
    public var pendingEventsAutoDrainEnabled: Bool {
        get {
            if defaults.object(forKey: "pending_events_auto_drain_enabled") != nil {
                return defaults.bool(forKey: "pending_events_auto_drain_enabled")
            }
            return true
        }
        set { defaults.set(newValue, forKey: "pending_events_auto_drain_enabled") }
    }

    // OS wake-fence registration. false = off (default) — Polyfence's own polling
    // engine is the sole detector; nothing is registered with the OS. When true,
    // the top-N-nearest active zones are registered with CLLocationManager
    // region monitoring so an OS-side callback can wake the app after full
    // process kill and enqueue the crossing into the pending-events queue for
    // drain-on-next-boot. Requires "Always" location authorization granted by
    // the consumer app and the corresponding Info.plist usage description.
    public var osGeofenceWakeEnabled: Bool {
        get { return defaults.bool(forKey: "os_geofence_wake_enabled") }
        set { defaults.set(newValue, forKey: "os_geofence_wake_enabled") }
    }

    // How many OS geofence slots Polyfence may occupy while the app is
    // backgrounded. Unlike Android there is nothing to tune here: iOS hard-caps
    // simultaneously-monitored CLCircularRegions at 20 per app, so the default
    // is already the ceiling and any higher value is clamped. The field exists
    // so the configuration surface stays identical across platforms and so a
    // consumer that registers its own regions can lower it.
    // Clamped on write so the persisted value is always the value that will
    // actually be applied. Storing the raw request instead would make
    // getConfiguration() echo a budget the registrar never uses, and would
    // leave consumers with no way to discover the effective one. The clamp
    // guarantees a stored value is never 0, so treating 0 as "unset" below
    // cannot swallow a deliberate setting.
    public var osGeofenceMaxRegions: Int {
        get {
            let stored = defaults.integer(forKey: "os_geofence_max_regions")
            return stored != 0 ? stored : PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        }
        set {
            defaults.set(
                PolyfenceConfig.clampOsGeofenceMaxRegions(newValue),
                forKey: "os_geofence_max_regions"
            )
        }
    }

    /// Constrains a slot budget to what the platform will honour. iOS silently
    /// declines regions past its per-app cap, so passing a raw value through
    /// would report coverage that does not exist. Kept identical in shape to
    /// the Android clamp so the same consumer value produces the same
    /// effective budget on both platforms.
    public static func clampOsGeofenceMaxRegions(_ requested: Int) -> Int {
        return min(max(requested, 1), DEFAULT_OS_GEOFENCE_PLATFORM_MAX_REGIONS)
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
            "confidence_timeout_ms": confidenceTimeoutMs,
            "gps_staleness_timeout_ms": gpsStalenessTimeoutMs
        ]
    }

    public func updateFromMap(_ configMap: [String: Any]) {
        if let val = configMap["gps_interval_ms"] as? Int { gpsIntervalMs = val }
        if let val = configMap["gps_accuracy_threshold"] as? Double { gpsAccuracyThreshold = val }
        if let val = configMap["gps_staleness_timeout_ms"] as? Double { gpsStalenessTimeoutMs = val }
        if let val = configMap["min_update_interval_ms"] as? Int { minUpdateIntervalMs = val }
        if let val = configMap["max_update_delay_ms"] as? Int { maxUpdateDelayMs = val }
        if let val = configMap["require_confirmation"] as? Bool { requireConfirmation = val }
        if let val = configMap["confidence_points"] as? Int { confidencePoints = val }
        if let val = configMap["confidence_timeout_ms"] as? Int { confidenceTimeoutMs = val }
    }
}

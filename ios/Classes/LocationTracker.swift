import Foundation
import CoreLocation
import UserNotifications
import os
#if canImport(UIKit)
import UIKit
#endif

// GeoMath is already available in the same module

// Diagnostic forensics — Xcode > Window > Devices and Simulators > Open
// Console, then search `subsystem:io.polyfence.core` to see real-time.
// All at .error so they survive the default Console filter; remove once
// background-event-delivery is stable.
private let pfCoreLog = OSLog(subsystem: "io.polyfence.core", category: "tracker")

/**
 * Background location tracking service for iOS
 * Single responsibility: GPS updates -> GeofenceEngine -> Notifications
 * Ported from Android LocationTracker.kt
 */
public class LocationTracker: NSObject {

    // MARK: - Constants
    private static let TAG = "LocationTracker"
    private static let NOTIFICATION_ID = 1001
    private static let CHANNEL_ID = "polyfence_tracking"
    private static let GEOFENCE_CHANNEL_ID = "polyfence_alerts"

    // MARK: - Properties
    private var locationManager: CLLocationManager?
    private let geofenceEngine = GeofenceEngine()
    private var zonePersistence: ZonePersistence?
    private var config: PolyfenceConfig?

    /// Centralized telemetry aggregator
    let telemetryAggregator = TelemetryAggregator()

    // Error Recovery Properties
    private var lastLocationTime: TimeInterval = 0
    private var consecutiveGpsFailures: Int = 0
    private var isRunning: Bool = false

    /// Whether the tracker is currently running
    public func isTracking() -> Bool {
        return isRunning
    }
    private var pendingStartAfterAuthorization: Bool = false

    // GPS Health Tracking
    private var currentGpsAccuracy: Double?
    private var gpsAvailabilityDropTimestamps: [TimeInterval] = []
    private var lastGpsUnreliableErrorTime: TimeInterval = 0
    private let gpsUnreliableErrorCooldownSeconds: TimeInterval = 60.0 // Emit error max once per minute

    // CRITICAL: Prevent auto-tracking to match Android behavior
    private var trackingEnabled: Bool = false
    private var fallbackTimer: Timer?
    private let geofenceQueue = DispatchQueue(label: "polyfence.geofence", qos: .userInitiated)

    // Track last location where zone check was performed
    private var lastZoneCheckLocation: CLLocation?
    private let minMovementForZoneCheckMeters: CLLocationDistance = 5.0  // Only recheck zones if moved >5m

    // Defer GPS start until zones exist
    private var gpsStartDeferred: Bool = false

    // Throttle delegate callbacks when stationary
    private var lastDelegateCallbackTime: TimeInterval = 0
    private let stationaryDelegateCallbackInterval: TimeInterval = 30.0  // 30s when stationary
    // CPU usage tracking state
    private var prevCpuTotal: UInt32 = 0
    private var prevCpuIdle: UInt32 = 0

    // Notification properties
    private var notificationCenter: UNUserNotificationCenter?
    private var healthTimer: Timer?
    private var healthScoreTimer: Timer?

    // Callbacks
    private var locationCallback: (([String: Any]) -> Void)?
    private var geofenceCallback: (([String: Any]) -> Void)?

    // Core delegate for platform bridge communication
    public weak var coreDelegate: PolyfenceCoreDelegate?

    // Smart GPS Configuration
    private var smartConfig = SmartGpsConfig()
    private var currentGpsInterval: TimeInterval = 5.0
    private var isStationary: Bool = false

    // ML Telemetry: GPS interval distribution (seconds -> time spent)
    private var intervalTime: [String: TimeInterval] = [:]
    private var lastIntervalChangeTime: TimeInterval = Date().timeIntervalSince1970
    private var lastTrackedIntervalMs: Int = 5000
    private var totalIntervalMs: Int = 0
    private var intervalSampleCount: Int = 0

    // ML Telemetry: stationary tracking
    private var cumulativeStationaryTime: TimeInterval = 0
    private var stationaryStartTime: TimeInterval?
    private var trackingStartTime: TimeInterval = Date().timeIntervalSince1970
    private var lastKnownLocation: CLLocation?

    // Movement tracking for stationary detection (independent of movementSettings)
    private var lastMovementLocation: CLLocation?
    private var lastMovementTime: TimeInterval = 0

    // Runtime Status Emission
    private var lastEmittedStatus: [String: Any] = [:]
    private var lastStatusEmitTime: TimeInterval = 0

    // Alert Notifications Control
    private var alertNotificationsEnabled: Bool = true

    // Activity Recognition
    private var activityRecognitionManager: ActivityRecognitionManager?
    private var activitySettings: ActivitySettings = ActivitySettings()
    private var currentActivity: ActivityType = .unknown

    // Battery snapshot for telemetry drain calculation. Captured at every
    // session-start: init() (first session) and every resetTelemetry()
    // (subsequent sessions, when TelemetryAggregator restarts
    // sessionStartTime and nulls its own batteryLevelStart). Paired with a
    // fresh read at every getSessionTelemetryData() call. Without this
    // capture, batteryLevelStart stays nil on the aggregator → omitted from
    // the telemetry payload → drain field comes back null on every session.
    //
    // Guarded by batteryLock for parity with Android's @Volatile on the
    // corresponding fields — init/resetTelemetry/getSessionTelemetryData
    // can be invoked from different queues (location callbacks vs bridge
    // method dispatch), and an unsynchronized read of a stale start would
    // produce one cycle of slightly-wrong drain.
    private var batterySnapshotAtStart: Double? = nil
    private var chargingAtStart: Bool = false
    private let batteryLock = NSLock()

    public override init() {
        super.init()
        // Enable battery monitoring before anything else in init so the
        // OS has had as much time as possible to populate batteryLevel by
        // the time captureBatterySessionStart() reads it below. iOS reports
        // -1 immediately after enabling monitoring; getBatteryLevel coerces
        // that to 100, so a too-fresh enable + read in the same tick can
        // give a stale 100 on first session. Enabling here keeps the
        // window before the read as wide as the rest of init takes.
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Initialize persistence first so it's available for geofence engine
        zonePersistence = ZonePersistence()
        setupLocationManager()
        setupNotificationCenter()
        setupGeofenceEngine()

        // Initialize tracking scheduler and load saved config
        TrackingScheduler.shared.setLocationTracker(self)
        TrackingScheduler.shared.loadConfig()

        // Capture battery snapshot for telemetry drain calculation. Done here
        // so it aligns with TelemetryAggregator's sessionStartTime. The
        // matching end-snapshot + setBatteryInfo call lives in
        // getSessionTelemetryData() below; subsequent sessions re-capture
        // via resetTelemetry().
        captureBatterySessionStart()
    }

    /**
     * Refresh the battery start-snapshot for a new telemetry session.
     * Called from init() for the first session and from resetTelemetry()
     * for every subsequent session — without the resetTelemetry path, the
     * start value goes stale after the first session while the aggregator's
     * sessionStartTime restarts, producing a meaningless drain rate over
     * sessions 2..N.
     */
    private func captureBatterySessionStart() {
        let level = getBatteryLevel()
        let charging = UIDevice.current.batteryState == .charging
            || UIDevice.current.batteryState == .full
        batteryLock.lock()
        defer { batteryLock.unlock() }
        batterySnapshotAtStart = level
        chargingAtStart = charging
    }

    // MARK: - Setup Methods

    private func setupLocationManager() {
        // Apple delivers CLLocationManager's async delegate callbacks
        // (didUpdateLocations, didChangeAuthorization, didFailWithError, etc.)
        // via the run loop of the thread on which the manager was created.
        // The bridge that constructs LocationTracker may not be on such a
        // thread. React Native 0.76+ in Bridgeless / New Arch dispatches
        // RCTEventEmitter method invocations on a runloop-less background
        // dispatch queue by default; LocationTracker.init() runs there, the
        // manager is created there, and CL has no runloop to post callbacks
        // to. Symptom: iOS buffers and then discards updates with
        // `Location callback block not executed in a timely manner` and
        // `Discarding message for event because of too many unprocessed
        // messages, count:N`. Flutter does not hit this because
        // FlutterMethodChannel dispatches plugin calls on a thread that
        // does have a runloop. Force construction onto the main thread
        // (which always has a runloop) so callback delivery works
        // regardless of which bridge instantiates us. .sync (not .async)
        // because callers rely on `locationManager` being non-nil
        // immediately after init() returns (e.g. startTracking() guards on
        // it and bails out otherwise). No-op when already on main.
        // Deadlock assumption: this `.sync` is safe because (a) the
        // `Thread.isMainThread` gate above prevents calling `.sync` from main
        // (the canonical self-deadlock), and (b) `LocationTracker.init()` is
        // only invoked from bridge-init entry points (PolyfenceModule.initialize
        // on RN; Flutter plugin registration). Those entry points run on a
        // dispatch queue, not under any lock or semaphore that main is itself
        // waiting on, so blocking the calling thread until main has executed
        // this block cannot deadlock.
        if !Thread.isMainThread {
            DispatchQueue.main.sync { self.setupLocationManager() }
            return
        }
        // os_log (not NSLog) with %{public} so the marker survives the
        // release-build privacy redaction that would otherwise show as
        // `<private>` in idevicesyslog / Console.app.
        os_log("PF-THREAD setupLocationManager isMain=%{public}d", Thread.isMainThread ? 1 : 0)
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        // Use smartConfig defaults for initial setup (BALANCED profile by default)
        locationManager?.desiredAccuracy = smartConfig.getCLLocationAccuracy()
        locationManager?.distanceFilter = smartConfig.getDistanceFilter()
        locationManager?.pausesLocationUpdatesAutomatically = smartConfig.shouldPauseAutomatically()
        locationManager?.activityType = .otherNavigation

        if #available(iOS 9.0, *) {
            locationManager?.allowsBackgroundLocationUpdates = true
        }
    }

    private func setupNotificationCenter() {
        notificationCenter = UNUserNotificationCenter.current()

        // Set delegate to enable foreground notification delivery
        notificationCenter?.delegate = self

        // Request standard notification permissions (no critical alerts)
        notificationCenter?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        createNotificationCategories()
    }

    private func setupGeofenceEngine() {
        // Setup geofence engine callback
        geofenceEngine.setEventCallback { [weak self] zoneId, eventType, location, detectionTimeMs in
            self?.handleGeofenceEvent(zoneId: zoneId, eventType: eventType, location: location, detectionTimeMs: detectionTimeMs)
        }

        // Wire up zone persistence for state recovery across service restarts
        if let persistence = zonePersistence {
            geofenceEngine.setZonePersistence(persistence)
        }

        // Configure validation using config (opt for immediate detection to verify pipeline)
        geofenceEngine.setValidationConfig(requireConfirmation: false, confirmationPoints: 1)

        // Set GPS accuracy threshold from config (default: 100m for platform parity)
        let accuracyThreshold = config?.gpsAccuracyThreshold ?? PolyfenceConfig.DEFAULT_GPS_ACCURACY_THRESHOLD
        geofenceEngine.setGpsAccuracyThreshold(accuracyThreshold)
    }

    // Track if first location after restart has been processed
    private var firstLocationAfterRestart = true

    // MARK: - Public Methods

    /**
     * Start location tracking
     */
    public func startTracking() {
        os_log("startTracking() zoneCount=%{public}d hasLocMgr=%{public}d",
               log: pfCoreLog, type: .error,
               geofenceEngine.getZoneCount(), locationManager != nil ? 1 : 0)
        guard locationManager != nil else {
            os_log("startTracking ABORT: locationManager is nil",
                   log: pfCoreLog, type: .error)
            return
        }

        isRunning = true
        trackingEnabled = true
        firstLocationAfterRestart = true  // Reset for state reconciliation

        // NOTE: We do NOT call `UIApplication.beginBackgroundTask` here.
        // That API is for short, finite work (≤30s) that must complete
        // after the app moves to background; iOS warns and may terminate
        // the app for misuse when the task is held open for the whole
        // session. For continuous background location, the combination
        // of `UIBackgroundModes: location` (Info.plist) and
        // `CLLocationManager.allowsBackgroundLocationUpdates = true`
        // (set in setupLocationManager) is what iOS provides — and what
        // it expects. See iOS log warning:
        //   "Background Task X created over 30 seconds ago...
        //    this creates a risk of termination."
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12 * 60, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            let battery = self.getBatteryLevel()
            let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            let gpsActive = Date().timeIntervalSince1970 - self.lastLocationTime < 60.0
            let payload: [String: Any] = [
                "type": "system_health",
                "battery_level": battery,
                "is_charging": charging,
                "gps_active": gpsActive,
                "gps_status": gpsActive ? "active" : "idle",
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
            ]
            // Send health timer data on main thread
            DispatchQueue.main.async {
                self.coreDelegate?.onPerformanceEvent(payload)
            }
        }
        RunLoop.main.add(healthTimer!, forMode: .common)

        // Health score emitter (every 5 minutes)
        healthScoreTimer?.invalidate()
        healthScoreTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.emitHealthScore()
        }
        RunLoop.main.add(healthScoreTimer!, forMode: .common)

        fallbackTimer?.invalidate()
        fallbackTimer = nil
        // Request permissions if needed
        let authorizationStatus = locationManager?.authorizationStatus ?? .notDetermined

        if authorizationStatus == .notDetermined {
            pendingStartAfterAuthorization = true
            DispatchQueue.main.async { [weak self] in
                self?.locationManager?.requestWhenInUseAuthorization()
            }
            return
        }

        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            return
        }

        guard CLLocationManager.locationServicesEnabled() else {
            return
        }

        startLocationUpdatesFlow()
    }

    /**
     * Stop location tracking
     */
    public func stopTracking() {
        guard let locationManager = locationManager else { return }

        isRunning = false
        trackingEnabled = false
        healthTimer?.invalidate()
        healthTimer = nil
        healthScoreTimer?.invalidate()
        healthScoreTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        locationManager.stopUpdatingLocation()

        if #available(iOS 9.0, *) {
            locationManager.stopMonitoringSignificantLocationChanges()
        }

        // No background-task counterpart to end — we no longer call
        // beginBackgroundTask in startTracking (see note there).

        // Stop activity recognition
        activityRecognitionManager?.stop()

        // Location tracking stopped
    }

    // MARK: - Health Score

    /// Compute and emit health score via onPerformanceEvent.
    private func emitHealthScore() {
        guard isRunning else { return }

        let debugInfo = PolyfenceDebugCollector.shared.collectDebugInfo()
        let telemetry = telemetryAggregator.getSessionTelemetry()

        let gpsGoodRatio = (telemetry["gps_ok_ratio"] as? NSNumber)?.doubleValue ?? 0.0
        let batteryMetrics = debugInfo["battery"] as? [String: Any]
        let batteryDrain = (batteryMetrics?["estimatedHourlyDrainPercent"] as? NSNumber)?.doubleValue ?? 0.0
        let perfMetrics = debugInfo["performance"] as? [String: Any]
        let avgLatency = (perfMetrics?["averageDetectionLatencyMs"] as? NSNumber)?.doubleValue ?? 0.0
        let errorCount = (debugInfo["recentErrors"] as? [[String: Any]])?.count ?? 0
        let falseRatio = (telemetry["false_event_ratio"] as? NSNumber)?.doubleValue ?? 0.0
        let zoneCount = geofenceEngine.getZoneCount()

        let result = HealthScoreCalculator.calculate(
            gpsGoodRatio: gpsGoodRatio,
            batteryDrainPctPerHr: batteryDrain,
            avgDetectionLatencyMs: avgLatency,
            errorCountRecent: errorCount,
            falseEventRatio: falseRatio,
            isTracking: isRunning,
            activeZoneCount: zoneCount
        )

        let payload: [String: Any] = [
            "type": "health_score",
            "score": result.score,
            "topIssue": result.topIssue ?? "",
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]

        DispatchQueue.main.async { [weak self] in
            self?.coreDelegate?.onPerformanceEvent(payload)
        }
    }

    // (Intentionally no UIApplication.beginBackgroundTask helpers. The
    // `UIBackgroundModes: location` + `allowsBackgroundLocationUpdates`
    // combination is what iOS provides for continuous background
    // location; `beginBackgroundTask` is for finite ≤30s work and iOS
    // terminates apps that hold one open longer than that. Removed in
    // v1.0.8 after the iOS console flagged it as a termination risk.)

    /**
     * Add zone for monitoring
     */
    public func addZone(zoneId: String, zoneName: String, zoneData: [String: Any]) {
        geofenceQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.geofenceEngine.addZone(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData)
                // Save to persistent storage
                self.zonePersistence?.saveZone(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData)

                // Check CLLocationManager health after zone addition
                DispatchQueue.main.async {
                    self.checkLocationManagerHealth()

                    // If GPS was deferred, start it now that we have zones
                    if self.gpsStartDeferred && self.isRunning {
                        NSLog("[LocationTracker] First zone added - starting deferred GPS")
                        self.gpsStartDeferred = false
                        self.startGpsUpdates()
                    } else if self.isRunning, let cachedLocation = self.locationManager?.location {
                        // Tracking is already running. This zone was added AFTER
                        // startGpsUpdates' initial reconcile already ran, so without
                        // a re-reconcile the new zone never gets its cold-start
                        // ENTER even if the user is currently inside it (the engine's
                        // per-tick checkLocation goes through getZonesToCheck which
                        // may exclude this zone via clustering until it acquires
                        // INSIDE state, which would never happen).
                        // Re-reconciling now uses the cached location to evaluate the
                        // newly-added zone against the user's current position.
                        // Safe to call repeatedly because reconcileZoneStates' fresh-
                        // install branch is now idempotent (fires ENTER only on the
                        // false -> true state transition).
                        self.geofenceQueue.async {
                            self.geofenceEngine.reconcileZoneStates(cachedLocation)
                        }
                    }
                }
            } catch {
                // Previously this only NSLog'd — the bridge's addZone() Promise
                // resolved successfully even though the zone was dropped, and
                // no onError event fired (BUG-006). Route the rejection through
                // PolyfenceErrorManager so the bridge surfaces it via the
                // onError channel and consumers can react.
                NSLog("[LocationTracker] Failed to add zone %@: %@", zoneId, "\(error)")
                PolyfenceErrorManager.shared.reportError(
                    type: "zone_validation_failed",
                    message: "Zone \(zoneId) was rejected: \(error.localizedDescription)",
                    context: [
                        "platform": "ios",
                        "zoneId": zoneId,
                        "zoneName": zoneName,
                        "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
                    ]
                )
            }
        }
    }

    /**
     * Remove zone from monitoring
     */
    public func removeZone(zoneId: String) {
        geofenceQueue.async { [weak self] in
            self?.geofenceEngine.removeZone(zoneId: zoneId)
        }
        zonePersistence?.removeZone(zoneId: zoneId)
    }

    /**
     * Clear all zones
     */
    public func clearAllZones() {
        geofenceQueue.async { [weak self] in
            self?.geofenceEngine.clearAllZones()
        }
        zonePersistence?.clearAllZones()
    }

    /**
     * Set callbacks
     */
    public func setLocationCallback(_ callback: @escaping ([String: Any]) -> Void) {
        locationCallback = callback
    }

    public func setGeofenceCallback(_ callback: @escaping ([String: Any]) -> Void) {
        geofenceCallback = callback
    }

    /**
     * Set whether alert notifications should be shown
     */
    public func setAlertNotificationsEnabled(_ enabled: Bool) {
        alertNotificationsEnabled = enabled
        NSLog("[LocationTracker] Alert notifications \(enabled ? "enabled" : "disabled")")
    }

    /**
     * Set which bridge platform is calling core.
     */
    public func setBridgePlatform(_ platform: String) {
        telemetryAggregator.setBridgePlatform(platform: platform)
    }

    /**
     * Request permissions using the same CLLocationManager instance
     */
    public func requestPermissions(always: Bool = false) {
        let status = locationManager?.authorizationStatus ?? .notDetermined
        if status == .notDetermined {
            pendingStartAfterAuthorization = false
            DispatchQueue.main.async { [weak self] in
                if always { self?.locationManager?.requestAlwaysAuthorization() }
                else { self?.locationManager?.requestWhenInUseAuthorization() }
            }
            return
        }
        if always && status == .authorizedWhenInUse {
            DispatchQueue.main.async { [weak self] in
                self?.locationManager?.requestAlwaysAuthorization()
            }
        }
    }

    /**
     * Get last known location as a dictionary for bridge consumption
     */
    public func getLastKnownLocationData() -> [String: Any]? {
        guard let loc = locationManager?.location else { return nil }
        return [
            "latitude": loc.coordinate.latitude,
            "longitude": loc.coordinate.longitude,
            "accuracy": loc.horizontalAccuracy,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
    }

    // MARK: - Private Methods

    private func startLocationUpdatesFlow() {
        guard locationManager != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Restore zones from storage FIRST (before deciding whether to start GPS)
            self.restoreZonesFromStorage()

            // Only start GPS if zones exist, otherwise defer
            if !self.geofenceEngine.hasZones() {
                NSLog("[LocationTracker] No zones registered - deferring GPS start until zones are added")
                self.gpsStartDeferred = true
                return
            }

            self.startGpsUpdates()
        }
    }

    /**
     * Start actual GPS updates (called when zones exist)
     */
    private func startGpsUpdates() {
        guard let locationManager = locationManager else { return }

        locationManager.startUpdatingLocation()
        locationManager.requestLocation()
        if let lastKnown = locationManager.location {
            self.lastLocationTime = Date().timeIntervalSince1970
            self.sendLocationToDelegate(location: lastKnown)

            // Fire initial zone reconciliation against the cached location so
            // ENTER events for zones the user is already inside arrive as soon
            // as tracking starts — without waiting for CLLocationManager to
            // deliver a fresh `didUpdateLocations` callback (which can be
            // delayed indefinitely on a stationary device under
            // `pausesLocationUpdatesAutomatically=true` + distance-filter
            // gating). Subsequent `didUpdateLocations` will see
            // `firstLocationAfterRestart=false` and skip the re-reconcile —
            // they fall through to the normal `checkLocation` path.
            if firstLocationAfterRestart {
                firstLocationAfterRestart = false
                NSLog("[LocationTracker] Reconciling against cached location on startGpsUpdates")
                geofenceQueue.sync { [weak self] in
                    self?.geofenceEngine.reconcileZoneStates(lastKnown)
                }
            }
        }
        if #available(iOS 9.0, *) {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        // Start a fallback timer to keep requesting location until fixes flow
        self.startFallbackTimer()

        // Ensure activity recognition is started if enabled but not running
        if activitySettings.enabled && activityRecognitionManager == nil {
            NSLog("[LocationTracker] Restarting activity recognition on tracking start")
            updateActivityRecognition(activitySettings)
        }

        NSLog("[LocationTracker] GPS updates started with profile: \(smartConfig.accuracyProfile)")
    }

    /**
     * Restore zones from storage on service start
     */
    private func restoreZonesFromStorage() {
        guard let zonePersistence = zonePersistence else { return }

        let savedZones = zonePersistence.loadAllZones()
        geofenceQueue.sync { [weak self] in
            guard let self = self else { return }
            for (_, zoneInfo) in savedZones {
                let (id, name, data) = zoneInfo
                if self.geofenceEngine.getZoneName(id) != nil {
                    continue
                }
                do {
                    try self.geofenceEngine.addZone(zoneId: id, zoneName: name, zoneData: data)
                } catch {
                    // Failed to restore zone
                }
            }

            // Load persisted zone states AFTER zones are loaded
            // This restores the "inside/outside" state from before service restart
            self.geofenceEngine.loadPersistedZoneStates()
        }

        NSLog("[LocationTracker] Restored \(savedZones.count) zones from storage")
    }

    /**
     * Handle geofence events safely on main thread
     */
    private func handleGeofenceEvent(zoneId: String, eventType: String, location: CLLocation, detectionTimeMs: Double) {
        os_log("handleGeofenceEvent type=%{public}@ zone=%{public}@ trackingEnabled=%{public}d hasCoreDelegate=%{public}d",
               log: pfCoreLog, type: .error,
               eventType, zoneId, trackingEnabled ? 1 : 0, coreDelegate != nil ? 1 : 0)

        // CRITICAL: Only process geofence events if tracking is explicitly enabled
        guard trackingEnabled else {
            os_log("handleGeofenceEvent BLOCKED — trackingEnabled=false",
                   log: pfCoreLog, type: .error)
            return
        }

        // Get zone name from GeofenceEngine
        let zoneName = geofenceEngine.getZoneName(zoneId) ?? zoneId

        // Use the detection duration passed from GeofenceEngine (already in milliseconds)
        // This is the actual time it took to detect the geofence event, not GPS age

        // Get GPS accuracy
        let gpsAccuracy = location.horizontalAccuracy

        // ML Telemetry: per-event enrichment
        let speedMps = max(0.0, location.speed) // CLLocation.speed is m/s, -1 if unavailable
        let activityType = activityRecognitionManager?.getCurrentActivity().rawValue.lowercased() ?? "unknown"
        let distanceToBoundary = geofenceEngine.getDistanceToBoundary(zoneId: zoneId, location: location)

        // Record in centralized telemetry aggregator
        telemetryAggregator.recordGeofenceEvent(
            zoneId: zoneId,
            eventType: eventType,
            distanceM: distanceToBoundary,
            speedMps: speedMps,
            accuracyM: gpsAccuracy,
            detectionTimeMs: detectionTimeMs
        )

        // Build enriched event dictionary
        let eventData: [String: Any] = [
            "zoneId": zoneId,
            "zoneName": zoneName,
            "eventType": eventType,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "detectionTimeMs": detectionTimeMs,
            "gpsAccuracy": gpsAccuracy,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": gpsAccuracy,
            "speedMps": speedMps,
            "activityAtEvent": activityType,
            "distanceToBoundaryM": distanceToBoundary
        ]

        // Send event to delegate on main thread
        DispatchQueue.main.async {
            self.geofenceCallback?(eventData)
            self.coreDelegate?.onGeofenceEvent(eventData)
        }

        // Show notification with proper zone name
        showGeofenceNotification(eventType: eventType, zoneId: zoneId, zoneName: zoneName)

        // Emit lightweight system health snapshot on zone change
        let battery = getBatteryLevel()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        let health: [String: Any] = [
            "type": "system_health",
            "gps_status": "active",
            "gps_accuracy": location.horizontalAccuracy,
            "battery_level": battery,
            "is_charging": charging,
            "gps_active": true,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        // Send health data on main thread
        DispatchQueue.main.async {
            self.coreDelegate?.onPerformanceEvent(health)
        }
    }

    /**
     * Send location to delegate safely on main thread
     */
    private func sendLocationToDelegate(location: CLLocation) {
        let activityName = currentActivity.rawValue.lowercased()
        let locationData: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "speed": location.speed >= 0 ? location.speed * 3.6 : 0.0, // Convert m/s to km/h
            "activity": activityName // Include current activity type
        ]

        // CRITICAL: Send on main thread
        DispatchQueue.main.async {
            self.locationCallback?(locationData)
            self.coreDelegate?.onLocationUpdate(locationData)
        }
    }

    /**
     * Show geofence notification with standardized content
     */
    private func showGeofenceNotification(eventType: String, zoneId: String, zoneName: String) {
        guard isRunning else { return }
        guard alertNotificationsEnabled else { return }  // Respect disableAlertNotifications config
        let title = eventType == "ENTER" ? "Entered Zone" : "Exited Zone"
        let message = zoneName // Use zone name instead of ID

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message

        // Standardized notification configuration
        content.sound = .default  // Standard default sound
        content.badge = 1

        // iOS 15+ time-sensitive interruption level (not critical)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        // Metadata for tracking
        content.userInfo = [
            "zoneId": zoneId,
            "zoneName": zoneName,
            "eventType": eventType,
            "timestamp": Date().timeIntervalSince1970
        ]

        // Use appropriate category
        content.categoryIdentifier = eventType == "ENTER" ? "POLYFENCE_ZONE_ENTRY" : "POLYFENCE_ZONE_EXIT"

        // Immediate local delivery (trigger = nil)
        let request = UNNotificationRequest(
            identifier: "geofence-\(zoneId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // Immediate delivery
        )

        notificationCenter?.add(request) { _ in
            DispatchQueue.main.async {
                // Notification delivery completed
            }
        }
    }

    /**
     * Create notification categories
     */
    private func createNotificationCategories() {
        // Tracking notification (low priority)
        let trackingCategory = UNNotificationCategory(
            identifier: "POLYFENCE_TRACKING",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // Zone entry notification
        let entryCategory = UNNotificationCategory(
            identifier: "POLYFENCE_ZONE_ENTRY",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // Zone exit notification
        let exitCategory = UNNotificationCategory(
            identifier: "POLYFENCE_ZONE_EXIT",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter?.setNotificationCategories([trackingCategory, entryCategory, exitCategory])
    }

    /**
     * Get device ID
     */
    private func getPolyfenceDeviceId() -> String {
        let userDefaults = UserDefaults.standard
        var deviceId = userDefaults.string(forKey: "polyfence_device_id")

        if deviceId == nil {
            let timestamp = Date().timeIntervalSince1970
            let random = Int(timestamp.truncatingRemainder(dividingBy: 10000))
            deviceId = "polyfence-\(Int(timestamp))-\(String(format: "%04d", random))"
            userDefaults.set(deviceId, forKey: "polyfence_device_id")
        }

        return deviceId ?? UUID().uuidString
    }

    /**
     * Get battery level
     */
    private func getBatteryLevel() -> Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        return batteryLevel >= 0 ? Double(batteryLevel * 100) : 100.0
    }

    /**
     * Get CPU usage (mock implementation)
     */
    private func getCpuUsage() -> Double {
        // System-wide CPU usage based on host CPU load counters
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoad = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        let user = cpuLoad.cpu_ticks.0
        let nice = cpuLoad.cpu_ticks.1
        let system = cpuLoad.cpu_ticks.2
        let idle = cpuLoad.cpu_ticks.3
        let idleAll = idle
        let total = user &+ nice &+ system &+ idleAll
        let totald = total &- prevCpuTotal
        let idled = idleAll &- prevCpuIdle
        prevCpuTotal = total
        prevCpuIdle = idleAll
        if totald > 0 {
            let usage = Double(totald &- idled) / Double(totald) * 100.0
            return Double(round(10 * usage) / 10)
        }
        return 0.0
    }

    /**
     * Handle GPS restart (error recovery)
     */
    private func handleGpsRestart() {
        guard let locationManager = locationManager else { return }

        // Stop current location updates
        locationManager.stopUpdatingLocation()

        // Use more conservative settings on restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, self.isRunning else { return }

            // Use balanced power accuracy for restart
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 20.0 // 20 meters minimum movement

            locationManager.startUpdatingLocation()

            if #available(iOS 9.0, *) {
                locationManager.startMonitoringSignificantLocationChanges()
            }
        }
    }

    /**
     * Start a fallback timer to request single-shot locations if stale
     * Changed from repeating (15s) to non-repeating (30s) - only fires when truly needed
     */
    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        // Non-repeating timer at 30s - reschedules itself only after location received
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            let now = Date().timeIntervalSince1970
            let secondsSinceLast = now - self.lastLocationTime
            if secondsSinceLast > 30.0 {
                // Only request if truly stale (30s without update)
                if self.smartConfig.enableDebugLogging {
                    NSLog("%@", "\(Self.TAG): Fallback timer triggered - requesting location")
                }
                self.locationManager?.requestLocation()
            }
            // Reschedule for next check
            self.startFallbackTimer()
        }
        RunLoop.main.add(fallbackTimer!, forMode: .common)
    }

    /**
     * Reset fallback timer after receiving a location update
     * Called from locationManager:didUpdateLocations to prevent unnecessary fallback triggers
     */
    private func resetFallbackTimer() {
        if isRunning {
            startFallbackTimer()
        }
    }

    /**
     * Handle permission loss
     */
    private func handlePermissionLoss() {
        stopTracking()
    }

    /**
     * Check if CLLocationManager is still healthy
     */
    private func checkLocationManagerHealth() {
        guard locationManager != nil else {
            return
        }

        // Test if we can still get location updates
        let testLocation = locationManager?.location
        if testLocation == nil {
            // LocationManager no longer providing location
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        os_log("didUpdateLocations n=%{public}d trackingEnabled=%{public}d isRunning=%{public}d firstAfterRestart=%{public}d",
               log: pfCoreLog, type: .error,
               locations.count, trackingEnabled ? 1 : 0, isRunning ? 1 : 0, firstLocationAfterRestart ? 1 : 0)
        // CRITICAL: Only process locations if tracking is explicitly enabled
        guard trackingEnabled, let location = locations.last, isRunning else {
            os_log("didUpdateLocations BLOCKED — trackingEnabled or isRunning false",
                   log: pfCoreLog, type: .error)
            return
        }

        // STATE RECOVERY: On first valid location after service restart,
        // reconcile persisted zone states with actual location.
        // This fires RECOVERY_ENTER/RECOVERY_EXIT for any mismatches.
        if firstLocationAfterRestart {
            firstLocationAfterRestart = false
            NSLog("[LocationTracker] First location after restart - reconciling zone states")
            geofenceQueue.sync { [weak self] in
                self?.geofenceEngine.reconcileZoneStates(location)
            }
        }

        // Update movement state for smart GPS
        updateMovementState(location)

        // Log proximity debug info
        logProximityDebugInfo(location)

        // Update GPS health tracking
        lastLocationTime = Date().timeIntervalSince1970
        consecutiveGpsFailures = 0
        currentGpsAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil

        // Check for unreliable GPS (large accuracy swings, poor accuracy)
        checkGpsReliability(location)

        // Record in centralized telemetry aggregator
        telemetryAggregator.recordGpsUpdate(
            intervalMs: Int64(currentGpsInterval * 1000),
            accuracyM: Float(location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : 999.0)
        )

        // Reset fallback timer since we received a valid location
        resetFallbackTimer()

        // Throttle delegate callbacks when stationary to reduce overhead
        let currentTime = Date().timeIntervalSince1970
        let timeSinceLastCallback = currentTime - lastDelegateCallbackTime
        let shouldSendToDelegate: Bool
        if isStationary {
            // When stationary, only send updates every 30s
            shouldSendToDelegate = timeSinceLastCallback >= stationaryDelegateCallbackInterval
        } else {
            // When moving, send every update
            shouldSendToDelegate = true
        }

        if shouldSendToDelegate {
            sendLocationToDelegate(location: location)
            lastDelegateCallbackTime = currentTime
        }

        // Emit runtime status periodically (parity with Android)
        emitRuntimeStatus()

        // Only check geofences if moved significantly since last check
        let shouldCheckZones: Bool
        if let lastLoc = lastZoneCheckLocation {
            shouldCheckZones = location.distance(from: lastLoc) > minMovementForZoneCheckMeters
        } else {
            shouldCheckZones = true  // Always check on first location
        }

        if shouldCheckZones {
            // Run geofence check on geofence queue to avoid concurrency issues
            geofenceQueue.async { [weak self] in
                guard let self = self else { return }
                self.geofenceEngine.checkLocation(location)
            }
            lastZoneCheckLocation = location
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        consecutiveGpsFailures += 1

        // Track GPS availability drop for health metrics
        let currentTime = Date().timeIntervalSince1970
        gpsAvailabilityDropTimestamps.append(currentTime)
        cleanupOldGpsDrops(currentTime)

        // Emit gpsUnreliable error if we've had multiple drops recently
        let drops5Min = getGpsAvailabilityDrops5Min()
        if drops5Min >= 3 {
            emitGpsUnreliableError(drops: drops5Min, accuracy: nil)
        }

        // Report GPS error to developer stream
        PolyfenceErrorManager.shared.reportGpsError(
            type: "gps_error",
            details: error.localizedDescription
        )

        // Handle GPS failure recovery
        if consecutiveGpsFailures >= 3 && consecutiveGpsFailures <= 5 {
            handleGpsRestart()
        }
    }

    // iOS < 14 callback
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        handleAuthorizationChange(status: status)
    }

    // iOS 14+ callback
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        handleAuthorizationChange(status: status)
    }

    private func handleAuthorizationChange(status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            if isRunning {
                if pendingStartAfterAuthorization {
                    pendingStartAfterAuthorization = false
                    startLocationUpdatesFlow()
                }
            }
        case .denied, .restricted:
            // Emit permission revocation error to delegate error stream before stopping
            if isRunning || trackingEnabled {
                let statusName = status == .denied ? "denied" : "restricted"
                NSLog("[LocationTracker] Location permission changed to \(statusName) while tracking was active")
                PolyfenceErrorManager.shared.reportError(
                    type: "permission_revoked",
                    message: "Location permission was revoked while tracking was active (status: \(statusName))",
                    context: [
                        "platform": "ios",
                        "authorizationStatus": statusName,
                        "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
                    ]
                )
            }
            handlePermissionLoss()
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        // Started monitoring region
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // Entered region
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // Exited region
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LocationTracker: UNUserNotificationCenterDelegate {

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
}

// MARK: - Smart GPS Configuration Methods

extension LocationTracker {

    /**
     * Update smart GPS configuration
     */
    /**
     * Set GPS accuracy threshold for GeofenceEngine
     */
    public func setGpsAccuracyThreshold(_ threshold: Double) {
        geofenceEngine.setGpsAccuracyThreshold(threshold)
    }

    /**
     * Configure dwell detection
     * @param enabled Whether dwell detection is enabled
     * @param thresholdMs How long (milliseconds) device must stay in zone before DWELL fires
     */
    public func setDwellConfig(enabled: Bool, thresholdMs: Int) {
        // Convert milliseconds to seconds for iOS
        let thresholdSeconds = TimeInterval(thresholdMs) / 1000.0
        geofenceEngine.setDwellConfig(enabled: enabled, thresholdSeconds: thresholdSeconds)
    }

    /**
     * Configure zone clustering for large zone sets
     * @param enabled Whether clustering is enabled
     * @param activeRadiusMeters Radius to check zones within
     * @param refreshDistanceMeters Distance to move before refreshing active cluster
     */
    public func setClusterConfig(enabled: Bool, activeRadiusMeters: Double, refreshDistanceMeters: Double) {
        geofenceEngine.setClusterConfig(enabled: enabled, activeRadiusMeters: activeRadiusMeters, refreshDistanceMeters: refreshDistanceMeters)
    }

    /**
     * Configure scheduled tracking
     * @param scheduleSettings Schedule configuration map from bridge
     */
    public func setScheduleConfig(_ scheduleSettings: [String: Any]?) {
        TrackingScheduler.shared.setLocationTracker(self)
        TrackingScheduler.shared.updateConfig(scheduleSettings)
    }

    /// Clear all schedule configuration
    public func clearScheduleConfig() {
        setScheduleConfig(nil)
    }

    /**
     * Configure activity recognition
     * @param activitySettingsMap Activity configuration map from bridge
     */
    public func setActivityConfig(_ activitySettingsMap: [String: Any]?) {
        guard let settingsMap = activitySettingsMap else {
            // Disable activity recognition if no settings provided
            activityRecognitionManager?.stop()
            activitySettings = ActivitySettings()
            currentActivity = .unknown
            return
        }

        let newSettings = ActivitySettings.fromMap(settingsMap)
        updateActivityRecognition(newSettings)
    }

    /**
     * Update activity recognition settings
     */
    private func updateActivityRecognition(_ newSettings: ActivitySettings) {
        activitySettings = newSettings

        if newSettings.enabled {
            // Initialize manager if needed
            if activityRecognitionManager == nil {
                activityRecognitionManager = ActivityRecognitionManager()
            }

            // Start activity recognition with callback
            activityRecognitionManager?.start(settings: newSettings) { [weak self] activity, confidence in
                guard let self = self else { return }
                NSLog("[\(Self.TAG)] Activity changed: \(activity) (confidence: \(confidence)%)")
                self.currentActivity = activity
                // Record activity change in centralized telemetry
                self.telemetryAggregator.recordActivityChange(activityType: activity.rawValue.lowercased())
                // Update GPS settings when activity changes
                if self.trackingEnabled {
                    DispatchQueue.main.async {
                        self.updateLocationManagerSettings()
                    }
                }
            }
        } else {
            // Stop activity recognition
            activityRecognitionManager?.stop()
            currentActivity = .unknown
        }
    }

    public func updateSmartConfiguration(_ config: SmartGpsConfig) {
        self.smartConfig = config

        // Apply configuration if tracking is active
        if trackingEnabled {
            updateLocationManagerSettings()
        }

        config.logConfiguration(tag: Self.TAG)
    }

    /// Apply a partial configuration update without resetting the
    /// fields the caller omitted.
    ///
    /// Deep-merges [partial] into the current [smartConfig]'s map shape
    /// before re-parsing, so a call like
    /// `updateSmartConfigurationFromMap(["clusteringEnabled": true])`
    /// preserves the existing `updateStrategy` / nested settings
    /// instead of silently reverting them to data-class defaults.
    ///
    /// Bridges (RN, Flutter) on iOS should call this rather than
    /// constructing a SmartGpsConfig from the raw map themselves.
    /// Android's path goes through the foreground-service map handler
    /// which already does the merge internally. BUG-015.
    public func updateSmartConfigurationFromMap(_ partial: [String: Any]) {
        // Sparse merge base — omits null nested settings so a partial
        // update doesn't materialise a default-constructed nested
        // block the runtime treats as "feature inactive". Not the
        // same as SmartGpsConfigFactory.toMap (which stays full-shape
        // for getConfiguration display).
        let currentMap = SmartGpsConfigFactory.toMergeBaseMap(self.smartConfig)
        let merged = deepMergeMaps(base: currentMap, overrides: partial)
        let mergedConfig = SmartGpsConfigFactory.fromMap(merged)
        updateSmartConfiguration(mergedConfig)
    }

    /// Reset smart GPS configuration to defaults
    public func resetSmartConfiguration() {
        updateSmartConfiguration(SmartGpsConfig())
    }

    /**
     * Get current smart GPS configuration
     */
    public func getCurrentSmartConfiguration() -> SmartGpsConfig {
        return smartConfig
    }

    /**
     * Get current zone states from GeofenceEngine
     * Returns which zones the plugin believes the device is currently inside
     * @return Dictionary of zoneId to isInside state
     */
    public func getCurrentZoneStates() -> [String: Bool] {
        return geofenceEngine.getCurrentZoneStates()
    }

    /**
     * Update location manager settings based on smart configuration
     */
    private func updateLocationManagerSettings() {
        guard let locationManager = locationManager else { return }

        let accuracy = smartConfig.getCLLocationAccuracy()
        let distanceFilter = smartConfig.getDistanceFilter()

        locationManager.desiredAccuracy = accuracy
        locationManager.distanceFilter = distanceFilter
        locationManager.pausesLocationUpdatesAutomatically = smartConfig.shouldPauseAutomatically()

        // ML Telemetry: track interval changes
        let newIntervalMs = Int(calculateCurrentInterval() * 1000)
        if newIntervalMs != lastTrackedIntervalMs {
            accumulateIntervalTime(newIntervalMs: newIntervalMs)
        }
        currentGpsInterval = calculateCurrentInterval()

        if smartConfig.enableDebugLogging {
            NSLog("%@", "\(Self.TAG): Updated GPS settings - accuracy: \(accuracy), distanceFilter: \(distanceFilter)")
        }

        // Emit status after GPS configuration changes
        emitRuntimeStatus()
    }

    /**
     * Calculate current GPS interval based on smart configuration
     */
    private func calculateCurrentInterval() -> TimeInterval {
        switch smartConfig.updateStrategy {
        case .continuous:
            return smartConfig.getBaseUpdateInterval()
        case .proximityBased:
            return calculateProximityBasedInterval()
        case .movementBased:
            return calculateMovementBasedInterval()
        case .intelligent:
            return calculateIntelligentInterval()
        }
    }

    /**
     * Calculate interval based on proximity to zones
     */
    private func calculateProximityBasedInterval() -> TimeInterval {
        guard let proximitySettings = smartConfig.proximitySettings,
              let lastLocation = lastKnownLocation else {
            return smartConfig.getBaseUpdateInterval()
        }

        // Calculate distance to nearest zone
        let nearestZoneDistance = calculateDistanceToNearestZone(lastLocation)

        switch nearestZoneDistance {
        case 0...proximitySettings.nearZoneThresholdMeters:
            if smartConfig.enableDebugLogging {
                NSLog("%@", "\(Self.TAG): Near zone (\(nearestZoneDistance)m) - using high frequency")
            }
            return proximitySettings.nearZoneUpdateIntervalMs
        case proximitySettings.farZoneThresholdMeters...:
            if smartConfig.enableDebugLogging {
                NSLog("%@", "\(Self.TAG): Far from zones (\(nearestZoneDistance)m) - using low frequency")
            }
            return proximitySettings.farZoneUpdateIntervalMs
        default:
            // Interpolate for medium distances
            let ratio = (nearestZoneDistance - proximitySettings.nearZoneThresholdMeters) /
                       (proximitySettings.farZoneThresholdMeters - proximitySettings.nearZoneThresholdMeters)

            let intervalDiff = proximitySettings.farZoneUpdateIntervalMs - proximitySettings.nearZoneUpdateIntervalMs
            let interpolatedInterval = proximitySettings.nearZoneUpdateIntervalMs + (ratio * intervalDiff)

            if smartConfig.enableDebugLogging {
                NSLog("%@", "\(Self.TAG): Medium distance (\(nearestZoneDistance)m) - using interpolated interval: \(interpolatedInterval)s")
            }
            return interpolatedInterval
        }
    }

    /**
     * Calculate interval based on movement state
     */
    private func calculateMovementBasedInterval() -> TimeInterval {
        guard let movementSettings = smartConfig.movementSettings else {
            return smartConfig.getBaseUpdateInterval()
        }

        return isStationary ? movementSettings.stationaryUpdateIntervalMs : movementSettings.movingUpdateIntervalMs
    }

    /**
     * Calculate interval using intelligent combination of factors.
     *
     * HIERARCHY (fixed):
     * - When near a zone AND moving -> fast proximity interval (detect entry/exit quickly)
     * - When near a zone AND stationary -> respect stationary interval (save battery at home)
     * - When far from all zones -> use most battery-friendly interval
     */
    private func calculateIntelligentInterval() -> TimeInterval {
        let proximitySettings = smartConfig.proximitySettings
        var proximityInterval: TimeInterval? = nil

        // Check if we're near a zone
        if let settings = proximitySettings, let location = lastKnownLocation {
            let nearestZoneDistance = calculateDistanceToNearestZone(location)

            if nearestZoneDistance <= settings.nearZoneThresholdMeters {
                proximityInterval = calculateProximityBasedInterval()
                if smartConfig.enableDebugLogging {
                    NSLog("%@", "\(Self.TAG): Near zone (\(nearestZoneDistance)m) - proximity interval: \(proximityInterval!)s, isStationary=\(isStationary)")
                }
            }
        }

        // Collect other strategy intervals
        let movementInterval = calculateMovementBasedInterval()
        let batteryInterval = calculateBatteryBasedInterval()
        let activityInterval = calculateActivityBasedInterval()

        // Near a zone AND stationary -> respect stationary interval to save battery
        if let proxInterval = proximityInterval, isStationary {
            let stationaryInterval = smartConfig.movementSettings?.stationaryUpdateIntervalMs ?? 120.0 // seconds
            let result = max(proxInterval, stationaryInterval)
            if smartConfig.enableDebugLogging {
                NSLog("%@", "\(Self.TAG): Near zone but stationary - using: \(result)s (proximity=\(proxInterval), stationary=\(stationaryInterval))")
            }
            return result
        }

        // Near a zone AND moving -> proximity wins (fast updates for entry/exit detection)
        if let proxInterval = proximityInterval {
            return proxInterval
        }

        // Far from zones -> use the most battery-friendly (longest) interval
        let result = max(movementInterval, batteryInterval, activityInterval)
        if smartConfig.enableDebugLogging {
            NSLog("%@", "\(Self.TAG): Far from zones - using longest interval: \(result)s (movement=\(movementInterval), battery=\(batteryInterval), activity=\(activityInterval))")
        }
        return result
    }

    /**
     * Calculate interval based on detected activity type
     * Only applies when activity recognition is enabled
     */
    private func calculateActivityBasedInterval() -> TimeInterval {
        guard activitySettings.enabled else {
            return smartConfig.getBaseUpdateInterval()
        }

        return activitySettings.getIntervalForActivity(currentActivity)
    }

    /**
     * Calculate interval based on battery level
     */
    private func calculateBatteryBasedInterval() -> TimeInterval {
        guard let batterySettings = smartConfig.batterySettings else {
            return smartConfig.getBaseUpdateInterval()
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = Int(UIDevice.current.batteryLevel * 100)

        if batteryLevel <= batterySettings.criticalBatteryThreshold && batterySettings.pauseOnCriticalBattery {
            return TimeInterval.greatestFiniteMagnitude // Pause GPS
        } else if batteryLevel <= batterySettings.lowBatteryThreshold {
            return batterySettings.lowBatteryUpdateIntervalMs
        } else {
            return smartConfig.getBaseUpdateInterval()
        }
    }

    /**
     * Calculate distance to nearest zone
     */
    private func calculateDistanceToNearestZone(_ location: CLLocation) -> Double {
        // Get current zones from GeofenceEngine
        let zones = geofenceEngine.getCurrentZones()
        guard !zones.isEmpty else {
            return Double.greatestFiniteMagnitude // No zones configured
        }

        var nearestDistance = Double.greatestFiniteMagnitude

        for zone in zones {
            let distance: Double

            if zone.isCircle {
                distance = calculateDistanceToCircleZone(location: location, zone: zone)
            } else if zone.isPolygon {
                distance = calculateDistanceToPolygonZone(location: location, zone: zone)
            } else {
                distance = Double.greatestFiniteMagnitude
            }

            if distance < nearestDistance {
                nearestDistance = distance
            }
        }

        if smartConfig.enableDebugLogging {
            NSLog("%@", "\(Self.TAG): Nearest zone distance: \(nearestDistance)m")
        }
        return nearestDistance
    }

    /**
     * Calculate distance to circle zone boundary
     */
    private func calculateDistanceToCircleZone(location: CLLocation, zone: Zone) -> Double {
        guard let center = zone.center, let radius = zone.radius else {
            return Double.greatestFiniteMagnitude
        }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let distanceToCenter = location.distance(from: centerLocation)

        // Distance to zone boundary (0 if inside zone)
        return max(0.0, distanceToCenter - radius)
    }

    /**
     * Calculate distance to polygon zone boundary
     */
    private func calculateDistanceToPolygonZone(location: CLLocation, zone: Zone) -> Double {
        let currentPoint = location.coordinate
        let points = zone.points

        guard !points.isEmpty else { return Double.greatestFiniteMagnitude }

        // Check if inside polygon first
        if GeoMath.isPointInPolygon(point: currentPoint, polygon: points) {
            return 0.0 // Inside zone
        }

        // Calculate distance to nearest polygon edge
        var nearestDistance = Double.greatestFiniteMagnitude

        for i in points.indices {
            let p1 = points[i]
            let p2 = points[(i + 1) % points.count]

            let distance = GeoMath.pointToSegmentDistance(p: currentPoint, a: p1, b: p2)
            if distance < nearestDistance {
                nearestDistance = distance
            }
        }

        return nearestDistance
    }



    /**
     * Log proximity debug information for testing
     */
    private func logProximityDebugInfo(_ location: CLLocation) {
        if smartConfig.enableDebugLogging {
            let distance = calculateDistanceToNearestZone(location)
            let interval = calculateProximityBasedInterval()

            NSLog("%@", "\(Self.TAG): Proximity Debug:")
            NSLog("%@", "  - Distance to nearest zone: \(distance)m")
            NSLog("%@", "  - GPS interval: \(interval)s")
            NSLog("%@", "  - Update strategy: \(smartConfig.updateStrategy)")
            NSLog("%@", "  - Zones count: \(geofenceEngine.getZoneCount())")
        }
    }

    /**
     * Update movement state based on location changes.
     *
     * Stationary detection always runs using sensible defaults, even when
     * movementSettings is nil. This ensures isStationary is always accurate,
     * which is critical for INTELLIGENT strategy and P11 callback throttling.
     */
    // MARK: - ML Telemetry Methods

    /**
     * Accumulate time spent at the previous GPS interval before switching.
     */
    private func accumulateIntervalTime(newIntervalMs: Int) {
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastIntervalChangeTime
        if elapsed > 0 {
            let key = String(lastTrackedIntervalMs)
            intervalTime[key] = (intervalTime[key] ?? 0) + elapsed
        }
        lastIntervalChangeTime = now
        lastTrackedIntervalMs = newIntervalMs
        totalIntervalMs += newIntervalMs
        intervalSampleCount += 1
    }

    /**
     * Track stationary state transitions for telemetry.
     */
    private func updateStationaryTracking(nowStationary: Bool) {
        if nowStationary && stationaryStartTime == nil {
            stationaryStartTime = Date().timeIntervalSince1970
        } else if !nowStationary, let start = stationaryStartTime {
            cumulativeStationaryTime += Date().timeIntervalSince1970 - start
            stationaryStartTime = nil
        }
    }

    /**
     * Returns GPS interval distribution as proportions (0.0-1.0).
     */
    func getGpsIntervalDistribution() -> [String: Double] {
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastIntervalChangeTime
        var snapshot = intervalTime
        let key = String(lastTrackedIntervalMs)
        snapshot[key] = (snapshot[key] ?? 0) + elapsed

        let total = snapshot.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return snapshot.mapValues { $0 / total }
    }

    /**
     * Returns ratio of time spent stationary (0.0-1.0).
     */
    func getStationaryRatio() -> Double {
        let sessionDuration = Date().timeIntervalSince1970 - trackingStartTime
        guard sessionDuration > 0 else { return 0 }
        var total = cumulativeStationaryTime
        if let start = stationaryStartTime {
            total += Date().timeIntervalSince1970 - start
        }
        return total / sessionDuration
    }

    /**
     * Returns average GPS interval in milliseconds.
     */
    func getAvgGpsIntervalMs() -> Int {
        guard intervalSampleCount > 0 else { return 0 }
        return totalIntervalMs / intervalSampleCount
    }

    /**
     * Collect session telemetry from all native components.
     */
    public func getSessionTelemetryData() -> [String: Any] {
        // Set device/config info before collecting
        telemetryAggregator.setDeviceInfo(
            category: TelemetryAggregator.getDeviceCategory(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        telemetryAggregator.setConfig(
            accuracyProfile: smartConfig.accuracyProfile.rawValue.lowercased(),
            updateStrategy: smartConfig.updateStrategy.rawValue.lowercased()
        )

        // Battery start was captured in init() (and re-captured in
        // resetTelemetry() for sessions 2..N). Pair with a fresh end read
        // here and the OR of start/end charging state so the SaaS can
        // compute battery_drain_avg_pct_per_hr and tag whether the
        // measurement was muddied by charging at either end.
        // Caveat: UIDevice.batteryLevel returns -1 in the iOS Simulator;
        // getBatteryLevel() coerces that to 100.0, so simulator sessions
        // will show 0 drain. Test on a real, unplugged device.
        let endLevel = getBatteryLevel()
        let endCharging = UIDevice.current.batteryState == .charging
            || UIDevice.current.batteryState == .full
        batteryLock.lock()
        let startSnapshot = batterySnapshotAtStart
        let startCharging = chargingAtStart
        batteryLock.unlock()
        telemetryAggregator.setBatteryInfo(
            startPercent: startSnapshot,
            endPercent: endLevel,
            chargingDuring: startCharging || endCharging
        )

        // Return complete v2 enhanced payload from centralized aggregator
        return telemetryAggregator.getSessionTelemetry(geofenceEngine: geofenceEngine)
    }

    /**
     * Reset telemetry counters for a new session.
     */
    func resetTelemetry() {
        intervalTime.removeAll()
        lastIntervalChangeTime = Date().timeIntervalSince1970
        lastTrackedIntervalMs = Int(currentGpsInterval * 1000)
        totalIntervalMs = 0
        intervalSampleCount = 0
        cumulativeStationaryTime = 0
        stationaryStartTime = nil
        trackingStartTime = Date().timeIntervalSince1970
        telemetryAggregator.resetTelemetry()
        // Re-anchor the battery snapshot to the new session-start clock —
        // telemetryAggregator.resetTelemetry() just restarted sessionStartTime
        // and nulled batteryLevelStart on the aggregator. Without refreshing
        // here, the next getSessionTelemetryData() call would pair a stale
        // start (from init) with a fresh end over the new (typically shorter)
        // session duration → meaningless drain.
        captureBatterySessionStart()
    }

    private func updateMovementState(_ location: CLLocation) {
        lastKnownLocation = location
        let currentTime = Date().timeIntervalSince1970
        let movementSettings = smartConfig.movementSettings

        // Always compute stationary state -- use defaults when movementSettings is nil
        let moveThreshold = movementSettings?.movementThresholdMeters ?? 50.0
        let timeThreshold = movementSettings?.stationaryThresholdMs ?? 300.0 // seconds

        // Distance from last significant movement position (not from lastKnownLocation,
        // which was just overwritten above -- comparing to itself would always yield 0)
        let distance: Double = lastMovementLocation.map { location.distance(from: $0) } ?? Double.greatestFiniteMagnitude

        if distance > moveThreshold {
            // Significant movement detected -- update movement anchor
            lastMovementLocation = location
            lastMovementTime = currentTime
            if isStationary {
                isStationary = false
                updateStationaryTracking(nowStationary: false)
                if smartConfig.enableDebugLogging {
                    NSLog("%@", "\(Self.TAG): Device started moving (moved \(String(format: "%.1f", distance))m)")
                }
                updateLocationManagerSettings()
            }
        } else if lastMovementTime > 0 && currentTime - lastMovementTime >= timeThreshold {
            // No significant movement for threshold duration
            if !isStationary {
                isStationary = true
                updateStationaryTracking(nowStationary: true)
                if smartConfig.enableDebugLogging {
                    NSLog("%@", "\(Self.TAG): Device is now stationary (no movement > \(moveThreshold)m in \(timeThreshold)s)")
                }
                updateLocationManagerSettings()
            }
        }

        // Initialize movement tracking on first location
        if lastMovementLocation == nil {
            lastMovementLocation = location
            lastMovementTime = currentTime
        }

        lastLocationTime = currentTime
    }

    // MARK: - Battery Level Detection

    /**
     * Get current battery level percentage (as Int)
     */
    private func getBatteryLevelInt() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return Int(UIDevice.current.batteryLevel * 100)
    }

    /**
     * Get current battery mode based on level and settings
     */
    private func getCurrentBatteryMode() -> String {
        let batteryLevel = getBatteryLevelInt()
        guard let batterySettings = smartConfig.batterySettings else { return "normal" }

        switch batteryLevel {
        case ...batterySettings.criticalBatteryThreshold:
            return "critical"
        case ...batterySettings.lowBatteryThreshold:
            return "low"
        default:
            return "normal"
        }
    }

    // MARK: - GPS Health Monitoring

    /**
     * Check GPS reliability based on accuracy and consistency
     */
    private func checkGpsReliability(_ location: CLLocation) {
        let accuracy = location.horizontalAccuracy
        guard accuracy >= 0 else { return }

        // Detect unreliable GPS: accuracy > 150m is considered unreliable
        // iOS CoreLocation can feed locations with poor accuracy during signal loss
        if accuracy > 150.0 {
            emitGpsUnreliableError(drops: getGpsAvailabilityDrops5Min(), accuracy: accuracy)
        }
    }

    /**
     * Remove GPS availability drop timestamps older than 5 minutes
     */
    private func cleanupOldGpsDrops(_ currentTime: TimeInterval) {
        let fiveMinutesAgo = currentTime - 300.0
        gpsAvailabilityDropTimestamps.removeAll { $0 < fiveMinutesAgo }
    }

    /**
     * Get number of GPS availability drops in the last 5 minutes
     */
    private func getGpsAvailabilityDrops5Min() -> Int {
        let currentTime = Date().timeIntervalSince1970
        cleanupOldGpsDrops(currentTime)
        return gpsAvailabilityDropTimestamps.count
    }

    /**
     * Emit gpsUnreliable error (with cooldown to prevent spam)
     */
    private func emitGpsUnreliableError(drops: Int, accuracy: Double?) {
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastGpsUnreliableErrorTime < gpsUnreliableErrorCooldownSeconds {
            return // Cooldown active - don't spam errors
        }

        lastGpsUnreliableErrorTime = currentTime

        let message: String
        var context: [String: Any] = [
            "platform": "ios",
            "drops5Min": drops,
            "timestamp": Int64(currentTime * 1000)
        ]

        if let acc = accuracy {
            message = "GPS signal unreliable - poor accuracy (\(Int(acc))m)"
            context["accuracy"] = acc
        } else {
            message = "GPS signal unreliable - \(drops) availability drops in last 5 minutes"
        }

        NSLog("[LocationTracker] GPS unreliable: drops=\(drops), accuracy=\(accuracy?.description ?? "nil")")

        PolyfenceErrorManager.shared.reportError(
            type: "gps_unreliable",
            message: message,
            context: context
        )
    }

    // MARK: - Runtime Status Emission

    /**
     * Emit runtime status to delegate via performance stream
     * Parity with Android LocationTracker.emitRuntimeStatus()
     */
    private func emitRuntimeStatus() {
        guard let location = lastKnownLocation else { return }

        let currentTime = Date().timeIntervalSince1970

        // Calculate seconds since last GPS fix
        let secondsSinceLastFix: Int
        if lastLocationTime > 0 {
            secondsSinceLastFix = Int(currentTime - lastLocationTime)
        } else {
            secondsSinceLastFix = 0
        }

        var status: [String: Any] = [
            "strategy": smartConfig.updateStrategy.rawValue,
            "intervalMs": Int(currentGpsInterval * 1000),
            "accuracyProfile": smartConfig.accuracyProfile.rawValue,
            "nearestZoneDistanceM": calculateDistanceToNearestZone(location),
            "isStationary": isStationary,
            "batteryMode": getCurrentBatteryMode(),
            "gpsAccuracy": location.horizontalAccuracy,
            "timestamp": Int64(currentTime * 1000),
            // New GPS health fields
            "secondsSinceLastGpsFix": secondsSinceLastFix,
            "gpsAvailabilityDrops5Min": getGpsAvailabilityDrops5Min()
        ]

        // Add currentGpsAccuracy if available
        if let accuracy = currentGpsAccuracy, accuracy >= 0 {
            status["currentGpsAccuracy"] = accuracy
        }

        // Only emit if status changed or 30 seconds elapsed
        let timeSinceLastEmit = currentTime - lastStatusEmitTime

        // Compare status dictionaries (simplified comparison - check key values)
        let statusChanged = !NSDictionary(dictionary: status).isEqual(to: lastEmittedStatus)

        if statusChanged || timeSinceLastEmit >= 30.0 {
            // Send via existing performance event channel
            let event: [String: Any] = [
                "type": "runtime_status",
                "data": status
            ]
            coreDelegate?.onPerformanceEvent(event)
            lastEmittedStatus = status
            lastStatusEmitTime = currentTime
            NSLog("[LocationTracker] Runtime status emitted: \(status)")
        }
    }

}

/// Deep-merge two configuration maps. Keys present in `overrides` win.
/// When both sides have a `[String: Any]` value for the same key, that
/// nested map is merged recursively (one level is enough for the
/// SmartGpsConfig shape — proximitySettings / movementSettings /
/// batterySettings are the only nested objects and they're flat
/// scalars inside).
///
/// Used by `LocationTracker.updateSmartConfigurationFromMap` to
/// preserve unspecified fields across partial updateConfiguration
/// calls from iOS bridges. BUG-015.
private func deepMergeMaps(
    base: [String: Any],
    overrides: [String: Any]
) -> [String: Any] {
    var result = base
    for (key, value) in overrides {
        if let existingDict = result[key] as? [String: Any],
           let overrideDict = value as? [String: Any] {
            result[key] = deepMergeMaps(base: existingDict, overrides: overrideDict)
        } else {
            result[key] = value
        }
    }
    return result
}

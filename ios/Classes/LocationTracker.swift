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
    // Degraded-GPS staleness watchdog. gpsStalenessTimeoutMs 0 = disabled;
    // lastValidFixTime is stamped only on valid fixes (not coarse ones the
    // engine rejects), so the watchdog still fires while degraded fixes arrive.
    private var stalenessTimer: Timer?
    private var gpsStalenessTimeoutMs: Double = 0
    private var lastValidFixTime: TimeInterval = 0
    private let geofenceQueue = DispatchQueue(label: "polyfence.geofence", qos: .userInitiated)

    // Track last location where zone check was performed
    private var lastZoneCheckLocation: CLLocation?
    private let minMovementForZoneCheckMeters: CLLocationDistance = 5.0  // Only recheck zones if moved >5m

    // Defer GPS start until zones exist
    private var gpsStartDeferred: Bool = false

    // Throttle delegate callbacks when stationary
    private var lastDelegateCallbackTime: TimeInterval = 0
    private let stationaryDelegateCallbackInterval: TimeInterval = 30.0  // 30s when stationary

    // Notification properties
    private var notificationCenter: UNUserNotificationCenter?
    private var healthTimer: Timer?
    private var healthScoreTimer: Timer?

    // Callbacks
    private var locationCallback: (([String: Any]) -> Void)?
    private var geofenceCallback: (([String: Any]) -> Void)?

    // Core delegate for platform bridge communication
    public weak var coreDelegate: PolyfenceCoreDelegate? {
        didSet {
            // A direct-Swift consumer has no listener lifecycle to hook, so
            // registering a delegate is its "I am receiving" moment. A bridge
            // declares ownership of the signal before it constructs a tracker,
            // and is excluded here.
            guard coreDelegate != nil, oldValue == nil else { return }
            guard LocationTracker.stagedEventListenerActive() == nil else { return }
            setEventListenerActive(true)
        }
    }

    // Durable-events plumbing. pendingEventsQueueSize == 0 disables persistence
    // entirely (the default). bridgeAttached is the signal a platform bridge
    // toggles to false when its internal delivery sink is not receiving —
    // polyfence-core cannot see past the delegate boundary, so this hint tells
    // the persist-hook that a live delivery attempt would drop.
    private var pendingEventsQueueSize: Int = 0
    private var pendingEventsStore: PendingEventsStore?
    private var bridgeAttached: Bool = true
    private let bridgeAttachedLock = NSLock()

    // Auto-delivery plumbing. `eventListenerActive` is the "somebody is
    // receiving" edge that replays the queue; `bridgeAttached` above is only
    // "the bridge's sink is wired", which is true from `initialize()` onward
    // and therefore says nothing about a subscriber existing.
    private var eventListenerActive: Bool = false
    private let eventListenerLock = NSLock()
    private var pendingEventsAutoDrainEnabled: Bool = true

    // A replay applies zone membership to the engine, so it runs once
    // restoreZonesFromStorage has registered the zones and reloaded their
    // stored states — the batch then settles against a whole engine rather
    // than seeding a map that restore is about to overwrite. It must also stay
    // ahead of the first reconcile, which runs off the first fix after that
    // same restore.
    private var zoneStatesRestored: Bool = false
    private var autoDrainDeferredUntilZonesRestored: Bool = false

    // Staged listener-live signal. Non-nil also means an external caller owns
    // this signal, which suppresses the delegate-registration shortcut above.
    // Type-level rather than per-instance because bridges declare ownership
    // before any tracker exists, and RN replaces the tracker across bridge
    // reloads.
    private static var pendingEventListenerActive: Bool?
    private static let pendingEventListenerLock = NSLock()

    private static func stagedEventListenerActive() -> Bool? {
        pendingEventListenerLock.lock()
        defer { pendingEventListenerLock.unlock() }
        return pendingEventListenerActive
    }

    /// Tell the tracker whether a consumer's event listener is live.
    ///
    /// Distinct from `setBridgeAttached`, which reports whether the bridge's own
    /// platform-channel sink is wired. A sink can be wired long before anything
    /// downstream of it is subscribed — both bridges attach their sink during
    /// `initialize()` — so only this signal means "an event handed over now
    /// reaches somebody".
    ///
    /// On the false→true edge, and when `pendingEventsQueueSize > 0` and the
    /// auto-drain flag is on, the durable queue is drained and replayed through
    /// the normal event callback. Repeated `true` calls are a no-op: a second
    /// subscriber must not replay the batch the first one received.
    ///
    /// Calling this at all declares that the caller owns the signal, which
    /// suppresses the delegate-registration shortcut. Bridges therefore call
    /// `setEventListenerActive(false)` from their module-construction hook,
    /// which the platform guarantees runs before any tracker is built.
    ///
    /// Applies to the live tracker when one exists, and is staged for the next
    /// one otherwise.
    public static func setEventListenerActive(_ active: Bool) {
        pendingEventListenerLock.lock()
        pendingEventListenerActive = active
        pendingEventListenerLock.unlock()
        currentInstanceForOsGeofence?.setEventListenerActive(active)
    }

    /// Test-only seam that returns the staged signal to "nobody has declared
    /// ownership", the state a direct-Swift consumer runs in. The staging is
    /// process-wide, so a test that did not reset it would inherit whichever
    /// value an earlier one left. Do not call from production code.
    internal static func _testResetEventListenerSignal() {
        pendingEventListenerLock.lock()
        pendingEventListenerActive = nil
        pendingEventListenerLock.unlock()
    }

    // OS wake-fence plumbing. Off by default. When on, the registrar mirrors the
    // top-N-nearest zones to CLLocationManager region monitoring so a killed
    // process can be woken by an OS-side callback that enqueues the crossing
    // into the pending queue for drain on the next tracker boot.
    private var osGeofenceWakeEnabled: Bool = false
    private var osGeofenceMaxRegions: Int = PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
    private var osGeofenceRegistrar: OsGeofenceRegistrar?

    /// Marks a queued event as having originated from an OS wake fence rather
    /// than the in-process polling engine. Consumers that want to distinguish
    /// "the OS woke us for this" from "we detected it while running" branch on
    /// this; the drain path treats both identically.
    public static let EVENT_SOURCE_OS_GEOFENCE = "os_geofence"

    /// Registrar / delegate seam. Reads what's currently on this instance.
    internal var pendingEventsStoreForOsGeofence: PendingEventsStore? {
        return pendingEventsStore
    }
    internal var geofenceEngineForOsGeofence: GeofenceEngine {
        return geofenceEngine
    }
    internal var lastKnownLocationForOsGeofence: CLLocation? {
        return lastKnownLocation
    }
    /// Process-wide handle the OS-geofence adapters read to reach live tracker
    /// state. Swift has no companion-object equivalent, so the instance
    /// maintains it: set on init, cleared on deinit but only when it still
    /// points at the instance being torn down — a bridge that constructs a
    /// replacement tracker before releasing the old one must not have the new
    /// instance's handle nulled by the old one's deinit.
    internal static private(set) weak var currentInstanceForOsGeofence: LocationTracker?

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
        LocationTracker.currentInstanceForOsGeofence = self
        // The OS wake-fence flag has to outlive the process: when the OS
        // relaunches a killed app on a region crossing, the wake path runs
        // before any bridge has re-applied configuration, so an in-memory-only
        // flag would read false and the crossing would be discarded — exactly
        // the loss the feature exists to prevent.
        config = PolyfenceConfig()
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

    deinit {
        if LocationTracker.currentInstanceForOsGeofence === self {
            LocationTracker.currentInstanceForOsGeofence = nil
        }
        osGeofenceRegistrar?.shutdown()
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
            // `allowsBackgroundLocationUpdates = true` requires the host
            // app to declare the `location` background mode in its
            // Info.plist and hold a valid CLClient background-mode
            // entitlement. SPM test targets are Info.plist-less, so a
            // unit test that instantiates LocationTracker crashes here
            // with NSInternalInconsistencyException (`!stayUp ||
            // CLClientIsBackgroundable`). Skip the flag when running
            // under XCTest so the class becomes unit-testable without
            // leaking test concerns further into production. The runtime
            // behaviour for shipping apps is unchanged.
            let inXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if !inXCTest {
                locationManager?.allowsBackgroundLocationUpdates = true
            }
        }
    }

    private func setupNotificationCenter() {
        // `UNUserNotificationCenter.current()` requires a valid
        // `Bundle.main.bundleIdentifier`, and `requestAuthorization` opens
        // a system permission dialog. SPM test targets are Info.plist-less
        // and headless, so both crash / hang under XCTest. Skip the whole
        // block when running under XCTest so the class becomes
        // unit-testable; runtime behaviour for shipping apps is unchanged.
        let inXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if inXCTest { return }

        notificationCenter = UNUserNotificationCenter.current()
        notificationCenter?.delegate = self
        notificationCenter?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        createNotificationCategories()
    }

    private func setupGeofenceEngine() {
        // The collector reads zone counts straight off the running engine. It
        // holds the reference weakly, so it empties itself when this tracker
        // goes away and never reports zones for a torn-down session.
        PolyfenceDebugCollector.shared.geofenceEngine = geofenceEngine

        // Setup geofence engine callback
        geofenceEngine.setEventCallback { [weak self] zoneId, eventType, location, detectionTimeMs in
            self?.handleGeofenceEvent(zoneId: zoneId, eventType: eventType, location: location, detectionTimeMs: detectionTimeMs)
        }

        // Wire up zone persistence for state recovery across service restarts
        if let persistence = zonePersistence {
            geofenceEngine.setZonePersistence(persistence)
        }

        // Confirmation settings come from config so both platforms apply the same
        // rule to the same journey — hardcoding single-point detection here made
        // iOS fire on one fix where Android required two, and a consumer's
        // requireConfirmation had no effect at all.
        geofenceEngine.setValidationConfig(
            requireConfirmation: config?.requireConfirmation ?? PolyfenceConfig.DEFAULT_REQUIRE_CONFIRMATION,
            confirmationPoints: config?.confidencePoints ?? PolyfenceConfig.DEFAULT_CONFIDENCE_POINTS
        )

        // Set GPS accuracy threshold from config (default: 100m for platform parity)
        let accuracyThreshold = config?.gpsAccuracyThreshold ?? PolyfenceConfig.DEFAULT_GPS_ACCURACY_THRESHOLD
        geofenceEngine.setGpsAccuracyThreshold(accuracyThreshold)

        // Degraded-GPS handling (Option D + signal-lost). One knob: > 0 ms
        // enables degraded-exit and arms the staleness watchdog.
        gpsStalenessTimeoutMs = config?.gpsStalenessTimeoutMs ?? 0
        geofenceEngine.setDegradedExitEnabled(gpsStalenessTimeoutMs > 0)

        // Durable pending-events queue. Off (append is a no-op) when
        // pendingEventsQueueSize == 0. The store still initialises so drainAll
        // works — recovers events queued under a previous larger cap.
        pendingEventsQueueSize = config?.pendingEventsQueueSize ?? 0
        pendingEventsAutoDrainEnabled = config?.pendingEventsAutoDrainEnabled ?? true
        pendingEventsStore = PendingEventsStore(queueSize: pendingEventsQueueSize)

        // Applied after the store exists so a listener that went live before
        // this tracker was constructed replays against a real queue. The drain
        // itself still waits for restoreZonesFromStorage.
        if let staged = LocationTracker.stagedEventListenerActive() {
            setEventListenerActive(staged)
        }

        // OS wake-fence registrar. Off unless the consumer opts in. Nothing is
        // registered until the app backgrounds, so instantiating here with an
        // empty engine is safe.
        //
        // No reboot handling is needed on this platform: iOS restores
        // CLCircularRegion monitoring across a device restart and relaunches
        // the app in the background on a crossing. Android has no equivalent —
        // Play Services drops every geofence on reboot — which is why only that
        // side carries a boot receiver.
        osGeofenceWakeEnabled = config?.osGeofenceWakeEnabled ?? false
        osGeofenceMaxRegions = config?.osGeofenceMaxRegions
            ?? PolyfenceConfig.DEFAULT_OS_GEOFENCE_MAX_REGIONS
        if let manager = locationManager {
            if osGeofenceWakeEnabled {
                osGeofenceRegistrar = OsGeofenceRegistrar(
                    locationManager: manager,
                    topN: osGeofenceMaxRegions
                )
                osGeofenceRegistrar?.startObservingAppLifecycle()
            } else {
                // Monitored regions outlive the process on iOS. Without this
                // sweep, a consumer who once enabled the flag would keep being
                // woken by that session's fences after turning it off.
                // CLLocationManager mutation is main-thread-only and this runs
                // on whichever thread constructed the tracker.
                OsGeofenceRegistrar.clearStaleRegionsOnMain(locationManager: manager)
            }
        }
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

        // Staleness watchdog — mirrors the Android health-check watchdog, on the
        // same 60s tick for cross-platform parity. Fires SIGNAL_LOST after
        // gpsStalenessTimeoutMs with no VALID fix while inside a zone. Repeating
        // (not reset by locations) so it triggers even when the OS delivers no
        // updates at all. Inert unless gpsStalenessTimeoutMs > 0.
        stalenessTimer?.invalidate()
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            guard self.gpsStalenessTimeoutMs > 0, self.lastValidFixTime > 0 else { return }
            let sinceValidMs = (Date().timeIntervalSince1970 - self.lastValidFixTime) * 1000.0
            if sinceValidMs > self.gpsStalenessTimeoutMs {
                self.geofenceEngine.forceSignalLost(self.lastKnownLocation)
            }
        }
        RunLoop.main.add(stalenessTimer!, forMode: .common)

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
        stalenessTimer?.invalidate()
        stalenessTimer = nil
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
        let perfMetrics = debugInfo[PolyfenceDebugCollector.Key.performance] as? [String: Any]
        // Nil when the collector had nothing to average, which the score
        // treats as an unmeasured dimension rather than a perfect one.
        let avgLatency = (perfMetrics?[PolyfenceDebugCollector.Key.averageDetectionLatency] as? NSNumber)?.doubleValue
        let errorCount = (debugInfo[PolyfenceDebugCollector.Key.recentErrors] as? [[String: Any]])?.count ?? 0
        // detections_total is the ratio's own denominator. The nearby
        // boundary_events_count is not: it counts only detections within the
        // boundary threshold, so gating on it would discard a ratio measured
        // over detections further out.
        let detections = (telemetry["detections_total"] as? NSNumber)?.intValue ?? 0
        let falseRatio: Double? = detections > 0
            ? (telemetry["false_event_ratio"] as? NSNumber)?.doubleValue
            : nil
        let zoneCount = geofenceEngine.getZoneCount()

        let result = HealthScoreCalculator.calculate(
            gpsGoodRatio: gpsGoodRatio,
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
     * Add zone for monitoring.
     *
     * The engine's `addZone` and `zonePersistence.saveZone` are both
     * synchronous internally (the engine uses its own `syncQueue.sync`
     * for the `zoneStates` write), so the whole state mutation runs on
     * the caller's thread and is observable by an
     * immediately-following `getCurrentZoneStates()`. The outer
     * `geofenceQueue.async` wrapper used to hop this off to a background
     * queue — that returned before the mutation ran and created a race
     * where the bridge's next `getZoneStates()` still saw the zone
     * absent (Bug-021). Removed.
     *
     * The `DispatchQueue.main.async` block is preserved — it does the
     * CLLocationManager health check + deferred-GPS-start logic and
     * MUST run on main because CLLocationManager delegate callbacks
     * are main-thread only.
     */
    public func addZone(zoneId: String, zoneName: String, zoneData: [String: Any]) {
        do {
            try geofenceEngine.addZone(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData)
            zonePersistence?.saveZone(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.checkLocationManagerHealth()

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
                self.osGeofenceRegistrar?.requestRefresh()
            }
        } catch {
            // Route the rejection through PolyfenceErrorManager so the
            // bridge surfaces the failure via the onError channel — a
            // plain NSLog would leave the bridge's addZone() Promise
            // resolving as success even though the zone was dropped,
            // and consumers would have no signal to react.
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

    /**
     * Remove zone from monitoring.
     *
     * The engine's `removeZone` uses `syncQueue.sync` internally for the
     * `zoneStates` write, so the removal is synchronous end-to-end and
     * observable by an immediately-following `getCurrentZoneStates()`.
     * The outer `geofenceQueue.async` wrapper used to defer the engine
     * call to a background queue and returned before it ran (Bug-021).
     * Removed.
     */
    public func removeZone(zoneId: String) {
        geofenceEngine.removeZone(zoneId: zoneId)
        zonePersistence?.removeZone(zoneId: zoneId)
        osGeofenceRegistrar?.requestRefresh()
    }

    /**
     * Clear all zones.
     *
     * Same rationale as `removeZone` — the engine's `clearAllZones`
     * uses `syncQueue.sync`, so the wipe is synchronous and observable
     * by an immediately-following `getCurrentZoneStates()`. Outer
     * `geofenceQueue.async` wrapper removed (Bug-021).
     */
    public func clearAllZones() {
        geofenceEngine.clearAllZones()
        zonePersistence?.clearAllZones()
        osGeofenceRegistrar?.requestRefresh()
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
            // A seed is a real fix: it reaches the consumer and drives a
            // reconcile that can raise crossings. Not counting it leaves the
            // counters short on exactly the stationary cold start where it may
            // be the only fix for some time — and leaves the health score
            // reading no GPS samples at all, which it treats as a GPS that is
            // failing to deliver. Android records the same seed.
            telemetryAggregator.recordGpsUpdate(
                intervalMs: Int64(currentGpsInterval * 1000),
                accuracyM: Float(lastKnown.horizontalAccuracy >= 0 ? lastKnown.horizontalAccuracy : 999.0)
            )
            PolyfenceDebugCollector.shared.recordLocationUpdate(
                accuracy: lastKnown.horizontalAccuracy
            )
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
        defer { markZoneStatesRestored() }
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

    /// Zone membership is whole and the first reconcile has not run yet — the
    /// window where a replay's state application survives restore and is still
    /// what reconcile evaluates against.
    private func markZoneStatesRestored() {
        zoneStatesRestored = true
        if autoDrainDeferredUntilZonesRestored && isEventListenerActive() {
            replayQueuedEventsToListener()
        }
    }

    /// Test-only seam for the restore step that gates a queue replay. Reaching
    /// it through `startTracking()` would need a real CLLocationManager fix.
    /// Underscore-prefixed and internal-scoped to keep it out of the public API
    /// while allowing `@testable import PolyfenceCore` to reach it. Do not call
    /// from production code.
    internal func _testRestoreZonesFromStorage() {
        restoreZonesFromStorage()
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

        // Boundary crossings only: dwell and the signal-lost/restored pair
        // are state changes, not crossings, and counting them would inflate a
        // figure consumers read as "how many times did the user cross a zone".
        //
        // A detection time of zero marks a crossing the engine synthesised
        // outside a location evaluation — a degraded-GPS exit. The consumer
        // receives it like any other, so it counts; it was never timed, so it
        // is passed as absent rather than as zero, which would drag the mean
        // toward a speed nothing achieved.
        if eventType == "ENTER" || eventType == "EXIT"
            || eventType == GeofenceEngine.EVENT_RECOVERY_ENTER
            || eventType == GeofenceEngine.EVENT_RECOVERY_EXIT {
            PolyfenceDebugCollector.shared.recordZoneDetection(
                latencyMs: detectionTimeMs > 0 ? detectionTimeMs : nil
            )
        }

        // Build enriched event dictionary.
        //
        // `dwellDurationMs` is populated only for DWELL events. For
        // ENTER/EXIT/RECOVERY_* events the key is absent from the
        // dictionary — bridges surface it as undefined/null which matches
        // the "only meaningful for dwell" semantic. Read against the same
        // zoneEntryTimes map that the dwell-check writes into, so the
        // value is exactly the time-in-zone the DWELL threshold just
        // crossed.
        var eventData: [String: Any] = [
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
        if eventType == GeofenceEngine.EVENT_DWELL,
           let dwellMs = geofenceEngine.getDwellDurationMs(zoneId) {
            eventData["dwellDurationMs"] = dwellMs
        }
        let finalEventData = eventData

        // The direct-Swift geofenceCallback is an in-process closure with no
        // bridge boundary and no drop scenario — fire it unconditionally
        // whenever an event exists. It is orthogonal to the delegate/persist
        // XOR below, which specifically guards against the bridge sink being
        // dead. A callback-only consumer (setGeofenceCallback with no
        // coreDelegate) MUST still receive events.
        DispatchQueue.main.async {
            self.geofenceCallback?(finalEventData)
        }

        // XOR delivery for the delegate path: live-deliver when a delegate is
        // registered, the bridge's sink is wired AND a consumer is actually
        // listening; otherwise persist to the durable queue for a subsequent
        // drain. Never both — persist AFTER a live delivery would double-report
        // the crossing on the next drain.
        //
        // The listener signal is load-bearing, not advisory. A bridge whose
        // sink is wired but whose consumer has unsubscribed emits into nothing:
        // a nil FlutterEventSink swallows the call, RCTDeviceEventEmitter fans
        // out to whoever registered. Delivering there destroys the event and
        // records it delivered, so it never reaches the queue either.
        //
        // This gate is the whole safety net on iOS. Delivery is dispatched to
        // the main queue because platform sinks require it, so the delegate
        // returns before delivery is attempted and its outcome is not
        // observable here. Swift try/catch would not help either: it catches
        // only Swift Error values, not the Objective-C NSException a sink
        // invoked from the wrong queue raises. Correctness therefore depends on
        // bridges keeping setBridgeAttached / setEventListenerActive accurate.
        bridgeAttachedLock.lock()
        let attached = bridgeAttached
        bridgeAttachedLock.unlock()
        let delegate = coreDelegate
        let deliveredLive: Bool

        if delegate != nil && attached && isEventListenerActive() {
            DispatchQueue.main.async {
                delegate?.onGeofenceEvent(finalEventData)
            }
            deliveredLive = true
        } else {
            deliveredLive = false
        }

        if !deliveredLive && pendingEventsQueueSize > 0 {
            if let store = pendingEventsStore {
                let evicted = store.append(finalEventData)
                if evicted > 0 {
                    PolyfenceErrorManager.shared.reportError(
                        type: "pending_events_evicted",
                        message: "Pending events queue reached capacity; oldest events dropped",
                        context: [
                            "severity": "warning",
                            "droppedCount": evicted,
                            "platform": "ios"
                        ]
                    )
                }
            } else {
                NSLog("[LocationTracker] queue enabled (size=\(pendingEventsQueueSize)) but store is nil — event dropped")
            }
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
        // Zone name leads the title so the alert names the place, not our
        // category. DWELL and RECOVERY_ENTER are inside-states — only a true
        // EXIT / RECOVERY_EXIT reads as leaving.
        let title: String
        let isInside: Bool
        switch eventType {
        case "ENTER", GeofenceEngine.EVENT_RECOVERY_ENTER:
            title = "Entered \(zoneName)"
            isInside = true
        case GeofenceEngine.EVENT_DWELL:
            title = "Dwelling in \(zoneName)"
            isInside = true
        default:  // EXIT, RECOVERY_EXIT
            title = "Exited \(zoneName)"
            isInside = false
        }

        let content = UNMutableNotificationContent()
        content.title = title
        // Body carries time-in-zone for DWELL only; ENTER/EXIT stay single-line.
        if eventType == GeofenceEngine.EVENT_DWELL, let dwellBody = formatDwellBody(zoneId) {
            content.body = dwellBody
        }

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
        content.categoryIdentifier = isInside ? "POLYFENCE_ZONE_ENTRY" : "POLYFENCE_ZONE_EXIT"

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
     * Human-readable "time in zone" line for DWELL alerts, e.g. "Here 12 min".
     * Returns nil when the engine has no dwell start recorded for the zone.
     */
    private func formatDwellBody(_ zoneId: String) -> String? {
        guard let ms = geofenceEngine.getDwellDurationMs(zoneId) else { return nil }
        let totalMinutes = Int(ms / 60_000)
        if totalMinutes < 1 { return "Here under a minute" }
        if totalMinutes < 60 { return "Here \(totalMinutes) min" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "Here \(h)h" : "Here \(h)h \(m)min"
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
        // Stamp the last VALID fix separately — coarse fixes the engine rejects
        // must not reset the staleness watchdog.
        if geofenceEngine.isValidFix(location) {
            lastValidFixTime = Date().timeIntervalSince1970
        }
        consecutiveGpsFailures = 0
        currentGpsAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil

        // Check for unreliable GPS (large accuracy swings, poor accuracy)
        checkGpsReliability(location)

        // Record in centralized telemetry aggregator
        telemetryAggregator.recordGpsUpdate(
            intervalMs: Int64(currentGpsInterval * 1000),
            accuracyM: Float(location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : 999.0)
        )

        // Raw horizontalAccuracy, negative when the fix carries none — the
        // collector reports it as lastKnownAccuracy, whose absent value is
        // already a negative sentinel.
        PolyfenceDebugCollector.shared.recordLocationUpdate(accuracy: location.horizontalAccuracy)

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
        // Regions monitored from a cold start do not produce a crossing
        // callback for a boundary the device is already inside, so ask the OS
        // for the current state explicitly. This is what gives iOS the
        // starting-state event Android gets from INITIAL_TRIGGER_ENTER.
        guard region.identifier.hasPrefix(OsGeofenceRegistrar.REGION_ID_PREFIX) else { return }
        manager.requestState(for: region)
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        switch state {
        case .inside:
            handleOsRegionEvent(region: region, eventType: "ENTER")
        case .outside, .unknown:
            break
        @unknown default:
            break
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        osGeofenceRegistrar?.recordMonitoringFailure(region: region, error: error)
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        handleOsRegionEvent(region: region, eventType: "ENTER")
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        handleOsRegionEvent(region: region, eventType: "EXIT")
    }

    /// Persist an OS-fired region transition into the pending queue for drain
    /// on the tracker's next boot. Delivery to the consumer happens via the
    /// same drain path in-process events use. The delegate is deliberately
    /// not invoked from here: this callback exists to catch crossings that
    /// happen while the tracker is not running, so there is no live sink.
    ///
    /// Ignores regions we did not register (an application-side
    /// `CLCircularRegion` monitored on the same shared manager), and no-ops
    /// when the store is absent rather than allocating a second store on a
    /// path that would then race the tracker's own writer on the same file.
    ///
    /// Internal (not private) so the parity tests can drive it through the
    /// public `didEnterRegion` / `didExitRegion` delegate methods.
    internal func handleOsRegionEvent(region: CLRegion, eventType: String) {
        let prefix = OsGeofenceRegistrar.REGION_ID_PREFIX
        guard region.identifier.hasPrefix(prefix) else { return }
        // With the flag off, behaviour must be indistinguishable from before
        // this feature existed — including for fences a previous session
        // registered and the OS is still holding.
        guard osGeofenceWakeEnabled else { return }
        // A queue-less wake has nowhere to deposit the crossing, so the whole
        // feature is inert. Surface it rather than losing events to a silent
        // misconfiguration.
        guard pendingEventsQueueSize > 0, let store = pendingEventsStore else {
            PolyfenceErrorManager.shared.reportError(
                type: "os_geofence_queue_disabled",
                message: "OS wake fences are enabled but pendingEventsQueueSize is 0; "
                    + "the woken crossing cannot be stored",
                context: [
                    "severity": "warning",
                    "platform": "ios",
                    "source": LocationTracker.EVENT_SOURCE_OS_GEOFENCE
                ]
            )
            return
        }
        // Gated on the in-process engine RUNNING, not on whether it could
        // deliver live. Those differ exactly where it matters: a detached
        // bridge leaves the engine polling and persisting into this same queue,
        // so gating on deliverability would let both writers record one
        // physical crossing and hand the consumer a duplicate.
        guard !isEngineRunningForOsGeofence else { return }

        let zoneId = String(region.identifier.dropFirst(prefix.count))

        // Region monitoring replays the current state for every fence at
        // registration time, via the requestState call that seeds a newly armed
        // region. Anything that merely restates believed membership is not a
        // crossing and must not reach the consumer as one. Android applies the
        // same rule in its wake receiver; without it here the two platforms
        // disagree about the same journey.
        let impliedInside = eventType == "ENTER"
        if let persisted = zonePersistence?.loadZoneStates()[zoneId],
           persisted == impliedInside {
            return
        }
        // On a wake relaunch the engine has not loaded zones yet, so the live
        // lookup misses and the raw id would reach the consumer as the display
        // name. Disk is the only source that survives the process.
        let zoneName = geofenceEngine.getZoneName(zoneId)
            ?? zonePersistence?.loadAllZones()[zoneId]?.1
            ?? zoneId
        let coord = (region as? CLCircularRegion)?.center

        let eventMap: [String: Any] = [
            "zoneId": zoneId,
            "zoneName": zoneName,
            "eventType": eventType,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "detectionTimeMs": 0.0,
            "gpsAccuracy": 0.0,
            "latitude": coord?.latitude ?? 0.0,
            "longitude": coord?.longitude ?? 0.0,
            "speedMps": 0.0,
            "activityAtEvent": "unknown",
            "distanceToBoundaryM": 0.0,
            "source": LocationTracker.EVENT_SOURCE_OS_GEOFENCE
        ]

        // Persisted membership is the record of where the user is; the queue is
        // only the record of what still needs delivering. Writing both keeps the
        // two agreeing across a wake, which is what stops the relaunched
        // session's first reconcile from raising a RECOVERY_* for a crossing
        // already sitting in the queue — and keeps the crossing reflected in
        // state even if eviction later drops the queued event.
        if eventType == "ENTER" || eventType == "EXIT" {
            zonePersistence?.mergeZoneStates([zoneId: eventType == "ENTER"])
        }

        let evicted = store.append(eventMap)
        if evicted > 0 {
            PolyfenceErrorManager.shared.reportError(
                type: "pending_events_evicted",
                message: "Pending events queue reached capacity; oldest events dropped",
                context: [
                    "severity": "warning",
                    "droppedCount": evicted,
                    "platform": "ios",
                    "source": LocationTracker.EVENT_SOURCE_OS_GEOFENCE
                ]
            )
        }
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
    /// which already does the merge internally.
    /**
     * Full 12-key configuration update, mirroring Kotlin's
     * `LocationTracker.updateConfigurationFromMap`. Applies a partial
     * or complete configuration map to every subsystem the composed
     * `getCurrentConfigurationMap` exposes:
     *   1. SmartGpsConfig (accuracyProfile, updateStrategy,
     *      enableDebugLogging, proximitySettings, movementSettings,
     *      batterySettings) — merged via updateSmartConfigurationFromMap
     *      so unspecified fields survive.
     *   2. GeofenceEngine: gpsAccuracyThreshold, dwellSettings,
     *      clusterSettings.
     *   3. TrackingScheduler.shared: scheduleSettings.
     *   4. activitySettings (via setActivityConfig).
     *   5. disableAlertNotifications (handled inside
     *      updateSmartConfigurationFromMap).
     *
     * Bridges should call this rather than hand-rolling the six extras
     * extractors — it's the single source of truth that round-trips
     * cleanly against getCurrentConfigurationMap and matches the
     * Kotlin implementation's field-for-field coverage.
     */
    /// Numeric coercion for configuration maps. Platform channels deliver the
    /// same field as `Int`, `Double`, or `NSNumber` depending on the bridge's
    /// serialiser, and `Bool` also bridges to `NSNumber` — so it is rejected
    /// explicitly rather than silently read as 0 or 1.
    private static func intValue(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, !(raw is Bool) else { return nil }
        return number.intValue
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, !(raw is Bool) else { return nil }
        return number.doubleValue
    }

    public func updateConfigurationFromMap(_ configMap: [String: Any]) {
        updateSmartConfigurationFromMap(configMap)

        // Delegate to the same public setters the bridges have been
        // calling directly. Route via LocationTracker's wrappers
        // rather than geofenceEngine directly so the ms→seconds
        // conversion for dwellThresholdMs stays consistent with the
        // bridge-side path, and so a future audit only has one
        // place per subsystem to worry about.
        if let gpsAccuracyThreshold = LocationTracker.doubleValue(configMap["gpsAccuracyThreshold"]) {
            setGpsAccuracyThreshold(gpsAccuracyThreshold)
            config?.gpsAccuracyThreshold = gpsAccuracyThreshold
        }

        // Degraded-GPS staleness timeout (0 = off). Gates Option D + signal-lost.
        if let staleness = LocationTracker.doubleValue(configMap["gpsStalenessTimeoutMs"]) {
            gpsStalenessTimeoutMs = staleness
            config?.gpsStalenessTimeoutMs = staleness
            geofenceEngine.setDegradedExitEnabled(staleness > 0)
        }

        // Durable pending-events queue cap (0 = off). Rebuild the store on
        // change so the new cap takes effect on the next append. Shut down the
        // outgoing store first so a mid-flight append cannot race the new
        // store on the same on-disk log. On-disk events survive the rebuild
        // because construction does not touch the log file.
        //
        // Parsed once rather than through a per-numeric-type branch chain: the
        // value has to be applied in memory AND persisted, and a branch chain
        // is a shape where one arm can silently miss a step.
        if let size = LocationTracker.intValue(configMap["pendingEventsQueueSize"]) {
            pendingEventsQueueSize = size
            config?.pendingEventsQueueSize = size
            pendingEventsStore?.shutdown()
            pendingEventsStore = PendingEventsStore(queueSize: size)
        }

        // Automatic replay of queued events (true = on, default). Turning it on
        // while a listener is already live replays immediately — otherwise the
        // switch would not take effect until the consumer happened to
        // resubscribe.
        if let autoDrain = configMap["pendingEventsAutoDrainEnabled"] as? Bool {
            let autoDrainTurnedOn = autoDrain && !pendingEventsAutoDrainEnabled
            pendingEventsAutoDrainEnabled = autoDrain
            config?.pendingEventsAutoDrainEnabled = autoDrain
            if autoDrainTurnedOn && isEventListenerActive() {
                replayQueuedEventsToListener()
            }
        }

        // OS wake-fence slot budget. Applied before the toggle below so a
        // single updateConfiguration carrying both lands the new cap on the
        // registrar this call creates.
        var maxRegionsChanged = false
        if let requested = LocationTracker.intValue(configMap["osGeofenceMaxRegions"]) {
            // Store the clamped value in memory too. Keeping the raw request
            // here would make getConfiguration echo a budget that was never
            // applied, indistinguishable from a genuine cap hit, until the next
            // process start silently swapped it for the persisted clamp.
            let effective = PolyfenceConfig.clampOsGeofenceMaxRegions(requested)
            maxRegionsChanged = effective != osGeofenceMaxRegions
            osGeofenceMaxRegions = effective
            config?.osGeofenceMaxRegions = effective
        }

        // OS wake-fence toggle (false = off, default). Nothing is registered
        // until the app backgrounds, so flipping on with an empty engine is
        // safe. Flipping off stops monitoring any currently-registered regions
        // and clears the health snapshot.
        var wakeChanged = false
        if let osWake = configMap["osGeofenceWakeEnabled"] as? Bool {
            wakeChanged = osWake != osGeofenceWakeEnabled
            osGeofenceWakeEnabled = osWake
            config?.osGeofenceWakeEnabled = osWake
        }
        // The cap is fixed on a constructed registrar, so a cap change while
        // the feature is already on has to rebuild it — otherwise the new
        // budget would not take effect until the next tracker construction.
        if wakeChanged || (maxRegionsChanged && osGeofenceWakeEnabled) {
            osGeofenceRegistrar?.shutdown()
            osGeofenceRegistrar = nil
            if osGeofenceWakeEnabled, let manager = locationManager {
                let registrar = OsGeofenceRegistrar(
                    locationManager: manager,
                    topN: osGeofenceMaxRegions
                )
                registrar.startObservingAppLifecycle()
                osGeofenceRegistrar = registrar
                registrar.requestRefresh()
            }
        }

        if let dwellSettings = configMap["dwellSettings"] as? [String: Any] {
            let dwellEnabled = dwellSettings["enabled"] as? Bool ?? true
            let dwellThresholdMs = dwellSettings["dwellThresholdMs"] as? Int
                ?? Int(GeofenceEngine.DEFAULT_DWELL_THRESHOLD_SECONDS * 1000)
            setDwellConfig(enabled: dwellEnabled, thresholdMs: dwellThresholdMs)
        }

        if let clusterSettings = configMap["clusterSettings"] as? [String: Any] {
            let clusterEnabled = clusterSettings["enabled"] as? Bool ?? false
            let activeRadiusMeters = clusterSettings["activeRadiusMeters"] as? Double
                ?? GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS
            let refreshDistanceMeters = clusterSettings["refreshDistanceMeters"] as? Double
                ?? GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS
            setClusterConfig(
                enabled: clusterEnabled,
                activeRadiusMeters: activeRadiusMeters,
                refreshDistanceMeters: refreshDistanceMeters
            )
        }

        if let scheduleSettings = configMap["scheduleSettings"] as? [String: Any] {
            setScheduleConfig(scheduleSettings)
        }

        if let activitySettings = configMap["activitySettings"] as? [String: Any] {
            setActivityConfig(activitySettings)
        }
    }

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

        // Apply `disableAlertNotifications` symmetrically with the read
        // side: the composed getCurrentConfigurationMap emits it and
        // resetSmartConfiguration includes it, so the write side must
        // honour it too — otherwise
        // `updateConfiguration({disableAlertNotifications: true})`
        // silently does nothing. Handling it here means both iOS
        // bridges pick it up without per-bridge wiring.
        if let disableAlertNotifications = partial["disableAlertNotifications"] as? Bool {
            self.alertNotificationsEnabled = !disableAlertNotifications
        }
    }

    /// Reset smart GPS configuration to defaults
    public func resetSmartConfiguration() {
        // Reset the full 12-field configuration surface, not just
        // SmartGpsConfig. Bridges rely on `resetConfiguration()`
        // clearing every subsystem the composed
        // `getCurrentConfigurationMap` exposes — dwell, cluster,
        // schedule, activity, gpsAccuracyThreshold, and the alert
        // flag included — so a caller can't invoke reset and still
        // observe a previously-set override.
        updateSmartConfiguration(SmartGpsConfig())
        geofenceEngine.setGpsAccuracyThreshold(GeofenceEngine.DEFAULT_GPS_ACCURACY_THRESHOLD)
        geofenceEngine.setDwellConfig(
            enabled: true,
            thresholdSeconds: GeofenceEngine.DEFAULT_DWELL_THRESHOLD_SECONDS
        )
        geofenceEngine.setClusterConfig(
            enabled: false,
            activeRadiusMeters: GeofenceEngine.DEFAULT_CLUSTER_ACTIVE_RADIUS_METERS,
            refreshDistanceMeters: GeofenceEngine.DEFAULT_CLUSTER_REFRESH_DISTANCE_METERS
        )
        TrackingScheduler.shared.updateConfig(nil)
        updateActivityRecognition(ActivitySettings())
        alertNotificationsEnabled = true
    }

    /**
     * Get current smart GPS configuration
     */
    public func getCurrentSmartConfiguration() -> SmartGpsConfig {
        return smartConfig
    }

    /**
     * Full 12-key configuration snapshot for the bridge
     * `getConfiguration()` surface. Composes state from the four
     * places it actually lives:
     *   1. `smartConfig` — top-level scalars + proximity / movement /
     *      battery blocks (via `SmartGpsConfigFactory.toMap`).
     *   2. `geofenceEngine` — GPS accuracy threshold, dwell settings,
     *      cluster settings.
     *   3. `TrackingScheduler.shared` — schedule settings (the shared
     *      singleton stays populated regardless of the tracker's
     *      lifecycle).
     *   4. `activitySettings` on this instance.
     *
     * The shape matches the JS `PolyfenceConfiguration` type and
     * round-trips cleanly through `updateConfigurationFromMap` — all
     * eleven top-level keys are emitted (never `nil`) so bridges can
     * cache and re-apply the full configuration surface.
     */
    public func getCurrentConfigurationMap() -> [String: Any] {
        var base = SmartGpsConfigFactory.toMap(smartConfig)

        base["gpsAccuracyThreshold"] = geofenceEngine.getGpsAccuracyThreshold()
        base["gpsStalenessTimeoutMs"] = gpsStalenessTimeoutMs
        base["pendingEventsQueueSize"] = pendingEventsQueueSize
        base["pendingEventsAutoDrainEnabled"] = pendingEventsAutoDrainEnabled
        base["osGeofenceWakeEnabled"] = osGeofenceWakeEnabled
        base["osGeofenceMaxRegions"] = osGeofenceMaxRegions
        base["dwellSettings"] = geofenceEngine.getDwellConfigMap()
        base["clusterSettings"] = geofenceEngine.getClusterConfigMap()
        base["scheduleSettings"] = TrackingScheduler.shared.getConfigMap()

        // Materialise activity interval overrides (or their compile-
        // time defaults) instead of stripping nils, so the composed
        // map always includes the full 8-key activitySettings block.
        // Same shape-stability contract as the Kotlin composed
        // accessor; without this, `getConfiguration()` returns a
        // sparse `activitySettings` whose interval fields silently
        // drop when the user hasn't overridden them, and TypeScript /
        // Dart consumers see `undefined` for documented defaults.
        let activityMap: [String: Any] = [
            "enabled": activitySettings.enabled,
            "confidenceThreshold": activitySettings.confidenceThreshold,
            "debounceSeconds": activitySettings.debounceSeconds,
            "stillIntervalMs": Int((activitySettings.stillIntervalMs ?? ActivitySettings.DEFAULT_STILL_INTERVAL) * 1000),
            "walkingIntervalMs": Int((activitySettings.walkingIntervalMs ?? ActivitySettings.DEFAULT_WALKING_INTERVAL) * 1000),
            "runningIntervalMs": Int((activitySettings.runningIntervalMs ?? ActivitySettings.DEFAULT_RUNNING_INTERVAL) * 1000),
            "cyclingIntervalMs": Int((activitySettings.cyclingIntervalMs ?? ActivitySettings.DEFAULT_CYCLING_INTERVAL) * 1000),
            "drivingIntervalMs": Int((activitySettings.drivingIntervalMs ?? ActivitySettings.DEFAULT_DRIVING_INTERVAL) * 1000)
        ]
        base["activitySettings"] = activityMap

        // Alert-notifications flag also lives outside SmartGpsConfig
        // (instance property, mutated via setAlertNotificationsEnabled).
        // Emit it as `disableAlertNotifications` — the shape the
        // bridges' TypeScript / Dart configuration types expose — so a
        // round-trip `getConfiguration()` → cache → user code doesn't
        // silently reset the caller's original init preference.
        base["disableAlertNotifications"] = !alertNotificationsEnabled

        return base
    }

    /// Most recent GPS accuracy in metres, or `nil` if no fix has
    /// landed yet. Exposed so bridge `status`-event payloads can
    /// include the latest known accuracy instead of hardcoding nil —
    /// paired with the runtime_status emission which uses the same
    /// value to stabilise the field across emissions.
    public func getLastKnownAccuracy() -> Double? {
        return currentGpsAccuracy
    }

    /**
     * Get current zone states from GeofenceEngine
     * Returns which zones the plugin believes the device is currently inside
     * @return Dictionary of zoneId to isInside state
     */
    public func getCurrentZoneStates() -> [String: Bool] {
        return geofenceEngine.getCurrentZoneStates()
    }

    /// Tell the tracker whether the bridge's delivery sink is currently receiving.
    /// Bridges call `false` when their platform-channel sink is torn down (e.g.
    /// on `FlutterEventSink` teardown, RN bridge invalidation) and `true` when
    /// it is re-attached. The tracker uses this to decide whether a fired event
    /// will actually reach the consumer or drop silently — in the drop case,
    /// the event is persisted into the durable queue (when
    /// `pendingEventsQueueSize > 0`). Default is `true` — a direct-Swift
    /// consumer with no bridge sees today's behaviour with no change.
    public func setBridgeAttached(_ attached: Bool) {
        bridgeAttachedLock.lock()
        bridgeAttached = attached
        bridgeAttachedLock.unlock()
    }

    /// Tell the tracker whether a consumer's event listener is live. See the
    /// static overload for the contract; this is the instance half.
    public func setEventListenerActive(_ active: Bool) {
        eventListenerLock.lock()
        let changed = eventListenerActive != active
        if changed { eventListenerActive = active }
        eventListenerLock.unlock()
        guard changed, active else { return }
        replayQueuedEventsToListener()
    }

    private func isEventListenerActive() -> Bool {
        eventListenerLock.lock()
        defer { eventListenerLock.unlock() }
        return eventListenerActive
    }

    /// Drain the durable queue and hand the events to the consumer through the
    /// same delegate callback live events use. No-op unless the queue is on, the
    /// auto-drain flag is set, and something is actually queued.
    private func replayQueuedEventsToListener() {
        guard pendingEventsAutoDrainEnabled else { return }
        guard pendingEventsQueueSize > 0 else { return }
        guard let store = pendingEventsStore else { return }
        guard zoneStatesRestored else {
            autoDrainDeferredUntilZonesRestored = true
            return
        }
        autoDrainDeferredUntilZonesRestored = false
        // Nothing queued that this store has not already handed over — skip the
        // file read so repeated attach/detach cycles cost nothing.
        guard store.mayHaveEvents() else { return }

        // Composite drain-and-apply holds `reconcileLock` across the store drain
        // and the state application, which is what keeps a concurrent
        // reconcileZoneStates on the location-callback thread from mis-firing
        // RECOVERY_* for a zone this batch already resolved.
        let drained = geofenceEngine.drainAndApply(store)
        guard !drained.isEmpty else { return }

        guard let delegate = coreDelegate else {
            NSLog("[LocationTracker] listener signalled active but no delegate registered — re-queueing \(drained.count) event(s)")
            drained.forEach { store.append($0) }
            return
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let replayed = drained.map { LocationTracker.markDeliveredLate($0, nowMs: nowMs) }
        DispatchQueue.main.async {
            for event in replayed {
                delegate.onGeofenceEvent(event)
            }
        }
        NSLog("[LocationTracker] replayed \(replayed.count) queued event(s) to the consumer's listener")
    }

    /// Stamp the replay-provenance fields onto a queued event. `capturedTs` is
    /// the moment the crossing was detected — the `timestamp` the event carried
    /// when it was queued — so `queuedDurationMs` measures the wait, not the
    /// round trip.
    private static func markDeliveredLate(_ event: [String: Any], nowMs: Int64) -> [String: Any] {
        var out = event
        let capturedTs: Int64
        if let ts = event["timestamp"] as? Int64 {
            capturedTs = ts
        } else if let n = event["timestamp"] as? NSNumber {
            capturedTs = n.int64Value
        } else {
            capturedTs = nowMs
        }
        out["deliveredLate"] = true
        out["capturedTs"] = capturedTs
        out["queuedDurationMs"] = max(0, nowMs - capturedTs)
        return out
    }

    /// True when the in-process polling engine is running and will therefore
    /// record this crossing itself — either delivering it live or persisting it
    /// through the same queue the OS wake path writes to.
    ///
    /// Deliberately NOT "can deliver live": a detached bridge leaves the engine
    /// polling and persisting, so gating the OS path on deliverability would let
    /// both writers record one physical crossing.
    internal var isEngineRunningForOsGeofence: Bool { return trackingEnabled }

    /// Test-only seam for iOS unit tests that need to drive the persist-hook
    /// without wiring a real CLLocationManager fix. Underscore-prefixed and
    /// internal-scoped to keep it out of the public API while allowing
    /// `@testable import PolyfenceCore` to reach it. Do not call from
    /// production code.
    internal func _testInvokeHandleGeofenceEvent(zoneId: String, eventType: String, location: CLLocation) {
        trackingEnabled = true
        handleGeofenceEvent(zoneId: zoneId, eventType: eventType, location: location, detectionTimeMs: 5.0)
    }

    /// Drain every event that was persisted while a bridge was not receiving.
    /// Returns the events in oldest-first order and removes them from disk in
    /// the same serialised block. Returns an empty array when no events are
    /// queued or the store is not initialised.
    ///
    /// Drained events are also applied to the engine's zoneStates so a
    /// subsequent reconcileZoneStates sees the post-drain truth: any zone
    /// whose drain-final state matches actual position produces no RECOVERY
    /// event; any zone with a genuine mismatch (e.g. eviction dropped a later
    /// crossing) still recovers via the normal reconcile mismatch path.
    public func drainPendingEvents() -> [[String: Any]] {
        // Composite drain-and-apply holds `reconcileLock` across both
        // operations. Routing here (instead of drain + separate apply)
        // closes the window where a concurrent `reconcileZoneStates`
        // on the location-callback thread would see post-drain /
        // pre-apply state and mis-fire `RECOVERY_*` for a zone the
        // drained batch already resolved.
        return geofenceEngine.drainAndApply(pendingEventsStore)
    }

    /// Cumulative count of events that have been evicted from the pending queue
    /// since first construction of a store on this device (oldest-first
    /// eviction fires when the queue cap is reached). Persists across process
    /// restarts. Does not reset.
    public func pendingEventsDroppedCount() -> Int64 {
        return pendingEventsStore?.currentDroppedCount() ?? 0
    }

    /// Latest snapshot of the OS-geofence registration state as a
    /// `{ requested, registered, lastError }` map for the debug-collector
    /// systemStatus surface. `nil` when `osGeofenceWakeEnabled` is off or no
    /// registration has been attempted yet, matching the "no health data"
    /// contract consumers use to distinguish opt-out from cap-hit.
    public func osGeofenceRegistrationHealth() -> [String: Any]? {
        return osGeofenceRegistrar?.healthMap()
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
        // Notify the OS-geofence registrar so it can recompute the top-N-nearest
        // set as the user drives past the previously-registered fringe. Cheap
        // when the registrar is off (nil) or when the movement threshold has
        // not been crossed (compares two coordinates, no allocations).
        osGeofenceRegistrar?.onLocationUpdate(location)
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

        // Always present so every emission carries the same key set —
        // consumers can rely on a stable shape rather than checking for
        // absent vs present keys across emissions. NSNull bridges to
        // null on the Dart / JavaScript side.
        if let accuracy = currentGpsAccuracy, accuracy >= 0 {
            status["currentGpsAccuracy"] = accuracy
        } else {
            status["currentGpsAccuracy"] = NSNull()
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
/// calls from iOS bridges.
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

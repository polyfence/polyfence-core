import Foundation
import CoreMotion

/**
 * Manages activity recognition using CoreMotion
 * Detects user activity (still, walking, running, cycling, driving)
 * and notifies listeners when activity changes
 */
class ActivityRecognitionManager {

    private static let TAG = "ActivityRecognition"

    // Motion activity manager
    private let motionActivityManager = CMMotionActivityManager()
    private let operationQueue = OperationQueue()

    // Synchronization for thread-safe access to mutable state
    private let syncQueue = DispatchQueue(label: "io.polyfence.ActivityRecognitionManager")

    // Current state
    private var currentActivity: ActivityType = .unknown
    private var currentConfidence: Int = 0
    private var isEnabled: Bool = false
    private var settings: ActivitySettings = ActivitySettings()

    // Debounce handling
    private var pendingActivityChange: ActivityType?
    private var debounceTimer: Timer?

    // Callback for activity changes
    private var onActivityChanged: ((ActivityType, Int) -> Void)?

    // ML Telemetry: time spent per activity type (seconds)
    private var activityTime: [String: TimeInterval] = [:]
    private var lastActivityChangeTime: TimeInterval = Date().timeIntervalSince1970
    private var lastTrackedActivity: String = "unknown"

    init() {
        operationQueue.name = "io.polyfence.activityRecognition"
        operationQueue.maxConcurrentOperationCount = 1
    }

    /**
     * Start activity recognition
     */
    func start(settings: ActivitySettings, callback: @escaping (ActivityType, Int) -> Void) {
        guard settings.enabled else {
            NSLog("[\(Self.TAG)] Activity recognition disabled in settings")
            return
        }

        guard CMMotionActivityManager.isActivityAvailable() else {
            NSLog("[\(Self.TAG)] Activity recognition not available on this device")
            return
        }

        let status = CMMotionActivityManager.authorizationStatus()

        // If explicitly denied, we cannot proceed
        if status == .denied || status == .restricted {
            NSLog("[\(Self.TAG)] Activity recognition permission denied or restricted")
            return
        }

        syncQueue.sync {
            self.settings = settings
            self.onActivityChanged = callback
            self.isEnabled = true
        }

        // Start activity updates - this also triggers permission prompt if status is .notDetermined
        // On iOS, calling startActivityUpdates is the only way to request motion permission
        NSLog("[\(Self.TAG)] Starting activity updates (status: \(status.rawValue))")

        motionActivityManager.startActivityUpdates(to: operationQueue) { [weak self] activity in
            guard let self = self, let activity = activity else { return }
            self.handleActivityUpdate(activity)
        }

        NSLog("[\(Self.TAG)] Activity recognition started")
    }

    /**
     * Stop activity recognition
     */
    func stop() {
        let shouldStop = syncQueue.sync { self.isEnabled }
        guard shouldStop else { return }

        // Cancel pending debounce
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingActivityChange = nil

        // Stop activity updates
        motionActivityManager.stopActivityUpdates()

        syncQueue.sync {
            self.isEnabled = false
            self.accumulateActivityTime()
            self.currentActivity = .unknown
            self.currentConfidence = 0
        }

        NSLog("[\(Self.TAG)] Activity recognition stopped")
    }

    /**
     * Update settings
     */
    func updateSettings(_ newSettings: ActivitySettings) {
        let (wasEnabled, callback) = syncQueue.sync { () -> (Bool, ((ActivityType, Int) -> Void)?) in
            let wasEnabled = self.settings.enabled
            self.settings = newSettings
            return (wasEnabled, self.onActivityChanged)
        }

        if !wasEnabled && newSettings.enabled {
            // Was disabled, now enabled - start
            if let callback = callback {
                start(settings: newSettings, callback: callback)
            }
        } else if wasEnabled && !newSettings.enabled {
            // Was enabled, now disabled - stop
            stop()
        }
    }

    /**
     * Get current detected activity
     */
    func getCurrentActivity() -> ActivityType {
        return syncQueue.sync { self.currentActivity }
    }

    /**
     * Get current activity confidence
     */
    func getCurrentConfidence() -> Int {
        return syncQueue.sync { self.currentConfidence }
    }

    /**
     * Check if activity recognition is running
     */
    func isRunning() -> Bool {
        return syncQueue.sync { self.isEnabled }
    }

    /**
     * Check if activity recognition permission is granted or can be requested
     * Returns true for .authorized and .notDetermined (can request)
     * Returns false for .denied and .restricted
     */
    func hasPermission() -> Bool {
        let status = CMMotionActivityManager.authorizationStatus()
        // .notDetermined means we haven't asked yet - we can still start and trigger the prompt
        return status == .authorized || status == .notDetermined
    }

    /**
     * Handle activity update from CoreMotion
     */
    private func handleActivityUpdate(_ activity: CMMotionActivity) {
        let newActivity = mapToActivityType(activity)
        let confidence = mapConfidence(activity.confidence)

        NSLog("[\(Self.TAG)] Detected: \(newActivity) (confidence: \(confidence)%)")

        // Check confidence threshold and compare with current activity inside sync block
        let (confidenceThreshold, currentActivityState) = syncQueue.sync { () -> (Int, ActivityType) in
            return (self.settings.confidenceThreshold, self.currentActivity)
        }

        guard confidence >= confidenceThreshold else {
            NSLog("[\(Self.TAG)] Confidence below threshold (\(confidenceThreshold)%), ignoring")
            return
        }

        // Check if activity changed
        if newActivity != currentActivityState {
            applyDebounce(newActivity: newActivity, confidence: confidence)
        }
    }

    /**
     * Apply debounce before confirming activity change
     */
    private func applyDebounce(newActivity: ActivityType, confidence: Int) {
        let debounceSeconds = syncQueue.sync { self.settings.debounceSeconds }

        let shouldReturn = syncQueue.sync { () -> Bool in
            // If same activity is already pending, let the timer complete (don't reset)
            if newActivity == self.pendingActivityChange && self.debounceTimer != nil {
                NSLog("[\(Self.TAG)] Same activity pending, letting timer complete")
                return true
            }

            // Cancel any pending change for a DIFFERENT activity
            self.debounceTimer?.invalidate()
            self.pendingActivityChange = newActivity

            return false
        }

        if shouldReturn {
            return
        }

        // Schedule debounce timer on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let onActivityChanged = self.syncQueue.sync { self.onActivityChanged }
            self.syncQueue.sync {
                self.debounceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(debounceSeconds), repeats: false) { [weak self] _ in
                    guard let self = self else { return }

                    self.syncQueue.sync {
                        if self.pendingActivityChange == newActivity {
                            NSLog("[\(Self.TAG)] Activity confirmed after debounce: \(newActivity)")
                            self.accumulateActivityTime()
                            self.currentActivity = newActivity
                            self.currentConfidence = confidence
                        }

                        self.pendingActivityChange = nil
                        self.debounceTimer = nil
                    }
                }
            }

            onActivityChanged?(newActivity, confidence)
            NSLog("[\(Self.TAG)] Debounce started: \(debounceSeconds)s for \(newActivity)")
        }
    }

    // MARK: - ML Telemetry

    /**
     * Accumulate time spent in the current activity before switching.
     * Must be called BEFORE updating currentActivity (already in sync context).
     */
    private func accumulateActivityTime() {
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastActivityChangeTime
        if elapsed > 0 {
            let key = lastTrackedActivity
            activityTime[key] = (activityTime[key] ?? 0) + elapsed
        }
        lastActivityChangeTime = now
        lastTrackedActivity = currentActivity.rawValue.lowercased()
    }

    /**
     * Finalize the last activity segment before reading the distribution.
     */
    func finalizeSession() {
        syncQueue.sync {
            self.accumulateActivityTime()
        }
    }

    /**
     * Returns activity distribution as proportions (0.0-1.0).
     */
    func getActivityDistribution() -> [String: Double] {
        return syncQueue.sync {
            let total = self.activityTime.values.reduce(0, +)
            guard total > 0 else { return [:] }
            return self.activityTime.mapValues { $0 / total }
        }
    }

    /**
     * Reset telemetry counters for a new session.
     */
    func resetTelemetry() {
        syncQueue.sync {
            self.activityTime.removeAll()
            self.lastActivityChangeTime = Date().timeIntervalSince1970
            self.lastTrackedActivity = self.currentActivity.rawValue.lowercased()
        }
    }

    /**
     * Map CMMotionActivity to our ActivityType enum
     */
    private func mapToActivityType(_ activity: CMMotionActivity) -> ActivityType {
        // Priority order: automotive > cycling > running > walking > stationary
        if activity.automotive {
            return .driving
        } else if activity.cycling {
            return .cycling
        } else if activity.running {
            return .running
        } else if activity.walking {
            return .walking
        } else if activity.stationary {
            return .still
        } else {
            return .unknown
        }
    }

    /**
     * Map CMMotionActivityConfidence to percentage
     */
    private func mapConfidence(_ confidence: CMMotionActivityConfidence) -> Int {
        switch confidence {
        case .low:
            return 33
        case .medium:
            return 66
        case .high:
            return 100
        @unknown default:
            return 0
        }
    }
}

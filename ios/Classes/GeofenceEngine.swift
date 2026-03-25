import Foundation
import CoreLocation

/**
 * Core geofencing detection engine for iOS
 * Single responsibility: GPS location -> zone detection -> events
 * Ported from Android GeofenceEngine.kt
 */
class GeofenceEngine {

    // MARK: - Constants
    internal static let EARTH_RADIUS_METERS: Double = 6371000.0
    static let TAG = "GeofenceEngine"

    // State recovery event types
    static let EVENT_RECOVERY_ENTER = "RECOVERY_ENTER"
    static let EVENT_RECOVERY_EXIT = "RECOVERY_EXIT"

    // Dwell event type
    static let EVENT_DWELL = "DWELL"

    // Default dwell threshold (5 minutes)
    static let DEFAULT_DWELL_THRESHOLD_SECONDS: TimeInterval = 300.0 // 300 seconds = 5 minutes

    // MARK: - Properties
    // Synchronization for thread-safe access to zone data/state
    private let syncQueue = DispatchQueue(label: "io.polyfence.GeofenceEngine.sync")
    private var zones: [String: ZoneData] = [:]
    private var zoneStates: [String: Bool] = [:]
    private var zoneConfidence: [String: ZoneConfidence] = [:]

    // Dwell time tracking: zoneId -> entry timestamp (seconds since epoch)
    private var zoneEntryTimes: [String: TimeInterval] = [:]
    // Track which zones have already fired dwell events this session
    private var dwellEventsFired: [String: Bool] = [:]
    // Dwell threshold in seconds (configurable)
    private var dwellThresholdSeconds: TimeInterval = GeofenceEngine.DEFAULT_DWELL_THRESHOLD_SECONDS
    // Whether dwell detection is enabled
    private var dwellEnabled: Bool = true

    // Configuration for validation
    private var requireConfirmation: Bool = true
    private var confirmationPoints: Int = 2
    private var confirmationTimeoutMs: TimeInterval = 10.0 // 10 seconds

    // GPS accuracy threshold in meters (default: 100m to match Android)
    private var gpsAccuracyThreshold: Double = 100.0

    // Zone clustering configuration
    private var clusteringEnabled: Bool = false
    private var clusterActiveRadiusMeters: Double = 5000.0
    private var clusterRefreshDistanceMeters: Double = 1000.0
    private var clusterCenterLat: Double?
    private var clusterCenterLng: Double?
    private var activeZoneIds: Set<String> = []

    // Event callbacks - includes detection time in milliseconds
    private var eventCallback: ((String, String, CLLocation, Double) -> Void)?

    // ML Telemetry: false event tracking (enter->exit reversal within 30s)
    private var lastEventPerZone: [String: (eventType: String, timestamp: TimeInterval)] = [:]
    private var lastEventWasQuickReversal: [String: Bool] = [:]
    private var falseEventCount: Int = 0

    // ML Telemetry: dwell durations (minutes)
    private var dwellDurationsMinutes: [Double] = []

    // ML Telemetry: zone transition counter
    private var zoneTransitionCount: Int = 0

    // Performance tracking
    private var performanceMetrics: [String: Double] = [:]

    // Zone state persistence (injected by LocationTracker)
    private var zonePersistence: ZonePersistence?

    // Track if state was recovered from persistence on startup
    private var stateRecoveredFromPersistence = false

    /**
     * Zone confidence tracking (ported from Android)
     */
    private class ZoneConfidence {
        var insideCount: Int = 0
        var outsideCount: Int = 0
        var lastDetection: TimeInterval = 0
        var confirmedState: Bool = false
    }

    // MARK: - Public Methods

    /**
     * Set callback for geofence events
     * Callback receives: zoneId, eventType, location, detectionTimeMs
     */
    func setEventCallback(_ callback: @escaping (String, String, CLLocation, Double) -> Void) {
        eventCallback = callback
    }

    /**
     * Configure validation settings
     */
    func setValidationConfig(requireConfirmation: Bool, confirmationPoints: Int = 2) {
        self.requireConfirmation = requireConfirmation
        self.confirmationPoints = confirmationPoints
    }

    /**
     * Set GPS accuracy threshold in meters
     * Locations with accuracy worse than this are rejected
     * Default: 100m (matches Android for platform parity)
     */
    func setGpsAccuracyThreshold(_ threshold: Double) {
        self.gpsAccuracyThreshold = threshold
    }

    /**
     * Configure dwell detection
     * @param enabled Whether dwell detection is enabled
     * @param thresholdSeconds How long (seconds) device must stay in zone before DWELL fires
     */
    func setDwellConfig(enabled: Bool, thresholdSeconds: TimeInterval = GeofenceEngine.DEFAULT_DWELL_THRESHOLD_SECONDS) {
        self.dwellEnabled = enabled
        self.dwellThresholdSeconds = thresholdSeconds
        NSLog("[\(GeofenceEngine.TAG)] Dwell config: enabled=\(enabled), threshold=\(thresholdSeconds)s")
    }

    /**
     * Configure zone clustering for large zone sets
     * @param enabled Whether clustering is enabled (default: false)
     * @param activeRadiusMeters Radius to check zones within (default: 5000m)
     * @param refreshDistanceMeters Distance to move before refreshing active cluster (default: 1000m)
     */
    func setClusterConfig(enabled: Bool, activeRadiusMeters: Double = 5000.0, refreshDistanceMeters: Double = 1000.0) {
        self.clusteringEnabled = enabled
        self.clusterActiveRadiusMeters = activeRadiusMeters
        self.clusterRefreshDistanceMeters = refreshDistanceMeters
        // Reset cluster center to force refresh on next location update
        self.clusterCenterLat = nil
        self.clusterCenterLng = nil
        self.activeZoneIds.removeAll()
        NSLog("[\(GeofenceEngine.TAG)] Cluster config: enabled=\(enabled), activeRadius=\(activeRadiusMeters)m, refreshDistance=\(refreshDistanceMeters)m")
    }

    /**
     * Check if cluster needs to be refreshed based on movement from cluster center
     */
    private func shouldRefreshCluster(_ location: CLLocation) -> Bool {
        guard let centerLat = clusterCenterLat, let centerLng = clusterCenterLng else {
            return true
        }

        let clusterCenter = CLLocation(latitude: centerLat, longitude: centerLng)
        let distance = location.distance(from: clusterCenter)
        return distance >= clusterRefreshDistanceMeters
    }

    /**
     * Refresh the active zone cluster around the given location
     */
    private func refreshCluster(_ location: CLLocation) {
        clusterCenterLat = location.coordinate.latitude
        clusterCenterLng = location.coordinate.longitude
        activeZoneIds.removeAll()

        var activatedZonesList: [String] = []

        for (zoneId, zone) in zones {
            let zoneCenter = zone.calculateCenter()
            let zoneCenterLocation = CLLocation(latitude: zoneCenter.latitude, longitude: zoneCenter.longitude)
            let distance = location.distance(from: zoneCenterLocation)

            // Include zone if its center is within active radius
            // Also include zones whose boundary might intersect (add zone radius buffer)
            let effectiveRadius = clusterActiveRadiusMeters + (zone.radius ?? 0.0)
            if distance <= effectiveRadius {
                activeZoneIds.insert(zoneId)
                activatedZonesList.append(zone.zoneName.isEmpty ? zoneId : zone.zoneName)
            }
        }

        NSLog("[\(GeofenceEngine.TAG)] Cluster refreshed at (\(location.coordinate.latitude), \(location.coordinate.longitude)): \(activatedZonesList.count) of \(zones.count) zones active - [\(activatedZonesList.joined(separator: ", "))]")
    }

    /**
     * Get zones to check based on clustering configuration
     */
    private func getZonesToCheck() -> [String: ZoneData] {
        if clusteringEnabled && !activeZoneIds.isEmpty {
            return zones.filter { activeZoneIds.contains($0.key) }
        } else {
            return zones
        }
    }

    /**
     * Set zone persistence for state recovery across service restarts
     */
    func setZonePersistence(_ persistence: ZonePersistence) {
        self.zonePersistence = persistence
    }

    /**
     * Load persisted zone states on service restart
     * Should be called after zones are loaded but before location updates start
     */
    func loadPersistedZoneStates() {
        guard let persistence = zonePersistence else { return }

        guard persistence.hasPersistedZoneStates() else {
            NSLog("[\(GeofenceEngine.TAG)] No persisted zone states found (fresh install or data wipe)")
            stateRecoveredFromPersistence = false
            return
        }

        let persistedStates = persistence.loadZoneStates()
        guard !persistedStates.isEmpty else {
            NSLog("[\(GeofenceEngine.TAG)] Persisted zone states empty")
            stateRecoveredFromPersistence = false
            return
        }

        // Only load states for zones that are currently registered
        var loadedCount = 0
        syncQueue.sync {
            for (zoneId, isInside) in persistedStates {
                if self.zones[zoneId] != nil {
                    self.zoneStates[zoneId] = isInside
                    loadedCount += 1
                    NSLog("[\(GeofenceEngine.TAG)] Restored state for zone \(zoneId): \(isInside ? "INSIDE" : "OUTSIDE")")
                }
            }
        }

        stateRecoveredFromPersistence = loadedCount > 0
        let insideCount = persistedStates.values.filter { $0 }.count
        NSLog("[\(GeofenceEngine.TAG)] Loaded \(loadedCount) persisted zone states (\(insideCount) were inside)")
    }

    /**
     * Reconcile zone states with current location after service restart
     * Fires RECOVERY_ENTER/RECOVERY_EXIT events for mismatches
     * Should be called with first valid location after restart
     */
    func reconcileZoneStates(_ location: CLLocation) {
        if !stateRecoveredFromPersistence {
            // No persisted state - establish initial state and fire ENTER events for zones we're inside
            NSLog("[\(GeofenceEngine.TAG)] No persisted state - establishing initial state from current location")
            let checkStartTime = CFAbsoluteTimeGetCurrent()
            let snapshot: [(String, ZoneData)] = syncQueue.sync { self.zones.map { ($0.key, $0.value) } }
            for (zoneId, zone) in snapshot {
                let isInside = zone.contains(location)
                syncQueue.sync { self.zoneStates[zoneId] = isInside }

                // Fire ENTER event for zones we're currently inside (fresh install behavior)
                if isInside {
                    let detectionTimeMs = (CFAbsoluteTimeGetCurrent() - checkStartTime) * 1000.0
                    NSLog("[\(GeofenceEngine.TAG)] Initial state: inside zone \(zoneId) -> firing ENTER")
                    eventCallback?(zoneId, "ENTER", location, detectionTimeMs)
                }
            }
            persistAllZoneStates()
            return
        }

        NSLog("[\(GeofenceEngine.TAG)] Reconciling zone states with current location...")
        let checkStartTime = CFAbsoluteTimeGetCurrent()
        var reconciliationCount = 0

        let snapshot: [(String, ZoneData)] = syncQueue.sync { self.zones.map { ($0.key, $0.value) } }
        for (zoneId, zone) in snapshot {
            let persistedState = syncQueue.sync { self.zoneStates[zoneId] ?? false }
            let actualState = zone.contains(location)

            if persistedState != actualState {
                reconciliationCount += 1
                syncQueue.sync { self.zoneStates[zoneId] = actualState }

                let detectionTimeMs = (CFAbsoluteTimeGetCurrent() - checkStartTime) * 1000.0

                if actualState {
                    // Was outside (persisted), now inside (actual) -> fire RECOVERY_ENTER
                    NSLog("[\(GeofenceEngine.TAG)] State mismatch for zone \(zoneId): was OUTSIDE, now INSIDE -> firing RECOVERY_ENTER")
                    eventCallback?(zoneId, GeofenceEngine.EVENT_RECOVERY_ENTER, location, detectionTimeMs)
                } else {
                    // Was inside (persisted), now outside (actual) -> fire RECOVERY_EXIT
                    NSLog("[\(GeofenceEngine.TAG)] State mismatch for zone \(zoneId): was INSIDE, now OUTSIDE -> firing RECOVERY_EXIT")
                    eventCallback?(zoneId, GeofenceEngine.EVENT_RECOVERY_EXIT, location, detectionTimeMs)
                }
            }
        }

        if reconciliationCount > 0 {
            NSLog("[\(GeofenceEngine.TAG)] Reconciled \(reconciliationCount) zone state mismatches")
            persistAllZoneStates()
        } else {
            NSLog("[\(GeofenceEngine.TAG)] All zone states match current location - no reconciliation needed")
        }

        stateRecoveredFromPersistence = false // Reset flag after reconciliation
    }

    /**
     * Persist all current zone states (called after reconciliation or bulk changes)
     */
    private func persistAllZoneStates() {
        guard let persistence = zonePersistence else { return }
        let states = syncQueue.sync { self.zoneStates }
        persistence.saveZoneStates(states)
    }

    /**
     * Persist single zone state change (called on each transition)
     */
    private func persistZoneState(zoneId: String, isInside: Bool) {
        guard let persistence = zonePersistence else { return }
        persistence.saveZoneState(zoneId: zoneId, isInside: isInside)
    }

    /**
     * Get current zone states for health check API
     */
    func getCurrentZoneStates() -> [String: Bool] {
        return syncQueue.sync { self.zoneStates }
    }

    /**
     * Check if state was recovered from persistence on last startup
     */
    func wasStateRecoveredFromPersistence() -> Bool {
        return stateRecoveredFromPersistence
    }

    /**
     * Add zone for monitoring using typed configuration
     */
    func addZone(config: ZoneConfig, completion: ((Bool) -> Void)? = nil) throws {
        try addZoneInternal(zoneId: config.id, zoneName: config.name, zoneData: config.toMap(), completion: completion)
    }

    /**
     * Add zone for monitoring from a raw dictionary.
     * Prefer `addZone(config:)` with `ZoneConfig` for type safety.
     */
    @available(*, deprecated, message: "Use addZone(config:) with ZoneConfig for type safety")
    func addZone(zoneId: String, zoneName: String, zoneData: [String: Any], completion: ((Bool) -> Void)? = nil) throws {
        try addZoneInternal(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData, completion: completion)
    }

    private func addZoneInternal(zoneId: String, zoneName: String, zoneData: [String: Any], completion: ((Bool) -> Void)? = nil) throws {
        let memoryBefore = getCurrentMemoryUsage()

        let zone = try ZoneData.fromMap(zoneId: zoneId, zoneName: zoneName, zoneData: zoneData)

        // Zone insertion is synchronous — callers can rely on zone being available after return
        syncQueue.sync {
            self.zones[zoneId] = zone
            self.zoneStates[zoneId] = false // Initially outside
            // Reset any previous confidence state if re-adding
            self.zoneConfidence[zoneId] = ZoneConfidence()
        }

        // Fire completion on background queue to avoid blocking caller with monitoring
        DispatchQueue.global(qos: .utility).async {
            let memoryAfter = self.getCurrentMemoryUsage()
            let _ = memoryAfter - memoryBefore
            completion?(true)
        }
    }

    /**
     * Remove zone from monitoring
     */
    func removeZone(zoneId: String) {
        syncQueue.sync {
            self.zones.removeValue(forKey: zoneId)
            self.zoneStates.removeValue(forKey: zoneId)
            self.zoneConfidence.removeValue(forKey: zoneId)
            self.zoneEntryTimes.removeValue(forKey: zoneId)
            self.dwellEventsFired.removeValue(forKey: zoneId)
        }

        // Remove persisted state
        zonePersistence?.removeZoneState(zoneId: zoneId)
    }

    /**
     * Clear all zones
     */
    func clearAllZones() {
        syncQueue.sync {
            self.zones.removeAll()
            self.zoneStates.removeAll()
            self.zoneConfidence.removeAll()
            self.zoneEntryTimes.removeAll()
            self.dwellEventsFired.removeAll()
        }

        // Clear persisted states
        zonePersistence?.clearAllZoneStates()
    }

    /**
     * Get zone name by ID
     */
    func getZoneName(_ zoneId: String) -> String? {
        return syncQueue.sync { self.zones[zoneId]?.zoneName }
    }

    /**
     * Enhanced check location (ported from Android)
     */
    func checkLocation(_ location: CLLocation) {
        guard isValidLocation(location) else { return }

        // Handle clustering: refresh active zones if needed
        if clusteringEnabled {
            if shouldRefreshCluster(location) {
                syncQueue.sync {
                    refreshCluster(location)
                }
            }
        }

        // Take a snapshot of current zones to avoid concurrent modification during iteration
        // Use clustered zones if enabled, otherwise all zones
        let snapshot: [(String, ZoneData)] = syncQueue.sync {
            let zonesToCheck = self.getZonesToCheck()
            return zonesToCheck.map { ($0.key, $0.value) }
        }
        let overallStartTime = CFAbsoluteTimeGetCurrent()
        let speed = location.speed * 3.6 // Convert m/s to km/h

        var zoneCheckCount = 0
        var totalAlgorithmTime: TimeInterval = 0
        var totalConfidenceTime: TimeInterval = 0

        for (zoneId, zone) in snapshot {
            zoneCheckCount += 1
            let zoneStartTime = CFAbsoluteTimeGetCurrent()
            let currentState = syncQueue.sync { self.zoneStates[zoneId] ?? false }

            // Precise algorithm timing
            let algorithmStartTime = CFAbsoluteTimeGetCurrent()
            let isInside = zone.contains(location)
            let algorithmDuration = CFAbsoluteTimeGetCurrent() - algorithmStartTime
            totalAlgorithmTime += algorithmDuration
            _ = (CFAbsoluteTimeGetCurrent() - zoneStartTime) * 1000

            // Smart validation: Use confirmation based on speed and zone characteristics
            let useConfirmation = requireConfirmation ? shouldUseConfirmation(speed: speed, zoneRadius: zone.radius) : false

            if useConfirmation {
                let confidenceStartTime = CFAbsoluteTimeGetCurrent()
                _ = processWithConfidence(zoneId: zoneId, zone: zone, isInside: isInside, currentState: currentState, currentTime: Date().timeIntervalSince1970, location: location, checkStartTime: zoneStartTime)
                let confidenceDuration = CFAbsoluteTimeGetCurrent() - confidenceStartTime
                totalConfidenceTime += confidenceDuration
            } else {
                // Original logic for immediate detection
                _ = processImmediate(zoneId: zoneId, zone: zone, isInside: isInside, currentState: currentState, location: location, checkStartTime: zoneStartTime)
            }

        }

        _ = CFAbsoluteTimeGetCurrent() - overallStartTime
    }

    // MARK: - Private Methods

    /**
     * Smart validation: Single point for obvious cases, 2-point for edge cases (ported from Android)
     */
    private func shouldUseConfirmation(speed: Double, zoneRadius: Double?) -> Bool {
        // Large zones always need confirmation (reduce false positives)
        if let radius = zoneRadius, radius > 200 {
            return true
        }

        // High speed + reasonable zones = single point OK
        if speed > 40 && (zoneRadius == nil || zoneRadius! > 50) {
            return false
        }

        // Default: Use 2-point for reliability
        return true
    }

    /**
     * Process with confidence validation - returns true if state changed (ported from Android)
     */
    private func processWithConfidence(zoneId: String, zone: ZoneData, isInside: Bool, currentState: Bool, currentTime: TimeInterval, location: CLLocation, checkStartTime: CFAbsoluteTime) -> Bool {
        let (hasConfidence, lastDetection) = syncQueue.sync { () -> (Bool, TimeInterval) in
            let confidence = self.zoneConfidence[zoneId] ?? ZoneConfidence()
            // Persist confidence across calls
            self.zoneConfidence[zoneId] = confidence

            // Update confidence counters
            if isInside {
                confidence.insideCount += 1
                confidence.outsideCount = 0
            } else {
                confidence.outsideCount += 1
                confidence.insideCount = 0
            }

            confidence.lastDetection = currentTime

            // Check if we have enough confidence for state change
            let requiredCount = self.confirmationPoints
            let hasConfidence = isInside ? confidence.insideCount >= requiredCount : confidence.outsideCount >= requiredCount

            return (hasConfidence, confidence.lastDetection)
        }

        // State change with confidence
        if hasConfidence && currentState != isInside {
            syncQueue.sync {
                self.zoneStates[zoneId] = isInside
                self.zoneConfidence[zoneId]?.confirmedState = isInside
            }

            // Persist state change immediately (write-through)
            persistZoneState(zoneId: zoneId, isInside: isInside)

            // Calculate detection time: from start of zone check to now (in milliseconds)
            let detectionTimeMs = (CFAbsoluteTimeGetCurrent() - checkStartTime) * 1000.0

            let eventType = isInside ? "ENTER" : "EXIT"
            trackEventTelemetry(zoneId: zoneId, eventType: eventType)
            eventCallback?(zoneId, eventType, location, detectionTimeMs)

            // Handle dwell tracking on state change
            handleDwellStateChange(zoneId: zoneId, isInside: isInside, location: location, checkStartTime: checkStartTime)

            // Reset confidence after successful event
            syncQueue.sync {
                self.zoneConfidence[zoneId]?.insideCount = 0
                self.zoneConfidence[zoneId]?.outsideCount = 0
            }

            return true // State changed
        }

        // Timeout: reset confidence if no consistent readings
        if currentTime - lastDetection > confirmationTimeoutMs {
            syncQueue.sync {
                self.zoneConfidence[zoneId]?.insideCount = 0
                self.zoneConfidence[zoneId]?.outsideCount = 0
            }
        }

        // Check for dwell even if no state change (still inside)
        if currentState && isInside && dwellEnabled {
            checkAndFireDwell(zoneId: zoneId, location: location, checkStartTime: checkStartTime)
        }

        return false // No state change
    }

    /**
     * Process immediate detection without confidence validation
     */
    private func processImmediate(zoneId: String, zone: ZoneData, isInside: Bool, currentState: Bool, location: CLLocation, checkStartTime: CFAbsoluteTime) -> Bool {
        // Check what happens when we detect a state change
        if isInside != currentState {
            handleStateChange(zoneId: zoneId, zoneName: zone.zoneName, isInside: isInside, location: location)

            syncQueue.sync { self.zoneStates[zoneId] = isInside }

            // Persist state change immediately (write-through)
            persistZoneState(zoneId: zoneId, isInside: isInside)

            // Calculate detection time: from start of zone check to now (in milliseconds)
            let detectionTimeMs = (CFAbsoluteTimeGetCurrent() - checkStartTime) * 1000.0

            let eventType = isInside ? "ENTER" : "EXIT"
            trackEventTelemetry(zoneId: zoneId, eventType: eventType)
            eventCallback?(zoneId, eventType, location, detectionTimeMs)

            // Handle dwell tracking on state change
            handleDwellStateChange(zoneId: zoneId, isInside: isInside, location: location, checkStartTime: checkStartTime)

            return true
        } else if isInside && dwellEnabled {
            // Still inside - check for dwell
            checkAndFireDwell(zoneId: zoneId, location: location, checkStartTime: checkStartTime)
        }

        return false
    }

    /**
     * Handle dwell tracking when zone state changes
     */
    private func handleDwellStateChange(zoneId: String, isInside: Bool, location: CLLocation, checkStartTime: CFAbsoluteTime) {
        guard dwellEnabled else { return }

        syncQueue.sync {
            if isInside {
                // Entered zone - start tracking dwell time
                self.zoneEntryTimes[zoneId] = Date().timeIntervalSince1970
                self.dwellEventsFired.removeValue(forKey: zoneId) // Reset dwell flag for new entry
                NSLog("[\(GeofenceEngine.TAG)] Dwell tracking started for zone \(zoneId)")
            } else {
                // ML Telemetry: capture dwell duration before removing entry time
                if let entryTime = self.zoneEntryTimes[zoneId] {
                    let dwellMinutes = (Date().timeIntervalSince1970 - entryTime) / 60.0
                    self.dwellDurationsMinutes.append(dwellMinutes)
                }
                // Exited zone - stop tracking dwell time
                self.zoneEntryTimes.removeValue(forKey: zoneId)
                self.dwellEventsFired.removeValue(forKey: zoneId)
                NSLog("[\(GeofenceEngine.TAG)] Dwell tracking stopped for zone \(zoneId)")
            }
        }
    }

    /**
     * Check if dwell threshold reached and fire DWELL event
     */
    private func checkAndFireDwell(zoneId: String, location: CLLocation, checkStartTime: CFAbsoluteTime) {
        // Check if dwell already fired for this zone entry
        let alreadyFired = syncQueue.sync { self.dwellEventsFired[zoneId] == true }
        guard !alreadyFired else { return }

        guard let entryTime = syncQueue.sync(execute: { self.zoneEntryTimes[zoneId] }) else { return }

        let dwellDuration = Date().timeIntervalSince1970 - entryTime

        if dwellDuration >= dwellThresholdSeconds {
            // Mark as fired to prevent duplicate events
            syncQueue.sync { self.dwellEventsFired[zoneId] = true }

            let detectionTimeMs = (CFAbsoluteTimeGetCurrent() - checkStartTime) * 1000.0

            NSLog("[\(GeofenceEngine.TAG)] DWELL event for zone \(zoneId) after \(dwellDuration)s")
            eventCallback?(zoneId, GeofenceEngine.EVENT_DWELL, location, detectionTimeMs)
        }
    }

    /**
     * Handle state change safely
     */
    private func handleStateChange(zoneId: String, zoneName: String, isInside: Bool, location: CLLocation) {
        // Update state safely
        syncQueue.sync {
            self.zoneStates[zoneId] = isInside
        }

        // Geofence events are dispatched on the main thread in processImmediate/processWithConfidence.
    }

    // MARK: - ML Telemetry

    /**
     * Track zone transitions and detect false events (reversals within 30s).
     */
    private func trackEventTelemetry(zoneId: String, eventType: String) {
        syncQueue.sync {
            self.zoneTransitionCount += 1
            let now = Date().timeIntervalSince1970
            var quickReversal = false

            if let lastEvent = self.lastEventPerZone[zoneId] {
                let timeSince = now - lastEvent.timestamp
                if timeSince <= 30.0 && lastEvent.eventType != eventType {
                    self.falseEventCount += 1
                    quickReversal = true
                }
            }
            self.lastEventPerZone[zoneId] = (eventType: eventType, timestamp: now)
            self.lastEventWasQuickReversal[zoneId] = quickReversal
        }
    }

    /**
     * Whether the most recently emitted event for this zone was a quick opposite transition
     * (e.g. EXIT within 30s of ENTER). Call after the event has been processed.
     */
    func isRecentReversal(zoneId: String, eventType: String) -> Bool {
        return syncQueue.sync {
            guard let lastEvent = self.lastEventPerZone[zoneId] else { return false }
            guard lastEvent.eventType == eventType else { return false }
            return self.lastEventWasQuickReversal[zoneId] == true
        }
    }

    /**
     * Calculate distance from point to zone boundary in meters.
     */
    func calculateDistanceToBoundary(zone: ZoneData, location: CLLocation) -> Double {
        let point = location.coordinate
        switch zone.type {
        case .circle:
            guard let center = zone.center, let radius = zone.radius else { return Double.greatestFiniteMagnitude }
            let distance = GeoMath.haversineDistance(point1: point, point2: center)
            return abs(distance - radius)
        case .polygon:
            guard let vertices = zone.polygon, vertices.count >= 2 else { return Double.greatestFiniteMagnitude }
            var minDist = Double.greatestFiniteMagnitude
            for i in 0..<vertices.count {
                let j = (i + 1) % vertices.count
                let segDist = GeoMath.pointToSegmentDistance(p: point, a: vertices[i], b: vertices[j])
                if segDist < minDist { minDist = segDist }
            }
            return minDist
        }
    }


    /**
     * Public accessor for boundary distance, used by LocationTracker for event enrichment.
     */
    func getDistanceToBoundary(zoneId: String, location: CLLocation) -> Double {
        return syncQueue.sync {
            guard let zone = self.zones[zoneId] else { return -1.0 }
            return self.calculateDistanceToBoundary(zone: zone, location: location)
        }
    }

    /**
     * Returns zone size distribution bucketed as small (<200m), medium (<1000m), large (>=1000m).
     */
    func getZoneSizeDistribution() -> [String: Int] {
        return syncQueue.sync {
            var dist = ["small": 0, "medium": 0, "large": 0]
            for zone in self.zones.values {
                let effectiveRadius: Double
                switch zone.type {
                case .circle:
                    effectiveRadius = zone.radius ?? 0
                case .polygon:
                    let center = zone.calculateCenter()
                    effectiveRadius = zone.polygon?.map { GeoMath.haversineDistance(point1: $0, point2: center) }.max() ?? 0
                }
                switch effectiveRadius {
                case ..<200: dist["small"]! += 1
                case ..<1000: dist["medium"]! += 1
                default: dist["large"]! += 1
                }
            }
            return dist
        }
    }

    func getZoneTransitionCount() -> Int {
        return syncQueue.sync { self.zoneTransitionCount }
    }

    func getFalseEventCount() -> Int {
        return syncQueue.sync { self.falseEventCount }
    }

    func getDwellDurations() -> [Double] {
        return syncQueue.sync { self.dwellDurationsMinutes }
    }

    /**
     * Compute dwell duration in minutes for a zone (if it has an entry time).
     */
    func getDwellDurationMinutes(zoneId: String) -> Double? {
        return syncQueue.sync {
            guard let entryTime = self.zoneEntryTimes[zoneId] else { return nil }
            return (Date().timeIntervalSince1970 - entryTime) / 60.0
        }
    }

    /**
     * Reset all telemetry counters for a new session.
     */
    func resetTelemetry() {
        syncQueue.sync {
            self.lastEventPerZone.removeAll()
            self.lastEventWasQuickReversal.removeAll()
            self.falseEventCount = 0
            self.dwellDurationsMinutes.removeAll()
            self.zoneTransitionCount = 0
        }
    }

    /**
     * Validate location quality
     * Uses configurable GPS accuracy threshold (default: 100m)
     * This ensures platform parity with Android
     */
    private func isValidLocation(_ location: CLLocation) -> Bool {
        return location.horizontalAccuracy > 0 && location.horizontalAccuracy < gpsAccuracyThreshold
    }

    /**
     * Calculate confidence based on location accuracy
     */
    private func calculateConfidence(_ accuracy: CLLocationAccuracy) -> Double {
        return max(0.0, min(1.0, 1.0 - (accuracy / 100.0)))
    }

    /**
     * Get current memory usage in MB
     */
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0
        } else {
            return 0.0
        }
    }

    // MARK: - Zone Access for Proximity Calculation

    /**
     * Get current zones for proximity calculation
     */
    func getCurrentZones() -> [Zone] {
        return syncQueue.sync {
            return zones.values.map { zoneData in
                Zone(
                    id: zoneData.zoneId,
                    name: zoneData.zoneName,
                    type: zoneData.type,
                    center: zoneData.center,
                    radius: zoneData.radius,
                    points: zoneData.polygon ?? []
                )
            }
        }
    }

    /**
     * Thread-safe zone count
     */
    func getZoneCount() -> Int {
        return syncQueue.sync { return zones.count }
    }

    /**
     * Check if any zones are configured
     */
    func hasZones() -> Bool {
        return syncQueue.sync { return !zones.isEmpty }
    }

}

// MARK: - Zone Data Models


class ZoneData {
    let zoneId: String
    let zoneName: String
    let type: ZoneType
    let center: CLLocationCoordinate2D?
    let radius: Double?
    let polygon: [CLLocationCoordinate2D]?

    init(zoneId: String, zoneName: String, type: ZoneType, center: CLLocationCoordinate2D? = nil, radius: Double? = nil, polygon: [CLLocationCoordinate2D]? = nil) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.type = type
        self.center = center
        self.radius = radius
        self.polygon = polygon
    }

    /**
     * Check if location is inside this zone
     */
    func contains(_ location: CLLocation) -> Bool {
        switch type {
        case .circle:
            guard let center = center, let radius = radius else { return false }
            let distance = GeoMath.haversineDistance(point1: center, point2: location.coordinate)
            return distance <= radius

        case .polygon:
            guard let polygon = polygon else { return false }
            return GeoMath.isPointInPolygon(point: location.coordinate, polygon: polygon)
        }
    }

    /**
     * Calculate the center point of this zone for clustering calculations
     * For circles: returns center
     * For polygons: returns centroid (average of all points)
     */
    func calculateCenter() -> CLLocationCoordinate2D {
        switch type {
        case .circle:
            guard let center = center else { return CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0) }
            return CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        case .polygon:
            guard let points = polygon, !points.isEmpty else { return CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0) }
            let avgLat = points.map { $0.latitude }.reduce(0, +) / Double(points.count)
            let avgLng = points.map { $0.longitude }.reduce(0, +) / Double(points.count)
            return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng)
        }
    }


    /**
     * Create ZoneData from map (ported from Android)
     */
    static func fromMap(zoneId: String, zoneName: String, zoneData: [String: Any]) throws -> ZoneData {
        guard let typeString = zoneData["type"] as? String else {
            throw NSError(domain: "GeofenceEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing zone type"])
        }

        let type: ZoneType
        let center: CLLocationCoordinate2D?
        let radius: Double?
        let polygon: [CLLocationCoordinate2D]?

        if typeString == "circle" {
            type = .circle
            // Accept multiple center formats; numbers or strings
            let centerData = zoneData["center"] as? [String: Any]
            func parseDouble(_ any: Any?) -> Double? {
                if let n = any as? NSNumber { return n.doubleValue }
                if let s = any as? String { return Double(s) }
                return nil
            }
            let lat: Double? = parseDouble(centerData?["latitude"]) ?? parseDouble(centerData?["lat"]) ?? parseDouble(zoneData["latitude"]) ?? parseDouble(zoneData["lat"])
            let lng: Double? = parseDouble(centerData?["longitude"]) ?? parseDouble(centerData?["lng"]) ?? parseDouble(zoneData["longitude"]) ?? parseDouble(zoneData["lng"])
            let rad: Double? = parseDouble(zoneData["radius"])
            guard let latUnwrapped = lat, let lngUnwrapped = lng, let radiusUnwrapped = rad else {
                throw NSError(domain: "GeofenceEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid circle zone data"])
            }
            center = CLLocationCoordinate2D(latitude: latUnwrapped, longitude: lngUnwrapped)
            radius = radiusUnwrapped
            polygon = nil

        } else if typeString == "polygon" {
            type = .polygon
            // Accept either "points" (iOS expectation) OR "polygon" (Android model)
            let pointsArray = (zoneData["points"] as? [[String: Any]]) ?? (zoneData["polygon"] as? [[String: Any]])
            var parsedPoints: [CLLocationCoordinate2D] = []
            if let pointsData = pointsArray {
                func parseDouble(_ any: Any?) -> Double? {
                    if let n = any as? NSNumber { return n.doubleValue }
                    if let s = any as? String { return Double(s) }
                    return nil
                }
                parsedPoints = pointsData.compactMap { pointData -> CLLocationCoordinate2D? in
                    let lat = parseDouble(pointData["latitude"]) ?? parseDouble(pointData["lat"])
                    let lng = parseDouble(pointData["longitude"]) ?? parseDouble(pointData["lng"])
                    guard let lat = lat, let lng = lng else { return nil }
                    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
                }
            } else if let coordsAny = zoneData["coordinates"] {
                // Accept GeoJSON-like coordinates: either [[lng,lat], ...] or [[[lng,lat], ...]] (first ring)
                if let coordinateArray = coordsAny as? [[Double]], let first = coordinateArray.first, first.count == 2 {
                    parsedPoints = coordinateArray.compactMap { pair -> CLLocationCoordinate2D? in
                        guard pair.count == 2 else { return nil }
                        let lng = pair[0]
                        let lat = pair[1]
                        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    }
                } else if let ringsArray = coordsAny as? [[[Double]]], let firstRing = ringsArray.first {
                    parsedPoints = firstRing.compactMap { pair -> CLLocationCoordinate2D? in
                        guard pair.count == 2 else { return nil }
                        let lng = pair[0]
                        let lat = pair[1]
                        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    }
                }
            }
            let points = parsedPoints

            guard points.count >= 3 else {
                throw NSError(domain: "GeofenceEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Polygon must have at least 3 points"])
            }

            // Check for self-intersecting polygon
            if isPolygonSelfIntersecting(points: points) {
                throw NSError(domain: "GeofenceEngine", code: 6, userInfo: [NSLocalizedDescriptionKey: "Polygon is self-intersecting and cannot be used for geofencing"])
            }

            // Warn about poles (reduced accuracy near ±85°)
            checkPoleWarning(points: points)

            center = nil
            radius = nil
            polygon = points

        } else {
            throw NSError(domain: "GeofenceEngine", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown zone type: \(typeString)"])
        }

        return ZoneData(zoneId: zoneId, zoneName: zoneName, type: type, center: center, radius: radius, polygon: polygon)
    }

    /**
     * Parse GeoJSON-style coordinates into CLLocationCoordinate2D array
     * Supports [[lng,lat], ...] or [[[lng,lat], ...]] (first ring)
     */
    private static func parseGeoJsonCoordinates(_ any: Any) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        // Case 1: [[lng,lat], ...]
        if let arr = any as? [[NSNumber]], let first = arr.first, first.count == 2 {
            for pair in arr {
                let lng = pair[0].doubleValue
                let lat = pair[1].doubleValue
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            return coords
        }
        // Case 2: [[[lng,lat], ...]] (rings) -> take first ring
        if let rings = any as? [[[NSNumber]]], let ring = rings.first {
            for pair in ring where pair.count == 2 {
                let lng = pair[0].doubleValue
                let lat = pair[1].doubleValue
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            return coords
        }
        // Case 3: [[Double]]
        if let arrD = any as? [[Double]], let first = arrD.first, first.count == 2 {
            for pair in arrD {
                let lng = pair[0]
                let lat = pair[1]
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            return coords
        }
        // Case 4: [[[Double]]]
        if let ringsD = any as? [[[Double]]], let ring = ringsD.first {
            for pair in ring where pair.count == 2 {
                let lng = pair[0]
                let lat = pair[1]
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            return coords
        }
        return coords
    }

    /**
     * Check if polygon is self-intersecting using O(n²) edge intersection test
     * Uses CCW (counter-clockwise) orientation test for robust intersection detection
     * Skips adjacent edges (they share a vertex) and first-last edge pair (closed polygon)
     */
    private static func isPolygonSelfIntersecting(points: [CLLocationCoordinate2D]) -> Bool {
        guard points.count >= 4 else { return false } // Minimum 4 points needed to self-intersect

        for i in 0..<(points.count - 1) {
            for j in (i + 2)..<points.count {
                // Skip last edge pair (first and last vertices share a connection in closed polygon)
                if i == 0 && j == points.count - 1 { continue }

                if segmentsIntersect(
                    a1: points[i], a2: points[i + 1],
                    b1: points[j], b2: points[(j + 1) % points.count]
                ) {
                    return true
                }
            }
        }
        return false
    }

    /**
     * Check if two line segments intersect using CCW orientation test
     * @param a1 First point of segment A
     * @param a2 Second point of segment A
     * @param b1 First point of segment B
     * @param b2 Second point of segment B
     * @return true if segments intersect
     */
    private static func segmentsIntersect(a1: CLLocationCoordinate2D, a2: CLLocationCoordinate2D, b1: CLLocationCoordinate2D, b2: CLLocationCoordinate2D) -> Bool {
        let d1 = cross(ux: b2.longitude - b1.longitude, uy: b2.latitude - b1.latitude,
                       vx: a1.longitude - b1.longitude, vy: a1.latitude - b1.latitude)
        let d2 = cross(ux: b2.longitude - b1.longitude, uy: b2.latitude - b1.latitude,
                       vx: a2.longitude - b1.longitude, vy: a2.latitude - b1.latitude)
        let d3 = cross(ux: a2.longitude - a1.longitude, uy: a2.latitude - a1.latitude,
                       vx: b1.longitude - a1.longitude, vy: b1.latitude - a1.latitude)
        let d4 = cross(ux: a2.longitude - a1.longitude, uy: a2.latitude - a1.latitude,
                       vx: b2.longitude - a1.longitude, vy: b2.latitude - a1.latitude)

        if sign(d1) != sign(d2) && sign(d3) != sign(d4) {
            return true
        }
        return false
    }

    /**
     * Cross product: u.x * v.y - u.y * v.x
     * Using lng as x, lat as y for geographic coordinates
     */
    private static func cross(ux: Double, uy: Double, vx: Double, vy: Double) -> Double {
        return ux * vy - uy * vx
    }

    /**
     * Get sign of a number (-1, 0, or 1)
     */
    private static func sign(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    /**
     * Check for poles (latitude > ±85°) and log warning about reduced accuracy
     */
    private static func checkPoleWarning(points: [CLLocationCoordinate2D]) {
        let polesNear = points.contains { abs($0.latitude) > 85.0 }
        if polesNear {
            NSLog("[\(GeofenceEngine.TAG)] Polygon zone contains vertices near poles (lat > ±85°) - accuracy will be reduced near poles due to geomagnetic field distortions")
        }
    }

}

// MARK: - Helper Structures

/**
 * Simple lat/lng container for distance calculations
 * Used by clustering logic
 */
struct LatLng {
    let latitude: Double
    let longitude: Double
}

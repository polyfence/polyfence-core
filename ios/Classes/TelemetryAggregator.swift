import Foundation
import UIKit

/// Aggregates all session telemetry in the native layer (D016).
/// Each platform bridge (Flutter, RN, future) only calls getSessionTelemetry()
/// and POSTs the result — no per-bridge telemetry reimplementation needed.
///
/// Thread-safe: all mutable state accessed via syncQueue.
class TelemetryAggregator {

    private let syncQueue = DispatchQueue(label: "io.polyfence.telemetryAggregator", attributes: .concurrent)

    // --- Activity distribution ---
    private var activityTimeMs: [String: Int64] = [:]
    private var lastActivityChangeTime: Int64
    private var lastTrackedActivity: String = "unknown"

    // --- GPS interval distribution ---
    private var intervalTimeMs: [Int64: Int64] = [:]
    private var lastIntervalChangeTime: Int64
    private var lastTrackedInterval: Int64 = 10_000
    private var totalIntervalMs: Int64 = 0
    private var intervalSampleCount: Int = 0

    // --- Stationary tracking ---
    private var cumulativeStationaryMs: Int64 = 0
    private var stationaryStartTime: Int64?

    // --- GPS accuracy at events ---
    private var eventAccuracies: [Double] = []
    private var eventSpeeds: [Double] = []
    private var boundaryEventsCount: Int = 0
    private let boundaryThresholdM: Double = 50.0

    // --- False event tracking ---
    private var lastEventPerZone: [String: (String, Int64)] = [:]
    private var falseEventCount: Int = 0

    // --- Detection timing ---
    private var detectionTimesMs: [Double] = []
    private var firstDetectionTimeMs: Int64?
    private var sessionStartTime: Int64

    // --- Zone metrics ---
    private var zoneTransitionCount: Int = 0
    private var dwellDurations: [Double] = []

    // --- GPS health ---
    private var totalGpsReadings: Int = 0
    private var goodGpsReadings: Int = 0

    // --- Error tracking ---
    private var errorCounts: [String: Int] = [:]

    // --- Device & config info ---
    private var deviceCategory: String?
    private var osVersionMajor: Int
    private var batteryLevelStart: Double?
    private var batteryLevelEnd: Double?
    private var chargingDuringSession: Bool = false
    private var accuracyProfile: String?
    private var updateStrategy: String?

    init() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        lastActivityChangeTime = now
        lastIntervalChangeTime = now
        sessionStartTime = now
        osVersionMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private func currentTimeMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    // ========================================================================
    // RECORDING METHODS — called by engines during session
    // ========================================================================

    /// Record an activity change. Accumulates time spent in each activity type.
    func recordActivityChange(activityType: String) {
        syncQueue.async(flags: .barrier) {
            let now = self.currentTimeMs()
            let elapsed = now - self.lastActivityChangeTime
            if elapsed > 0 {
                self.activityTimeMs[self.lastTrackedActivity, default: 0] += elapsed
            }
            self.lastActivityChangeTime = now
            self.lastTrackedActivity = activityType.lowercased()
        }
    }

    /// Finalize the last activity segment. Must be called before reading distribution.
    func finalizeActivityTracking() {
        recordActivityChange(activityType: lastTrackedActivity)
    }

    /// Record a GPS update with the current interval and accuracy.
    func recordGpsUpdate(intervalMs: Int64, accuracyM: Float) {
        syncQueue.async(flags: .barrier) {
            let now = self.currentTimeMs()
            let elapsed = now - self.lastIntervalChangeTime
            if elapsed > 0 {
                self.intervalTimeMs[self.lastTrackedInterval, default: 0] += elapsed
            }
            self.lastIntervalChangeTime = now
            self.lastTrackedInterval = intervalMs
            self.totalIntervalMs += intervalMs
            self.intervalSampleCount += 1

            self.totalGpsReadings += 1
            if accuracyM <= 100.0 {
                self.goodGpsReadings += 1
            }
        }
    }

    /// Record a geofence event with context.
    func recordGeofenceEvent(
        zoneId: String,
        eventType: String,
        distanceM: Double,
        speedMps: Double,
        accuracyM: Double,
        detectionTimeMs: Double
    ) {
        syncQueue.async(flags: .barrier) {
            self.zoneTransitionCount += 1
            self.detectionTimesMs.append(detectionTimeMs)

            if self.firstDetectionTimeMs == nil {
                self.firstDetectionTimeMs = self.currentTimeMs() - self.sessionStartTime
            }

            self.eventAccuracies.append(accuracyM)
            self.eventSpeeds.append(speedMps)

            if distanceM >= 0 && distanceM < self.boundaryThresholdM {
                self.boundaryEventsCount += 1
            }

            // False event detection (reversal within 30s on same zone)
            if let lastEvent = self.lastEventPerZone[zoneId] {
                let (lastType, lastTime) = lastEvent
                let timeSince = self.currentTimeMs() - lastTime
                if timeSince <= 30_000 && lastType != eventType {
                    self.falseEventCount += 1
                }
            }
            self.lastEventPerZone[zoneId] = (eventType, self.currentTimeMs())
        }
    }

    /// Record dwell completion (on EXIT).
    func recordDwellComplete(durationMinutes: Double) {
        syncQueue.async(flags: .barrier) {
            self.dwellDurations.append(durationMinutes)
        }
    }

    /// Record stationary state change.
    func recordStationaryChange(isStationary: Bool) {
        syncQueue.async(flags: .barrier) {
            if isStationary && self.stationaryStartTime == nil {
                self.stationaryStartTime = self.currentTimeMs()
            } else if !isStationary, let start = self.stationaryStartTime {
                self.cumulativeStationaryMs += self.currentTimeMs() - start
                self.stationaryStartTime = nil
            }
        }
    }

    /// Record an error occurrence.
    func recordError(errorType: String) {
        syncQueue.async(flags: .barrier) {
            self.errorCounts[errorType, default: 0] += 1
        }
    }

    /// Set device info (call once at session start).
    func setDeviceInfo(category: String, osVersion: Int) {
        syncQueue.async(flags: .barrier) {
            self.deviceCategory = category
            self.osVersionMajor = osVersion
        }
    }

    /// Set battery info.
    func setBatteryInfo(startPercent: Double?, endPercent: Double?, chargingDuring: Bool) {
        syncQueue.async(flags: .barrier) {
            if let s = startPercent { self.batteryLevelStart = s }
            if let e = endPercent { self.batteryLevelEnd = e }
            self.chargingDuringSession = chargingDuring
        }
    }

    /// Set configuration context.
    func setConfig(accuracyProfile: String, updateStrategy: String) {
        syncQueue.async(flags: .barrier) {
            self.accuracyProfile = accuracyProfile
            self.updateStrategy = updateStrategy
        }
    }

    // ========================================================================
    // OUTPUT — returns complete v2 enhanced payload
    // ========================================================================

    /// Returns the complete v2 enhanced session telemetry payload.
    /// Matches the schema defined in intelligence/DATA_STRATEGY.md.
    func getSessionTelemetry(
        geofenceEngine: GeofenceEngine? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        syncQueue.sync {
            // Finalize activity tracking
            let now = currentTimeMs()
            let actElapsed = now - lastActivityChangeTime
            var activitySnapshot = activityTimeMs
            if actElapsed > 0 {
                activitySnapshot[lastTrackedActivity, default: 0] += actElapsed
            }

            // Finalize stationary
            var totalStationary = cumulativeStationaryMs
            if let start = stationaryStartTime {
                totalStationary += now - start
            }

            let sessionDurationMs = now - sessionStartTime
            let sessionDurationMinutes = Double(sessionDurationMs) / 60_000.0

            // Activity distribution
            let totalActivityMs = activitySnapshot.values.reduce(0, +)
            var activityDist: [String: Double] = [:]
            if totalActivityMs > 0 {
                for (key, ms) in activitySnapshot {
                    activityDist[key] = Double(ms) / Double(totalActivityMs)
                }
            }

            // GPS interval distribution
            var intervalSnapshot = intervalTimeMs
            let intElapsed = now - lastIntervalChangeTime
            if intElapsed > 0 {
                intervalSnapshot[lastTrackedInterval, default: 0] += intElapsed
            }
            let totalIntMs = intervalSnapshot.values.reduce(0, +)
            var intervalDist: [String: Double] = [:]
            if totalIntMs > 0 {
                for (key, ms) in intervalSnapshot {
                    intervalDist[String(key)] = Double(ms) / Double(totalIntMs)
                }
            }

            // Detection stats
            let detTimes = detectionTimesMs
            let detAvg = detTimes.isEmpty ? 0.0 : detTimes.reduce(0, +) / Double(detTimes.count)
            let detP95: Double
            if detTimes.isEmpty {
                detP95 = 0.0
            } else {
                let sorted = detTimes.sorted()
                let idx = min(Int(Double(sorted.count) * 0.95), sorted.count - 1)
                detP95 = sorted[idx]
            }

            // Event averages
            let avgAccuracy = eventAccuracies.isEmpty ? 0.0 : eventAccuracies.reduce(0, +) / Double(eventAccuracies.count)
            let avgSpeed = eventSpeeds.isEmpty ? 0.0 : eventSpeeds.reduce(0, +) / Double(eventSpeeds.count)

            // False event ratio
            let totalDetections = detTimes.count
            let falseRatio = totalDetections > 0 ? Double(falseEventCount) / Double(totalDetections) : 0.0

            // Dwell average
            let avgDwell = dwellDurations.isEmpty ? 0.0 : dwellDurations.reduce(0, +) / Double(dwellDurations.count)

            // Stationary ratio
            let statRatio = sessionDurationMs > 0 ? Double(totalStationary) / Double(sessionDurationMs) : 0.0

            // Average GPS interval
            let avgInterval = intervalSampleCount > 0 ? Int(totalIntervalMs / Int64(intervalSampleCount)) : 0

            // GPS OK ratio
            let gpsOk = totalGpsReadings > 0 ? Double(goodGpsReadings) / Double(totalGpsReadings) : 0.0

            var telemetry = SessionTelemetry()
            telemetry.detectionsTotal = totalDetections
            telemetry.detectionTimeAvgMs = detAvg
            telemetry.detectionTimeP95Ms = detP95
            telemetry.gpsAccuracyAvgM = avgAccuracy
            telemetry.sessionDurationMinutes = sessionDurationMinutes
            telemetry.errorCounts = errorCounts
            telemetry.ttfdMs = firstDetectionTimeMs ?? 0
            telemetry.hadDetection = totalDetections > 0
            telemetry.gpsOkRatio = gpsOk
            telemetry.sampleEvents = totalGpsReadings
            telemetry.batteryLevelStart = batteryLevelStart
            telemetry.batteryLevelEnd = batteryLevelEnd
            telemetry.accuracyProfile = accuracyProfile
            telemetry.updateStrategy = updateStrategy
            telemetry.activityDistribution = activityDist
            telemetry.gpsIntervalDistribution = intervalDist
            telemetry.stationaryRatio = statRatio
            telemetry.avgGpsIntervalMs = avgInterval
            telemetry.falseEventCount = falseEventCount
            telemetry.falseEventRatio = falseRatio
            telemetry.avgGpsAccuracyAtEvent = avgAccuracy
            telemetry.avgSpeedAtEventMps = avgSpeed
            telemetry.boundaryEventsCount = boundaryEventsCount
            telemetry.zoneTransitionCount = zoneTransitionCount
            telemetry.avgDwellMinutes = avgDwell
            telemetry.deviceCategory = deviceCategory
            telemetry.osVersionMajor = osVersionMajor
            telemetry.chargingDuringSession = chargingDuringSession

            result = telemetry.toMap()
        }

        // Zone metrics from engine (outside sync to avoid deadlock)
        if let engine = geofenceEngine {
            result["zone_count"] = engine.getZoneCount()
            result["zone_size_distribution"] = engine.getZoneSizeDistribution()
        }

        return result
    }

    /// Reset all telemetry for a new session.
    func resetTelemetry() {
        syncQueue.async(flags: .barrier) {
            let now = self.currentTimeMs()

            self.activityTimeMs.removeAll()
            self.lastActivityChangeTime = now
            self.lastTrackedActivity = "unknown"

            self.intervalTimeMs.removeAll()
            self.lastIntervalChangeTime = now
            self.lastTrackedInterval = 10_000
            self.totalIntervalMs = 0
            self.intervalSampleCount = 0

            self.cumulativeStationaryMs = 0
            self.stationaryStartTime = nil

            self.eventAccuracies.removeAll()
            self.eventSpeeds.removeAll()
            self.boundaryEventsCount = 0

            self.lastEventPerZone.removeAll()
            self.falseEventCount = 0

            self.detectionTimesMs.removeAll()
            self.firstDetectionTimeMs = nil
            self.sessionStartTime = now

            self.zoneTransitionCount = 0
            self.dwellDurations.removeAll()

            self.totalGpsReadings = 0
            self.goodGpsReadings = 0

            self.errorCounts.removeAll()

            self.batteryLevelStart = nil
            self.batteryLevelEnd = nil
            self.chargingDuringSession = false
        }
    }

    // ========================================================================
    // DEVICE CATEGORY HELPERS
    // ========================================================================

    /// Determine device category. Returns a bucketed category — NOT the exact model.
    static func getDeviceCategory() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }

        if machine.hasPrefix("iPhone") {
            let stripped = machine.replacingOccurrences(of: "iPhone", with: "")
            let parts = stripped.split(separator: ",")
            if let major = Int(parts.first ?? "") {
                if major >= 15 { return "iphone_flagship" }
                if major >= 12 { return "iphone_standard" }
                return "iphone_older"
            }
        }
        if machine.hasPrefix("iPad") { return "ipad" }
        return "ios_other"
    }
}

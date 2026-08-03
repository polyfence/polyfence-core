import Foundation
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/**
 * Collects debug information for the Polyfence plugin
 * Provides system status, performance metrics, and error history
 */
public class PolyfenceDebugCollector {
    public static let shared = PolyfenceDebugCollector()

    private let syncQueue = DispatchQueue(label: "io.polyfence.PolyfenceDebugCollector")
    private var performanceMetrics: [String: Any] = [:]
    private var errorHistory: [[String: Any]] = []
    private var sessionStartTime = Date()
    public var pluginVersion: String? = nil
    weak var geofenceEngine: GeofenceEngine?

    private init() {}

    /**
     * Set plugin version from bridge (called during initialization)
     */
    public func setPluginVersion(_ version: String) {
        pluginVersion = version
    }

    public func collectDebugInfo() -> [String: Any] {
        return [
            "systemStatus": collectSystemStatus(),
            "performance": collectPerformanceMetrics(),
            "battery": collectBatteryMetrics(),
            "zones": collectZoneStatus(),
            "recentErrors": getRecentErrors()
        ]
    }

    private func collectSystemStatus() -> [String: Any] {
        // Read outside syncQueue — the registrar has its own serial queue and
        // nesting a sync onto ours would be an ordering hazard for no benefit.
        let osGeofenceHealth = LocationTracker.currentInstanceForOsGeofence?
            .osGeofenceRegistrationHealth()
        return syncQueue.sync {
            var status: [String: Any] = [
                // Throwaway CLLocationManager instances used here for a one-shot
                // synchronous `authorizationStatus` read. No delegate is set,
                // no `startUpdating…` is called, and the instance goes out of
                // scope immediately — so the run-loop-on-creating-thread
                // requirement that affects LocationTracker's long-lived manager
                // (see LocationTracker.setupLocationManager() comment) does not
                // apply here. Fast-follow candidate: read `authorizationStatus`
                // from the long-lived LocationTracker manager instead of
                // allocating temps.
                "isLocationPermissionGranted": {
                    let mgr = CLLocationManager()
                    return mgr.authorizationStatus == .authorizedAlways || mgr.authorizationStatus == .authorizedWhenInUse
                }(),
                "isBackgroundLocationEnabled": CLLocationManager().authorizationStatus == .authorizedAlways,
                "isBatteryOptimizationDisabled": true, // iOS doesn't have battery optimization like Android
                "isGpsEnabled": CLLocationManager.locationServicesEnabled(),
                "isWakeLockAcquired": false, // iOS doesn't use wake locks
                "lastKnownAccuracy": self.performanceMetrics["lastAccuracy"] as? Double ?? -1.0,
                "lastLocationUpdate": (self.performanceMetrics["lastLocationUpdate"] as? Date ?? Date()).timeIntervalSince1970 * 1000,
                "platformVersion": UIDevice.current.systemVersion,
                "pluginVersion": self.pluginVersion ?? "unknown"
            ]
            // Always present so consumers can rely on a stable shape. Null
            // when osGeofenceWakeEnabled is off or no registration has been
            // attempted; a { requested, registered, lastError } map otherwise,
            // letting a consumer surface observe OS-cap hits (requested >
            // registered) or permission drift (lastError ==
            // "background_location_denied"). NSNull bridges to null on both
            // platform channels, matching the Kotlin side's nullable value.
            status["osGeofenceRegistrationHealth"] = osGeofenceHealth ?? NSNull()
            return status
        }
    }

    private func collectPerformanceMetrics() -> [String: Any] {
        return syncQueue.sync {
            let uptime = Date().timeIntervalSince(self.sessionStartTime) * 1000
            let detectionCount = self.performanceMetrics["zoneDetectionCount"] as? Int ?? 0
            let totalLatency = self.performanceMetrics["totalDetectionLatency"] as? Double ?? 0.0

            return [
                "uptime": Int(uptime),
                "totalLocationUpdates": self.performanceMetrics["locationUpdateCount"] as? Int ?? 0,
                "totalZoneDetections": detectionCount,
                "averageDetectionLatency": detectionCount > 0
                    ? totalLatency / Double(detectionCount)
                    : 0.0,
                "memoryUsageMB": self.getMemoryUsage(),
                "cpuUsagePercent": 0.0, // CPU usage is complex to get on iOS
                "restartCount": self.performanceMetrics["restartCount"] as? Int ?? 0
            ]
        }
    }

    private func collectBatteryMetrics() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true

        return [
            "estimatedHourlyDrain": 0.0,
            "gpsActiveTimePercent": 0,
            "wakeUpCount": 0,
            "isCharging": UIDevice.current.batteryState == .charging,
            "batteryLevel": Int(UIDevice.current.batteryLevel * 100),
            "totalActiveTime": Int(Date().timeIntervalSince(sessionStartTime) * 1000)
        ]
    }

    private func collectZoneStatus() -> [String: Any] {
        let zones = geofenceEngine?.getCurrentZones() ?? []
        let circleCount = zones.filter { $0.isCircle }.count
        let polygonCount = zones.filter { $0.isPolygon }.count

        return [
            "activeZones": zones.count,
            "circleZones": circleCount,
            "polygonZones": polygonCount,
            "lastZoneUpdate": Date().timeIntervalSince1970 * 1000,
            "zoneEventCounts": [String: Int]()
        ]
    }

    private func getRecentErrors() -> [[String: Any]] {
        return syncQueue.sync {
            return self.errorHistory
        }
    }

    public func getErrorHistory(timeRangeMs: Int64?, errorTypes: [String]?) -> [[String: Any]] {
        return syncQueue.sync {
            var filteredErrors = self.errorHistory

            if let timeRangeMs = timeRangeMs {
                let cutoffTime = Date().timeIntervalSince1970 * 1000 - Double(timeRangeMs)
                filteredErrors = filteredErrors.filter { error in
                    // Read the timestamp through NSNumber. Numerics
                    // stored in a heterogeneous [String: Any] map do
                    // not bridge reliably via a direct `as? Double`;
                    // NSNumber.doubleValue accepts either concrete
                    // type. Same idiom is used across the codebase.
                    let timestamp = (error["timestamp"] as? NSNumber)?.doubleValue ?? 0
                    return timestamp >= cutoffTime
                }
            }

            if let errorTypes = errorTypes, !errorTypes.isEmpty {
                filteredErrors = filteredErrors.filter { error in
                    let type = error["type"] as? String
                    return errorTypes.contains(type ?? "")
                }
            }

            return filteredErrors
        }
    }

    public func recordLocationUpdate(accuracy: Double) {
        syncQueue.async { [weak self] in
            self?.performanceMetrics["lastAccuracy"] = accuracy
            self?.performanceMetrics["lastLocationUpdate"] = Date()
            let count = (self?.performanceMetrics["locationUpdateCount"] as? Int) ?? 0
            self?.performanceMetrics["locationUpdateCount"] = count + 1
        }
    }

    /**
     * Record one geofence detection and the time the engine spent producing it.
     *
     * Latency is fractional milliseconds: a point-in-zone evaluation routinely
     * completes in well under a millisecond, so the sum is kept and the mean
     * derived at read time rather than rolled per sample.
     */
    public func recordZoneDetection(latencyMs: Double) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            let count = (self.performanceMetrics["zoneDetectionCount"] as? Int) ?? 0
            self.performanceMetrics["zoneDetectionCount"] = count + 1

            let total = (self.performanceMetrics["totalDetectionLatency"] as? Double) ?? 0.0
            self.performanceMetrics["totalDetectionLatency"] = total + latencyMs
        }
    }

    public func addErrorToHistory(_ error: [String: Any]) {
        syncQueue.async { [weak self] in
            self?.errorHistory.append(error)
            if (self?.errorHistory.count ?? 0) > 100 {
                self?.errorHistory.removeFirst()
            }
        }
    }

    private func getMemoryUsage() -> Int {
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
            return Int(info.resident_size / 1024 / 1024)
        }
        return 0
    }
}

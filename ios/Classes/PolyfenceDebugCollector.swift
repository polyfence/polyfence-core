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

    /**
     * Names of the payload entries that are read back by name elsewhere in
     * the library rather than only handed to a consumer.
     *
     * A reader that spells one of these differently gets nil and falls back
     * to a default — and for the scored metrics the default is the *best*
     * possible value, so a typo raises the health score instead of breaking
     * it. Sharing the constant makes the two sides impossible to drift apart.
     */
    public enum Key {
        public static let performance = "performance"
        public static let recentErrors = "recentErrors"
        public static let averageDetectionLatency = "averageDetectionLatency"
    }

    public func collectDebugInfo() -> [String: Any] {
        return [
            "systemStatus": collectSystemStatus(),
            Key.performance: collectPerformanceMetrics(),
            "battery": collectBatteryMetrics(),
            "zones": collectZoneStatus(),
            Key.recentErrors: getRecentErrors()
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
                // Null rather than a value: iOS has no battery-optimisation
                // exemption and no wake locks, so there is nothing to report.
                // A `false` here would be read as "the app is subject to
                // optimisation" / "no wake lock is held", both of which are
                // claims about a mechanism that does not exist on this
                // platform. Android returns real values for both.
                "isBatteryOptimizationDisabled": NSNull(),
                "isGpsEnabled": CLLocationManager.locationServicesEnabled(),
                "isWakeLockAcquired": NSNull(),
                "lastKnownAccuracy": self.performanceMetrics["lastAccuracy"] as? Double ?? -1.0,
                // Zero until a fix has arrived, matching Android. Falling back
                // to the current time would report a location update at the
                // moment of asking, for a session that has had none.
                "lastLocationUpdate": (self.performanceMetrics["lastLocationUpdate"] as? Date)
                    .map { $0.timeIntervalSince1970 * 1000 } ?? 0,
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
            let timedCount = self.performanceMetrics["timedDetectionCount"] as? Int ?? 0
            let totalLatency = self.performanceMetrics["totalDetectionLatency"] as? Double ?? 0.0

            return [
                "uptime": Int(uptime),
                "totalLocationUpdates": self.performanceMetrics["locationUpdateCount"] as? Int ?? 0,
                "totalZoneDetections": detectionCount,
                // How many of those were timed, and so how many samples the
                // mean below covers. Without it a consumer would assume the
                // mean spans every crossing, which it cannot when the engine
                // synthesises one outside a timed evaluation.
                "timedZoneDetections": timedCount,
                // Absent until a crossing has been *timed*: a synthesised
                // one raises totalZoneDetections without contributing a
                // sample. Zero is the best possible latency, so reporting it
                // for "no samples" makes an unmeasured device look perfect.
                Key.averageDetectionLatency: timedCount > 0
                    ? totalLatency / Double(timedCount)
                    : NSNull(),
                // Process resident size. Android's counterpart reports Java
                // heap only, so the two are not comparable across platforms.
                "memoryUsageMB": self.getMemoryUsage(),
                // Null rather than 0: restarts are a property of Android's
                // foreground service, and iOS has no equivalent to count.
                "restartCount": NSNull()
            ]
        }
    }

    private func collectBatteryMetrics() -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true

        // Negative means the OS has not populated the level yet, and always
        // means it in the Simulator, which has no battery. Reporting the raw
        // value would surface -100; coercing it to a plausible number would
        // report a charge the device never had.
        let rawLevel = UIDevice.current.batteryLevel

        return [
            "isCharging": UIDevice.current.batteryState == .charging,
            "batteryLevel": rawLevel >= 0 ? Int(rawLevel * 100) : NSNull(),
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
            "polygonZones": polygonCount
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
     * Record one zone crossing, and the time the engine spent producing it
     * where that was measured.
     *
     * A nil latency means the crossing was real but never timed — the engine
     * synthesises some outside a location evaluation. Those still count as
     * crossings, because the consumer received them; they are simply left out
     * of the mean rather than folded in as zero, which would drag it toward a
     * speed nothing achieved.
     *
     * Latency is fractional milliseconds: a point-in-zone evaluation routinely
     * completes in well under a millisecond, so the sum is kept and the mean
     * derived at read time rather than rolled per sample.
     */
    public func recordZoneDetection(latencyMs: Double?) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            let count = (self.performanceMetrics["zoneDetectionCount"] as? Int) ?? 0
            self.performanceMetrics["zoneDetectionCount"] = count + 1

            guard let latencyMs = latencyMs else { return }
            let timed = (self.performanceMetrics["timedDetectionCount"] as? Int) ?? 0
            self.performanceMetrics["timedDetectionCount"] = timed + 1

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

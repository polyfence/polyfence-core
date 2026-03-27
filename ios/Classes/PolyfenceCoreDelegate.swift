import Foundation
import CoreLocation

/// Protocol for platform bridges (Flutter, React Native, etc.) to receive
/// events from the core engine. Each bridge implements this protocol.
public protocol PolyfenceCoreDelegate: AnyObject {
    /// Called when a geofence event occurs (ENTER, EXIT, DWELL, RECOVERY_*)
    func onGeofenceEvent(_ eventData: [String: Any])

    /// Called on each GPS location update
    func onLocationUpdate(_ locationData: [String: Any])

    /// Called with runtime performance/health status
    func onPerformanceEvent(_ performanceData: [String: Any])

    /// Called when an error occurs
    func onError(_ errorData: [String: Any])
}

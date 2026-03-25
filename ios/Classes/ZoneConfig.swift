import Foundation
import CoreLocation

/**
 * Typed configuration for creating geofence zones.
 * Preferred over the raw Dictionary-based addZone API.
 */
public struct ZoneConfig {
    public let id: String
    public let name: String
    public let type: ZoneType
    public let center: CLLocationCoordinate2D?
    public let radius: Double?
    public let polygon: [CLLocationCoordinate2D]?
    public let metadata: [String: String]?

    /**
     * Create a circle zone configuration
     */
    public static func circle(
        id: String,
        name: String,
        center: CLLocationCoordinate2D,
        radius: Double,
        metadata: [String: String]? = nil
    ) -> ZoneConfig {
        return ZoneConfig(
            id: id,
            name: name,
            type: .circle,
            center: center,
            radius: radius,
            polygon: nil,
            metadata: metadata
        )
    }

    /**
     * Create a polygon zone configuration
     */
    public static func polygon(
        id: String,
        name: String,
        polygon: [CLLocationCoordinate2D],
        metadata: [String: String]? = nil
    ) -> ZoneConfig {
        return ZoneConfig(
            id: id,
            name: name,
            type: .polygon,
            center: nil,
            radius: nil,
            polygon: polygon,
            metadata: metadata
        )
    }

    /**
     * Convert to the Dictionary format used by the legacy addZone API
     */
    public func toMap() -> [String: Any] {
        var map: [String: Any] = [:]
        switch type {
        case .circle:
            map["type"] = "circle"
            if let center = center {
                map["center"] = ["latitude": center.latitude, "longitude": center.longitude]
            }
            if let radius = radius {
                map["radius"] = radius
            }
        case .polygon:
            map["type"] = "polygon"
            if let polygon = polygon {
                map["polygon"] = polygon.map { ["latitude": $0.latitude, "longitude": $0.longitude] }
            }
        }
        if let metadata = metadata {
            map["metadata"] = metadata
        }
        return map
    }
}

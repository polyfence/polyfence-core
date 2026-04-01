import Foundation
import CoreLocation

/**
 * Zone data model for proximity calculation
 */
public struct Zone {
    public let id: String
    public let name: String
    public let type: ZoneType
    public let center: CLLocationCoordinate2D?
    public let radius: Double?
    public let points: [CLLocationCoordinate2D]

    public var isCircle: Bool { return type == .circle }
    public var isPolygon: Bool { return type == .polygon }
}

public enum ZoneType: String {
    case circle
    case polygon
}

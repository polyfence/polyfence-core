# Polyfence Core

[![CI](https://github.com/blackabass/polyfence-core/actions/workflows/ci.yml/badge.svg)](https://github.com/blackabass/polyfence-core/actions/workflows/ci.yml)
[![Maven Central](https://img.shields.io/maven-central/v/io.polyfence/polyfence-core)](https://central.sonatype.com/artifact/io.polyfence/polyfence-core)
[![CocoaPods](https://img.shields.io/cocoapods/v/PolyfenceCore)](https://cocoapods.org/pods/PolyfenceCore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Standalone, privacy-first geofencing engine for iOS and Android. Runs entirely on-device with zero cloud dependencies.

Polyfence Core is the shared native engine that powers [polyfence-flutter](https://github.com/blackabass/polyfence-flutter) and future framework bridges (React Native, native iOS/Android SDKs). It contains all geofencing algorithms, GPS management, and telemetry aggregation logic.

## Features

- **Polygon geofencing** — Ray-casting point-in-polygon algorithm for arbitrary polygon zones
- **Circle geofencing** — Haversine great-circle distance for radius-based zones
- **SmartGPS** — Intelligent GPS scheduling based on proximity, movement, activity, and battery state
- **Activity recognition** — Adjusts GPS intervals based on user activity (still, walking, driving, etc.)
- **Dwell detection** — Fire events when a device remains in a zone for a configurable duration
- **Zone clustering** — Performance optimization for large zone sets (100+ zones)
- **Scheduled tracking** — Time-window and day-of-week tracking schedules
- **Telemetry aggregation** — Session-level performance metrics collected natively (no GPS coordinates or PII)
- **Zone persistence** — Zone state recovery across app restarts

## Requirements

| Platform | Minimum |
|----------|---------|
| Android  | API 24 (Android 7.0) |
| iOS      | 14.0 |
| Kotlin   | 2.0+ |
| Swift    | 5.0+ |

## Installation

### iOS (CocoaPods)

```ruby
pod 'PolyfenceCore', '~> 1.0.0'
```

### iOS (Swift Package Manager)

Add to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/blackabass/polyfence-core.git", from: "1.0.0")
```

Or in Xcode: File → Add Package Dependencies → paste the repository URL.

### Android (Maven)

```kotlin
implementation("io.polyfence:polyfence-core:1.0.0")
```

## Quick Start

### Android (Kotlin)

```kotlin
import io.polyfence.core.*
import android.content.Intent
import android.content.Context

// 1. Create a delegate to receive events
val delegate = object : PolyfenceCoreDelegate {
    override fun onGeofenceEvent(eventData: Map<String, Any>) {
        val zoneId = eventData["zoneId"] as String
        val eventType = eventData["eventType"] as String
        println("Event: $eventType for zone $zoneId")
    }

    override fun onLocationUpdate(locationData: Map<String, Any>) {}
    override fun onPerformanceEvent(performanceData: Map<String, Any>) {}
    override fun onError(errorData: Map<String, Any>) {}
}

// 2. Start the LocationTracker service
val context: Context = this // Your Activity or Service context
val intent = Intent(context, LocationTracker::class.java)
intent.action = LocationTracker.ACTION_START_TRACKING
context.startService(intent)

// 3. Add a zone to monitor
val zoneIntent = Intent(context, LocationTracker::class.java)
zoneIntent.action = LocationTracker.ACTION_ADD_ZONE
zoneIntent.putExtra("zoneId", "office")
zoneIntent.putExtra("zoneName", "HQ")
zoneIntent.putExtra("zoneData", mapOf(
    "type" to "circle",
    "latitude" to 51.5074,
    "longitude" to -0.1278,
    "radius" to 100.0
) as Serializable)
context.startService(zoneIntent)

// 4. Stop tracking when done
val stopIntent = Intent(context, LocationTracker::class.java)
stopIntent.action = LocationTracker.ACTION_STOP_TRACKING
context.startService(stopIntent)
```

### iOS (Swift)

```swift
import PolyfenceCore
import CoreLocation

// 1. Create a delegate to receive events
class MyGeoDelegate: NSObject, PolyfenceCoreDelegate {
    func onGeofenceEvent(_ eventData: [String: Any]) {
        let zoneId = eventData["zoneId"] as? String ?? ""
        let eventType = eventData["eventType"] as? String ?? ""
        print("Event: \(eventType) for zone \(zoneId)")
    }

    func onLocationUpdate(_ locationData: [String: Any]) {}
    func onPerformanceEvent(_ performanceData: [String: Any]) {}
    func onError(_ errorData: [String: Any]) {}
}

let delegate = MyGeoDelegate()

// 2. Initialize the engine
let engine = GeofenceEngine()
engine.setEventCallback { zoneId, eventType, location, detectionTimeMs in
    print("Zone: \(zoneId), Event: \(eventType)")
}

// 3. Add a zone to monitor
try engine.addZone(
    zoneId: "office",
    zoneName: "HQ",
    zoneData: [
        "type": "circle",
        "latitude": 51.5074,
        "longitude": -0.1278,
        "radius": 100.0
    ]
)

// 4. Start tracking with LocationTracker
let tracker = LocationTracker()
tracker.startTracking()
```

## Architecture

Polyfence Core is the engine layer consumed by platform-specific bridges:

```
polyfence-core (this repo)
  │
  ├── polyfence-flutter           Flutter plugin bridge (depends on polyfence-core)
  ├── polyfence-react-native      React Native bridge (planned, depends on polyfence-core)
  └── polyfence-intelligence      ML add-on (planned, depends on polyfence-core)
```

### Key Classes

| Class | Purpose |
|---|---|
| `GeofenceEngine` | Zone detection — ray-casting for polygons, haversine for circles. Manages zone state (inside/outside), fires ENTER/EXIT/DWELL events, tracks dwell time. |
| `LocationTracker` | GPS lifecycle management — SmartGPS strategies (continuous, proximity-based, movement-based, intelligent), distance filtering, accuracy thresholds, stationary detection. |
| `ActivityRecognitionManager` | Detects user activity (still, walking, running, cycling, driving) via Play Services (Android) / CoreMotion (iOS). Feeds activity data to LocationTracker for interval adjustment. |
| `TrackingScheduler` | Time-based tracking control — start/stop tracking based on configurable time windows and days of week. |
| `TelemetryAggregator` | Collects session-level performance metrics natively — activity distribution, GPS interval histogram, zone transitions, dwell durations, device category. No GPS coordinates or PII. |
| `ZonePersistence` | Persists zone definitions and inside/outside state to local storage. Enables state recovery after app restarts. |
| `SmartGpsConfig` | Configuration model — accuracy profiles (max, balanced, battery-optimal, adaptive), update strategies, proximity/movement/battery/dwell/cluster/schedule/activity settings. |
| `PolyfenceCoreDelegate` | Bridge interface — platform bridges (Flutter, RN) implement this to receive events from the engine. |
| `GeoMath` | Shared geometry algorithms — haversine distance, ray-casting point-in-polygon, point-to-segment distance. Used by GeofenceEngine and LocationTracker. |
| `PolyfenceErrorManager` | Structured error reporting with typed errors, context, and correlation IDs. |
| `PolyfenceDebugCollector` | Collects debug information (system status, performance metrics, battery stats, zone status, recent errors). |

### Bridge Interface

Platform bridges implement `PolyfenceCoreDelegate` to receive events:

```kotlin
// Kotlin (Android)
interface PolyfenceCoreDelegate {
    fun onGeofenceEvent(eventData: Map<String, Any>)
    fun onLocationUpdate(locationData: Map<String, Any>)
    fun onPerformanceEvent(performanceData: Map<String, Any>)
    fun onError(errorData: Map<String, Any>)
}
```

```swift
// Swift (iOS)
protocol PolyfenceCoreDelegate: AnyObject {
    func onGeofenceEvent(_ eventData: [String: Any])
    func onLocationUpdate(_ locationData: [String: Any])
    func onPerformanceEvent(_ performanceData: [String: Any])
    func onError(_ errorData: [String: Any])
}
```

## Algorithms

These algorithms are implemented identically in Kotlin and Swift for cross-platform parity:

| Algorithm | Purpose | Complexity |
|---|---|---|
| **Haversine** | Great-circle distance between GPS coordinates | O(1) |
| **Ray-casting** | Point-in-polygon detection | O(n) where n = polygon vertices |
| **Douglas-Peucker** | Polygon simplification for large boundaries | O(n log n) |

## Privacy

All geofencing runs on-device. Zero location data is transmitted by default.

Telemetry is **opt-out** (enabled by default) when used through platform bridges like polyfence-flutter. The `TelemetryAggregator` in this library collects anonymous aggregate metrics — detection latency, GPS accuracy, battery drain, zone type counts. No GPS coordinates, zone definitions, user identifiers, or PII. Native consumers building custom bridges control telemetry defaults in their own configuration. See [polyfence-flutter TELEMETRY.md](https://github.com/blackabass/polyfence-flutter/blob/main/doc/TELEMETRY.md) for full details.

## Relationship to Other Repos

| Repository | What It Is |
|---|---|
| **[polyfence-core](https://github.com/blackabass/polyfence-core)** | This repo — shared native engine |
| **[polyfence-flutter](https://github.com/blackabass/polyfence-flutter)** | Flutter plugin that wraps polyfence-core |
| polyfence-react-native | React Native bridge (planned) |

## Building from Source

### Android

```bash
cd android
./gradlew build
./gradlew test
```

### iOS

```bash
# CocoaPods lint
cd ios
pod lib lint

# Swift Package Manager (from repo root)
swift build
swift test
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

MIT — see [LICENSE](LICENSE)

Copyright (c) 2026 Polyfence

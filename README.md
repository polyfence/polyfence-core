# Polyfence Core

[![CI](https://github.com/polyfence/polyfence-core/actions/workflows/ci.yml/badge.svg)](https://github.com/polyfence/polyfence-core/actions/workflows/ci.yml)
[![Maven Central](https://img.shields.io/maven-central/v/io.polyfence/polyfence-core)](https://central.sonatype.com/artifact/io.polyfence/polyfence-core)
[![CocoaPods](https://img.shields.io/cocoapods/v/PolyfenceCore)](https://cocoapods.org/pods/PolyfenceCore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Define once. Evaluate anywhere.**

polyfence-core is the mobile surface of the Polyfence geofence layer — the native Kotlin + Swift engine that evaluates zones on-device in mobile apps. Those same zone definitions power IoT and server-side evaluation elsewhere in the Polyfence platform. This repo powers [polyfence-flutter](https://github.com/polyfence/polyfence-flutter) and [polyfence-react-native](https://github.com/polyfence/polyfence-react-native); it runs entirely on-device with zero cloud dependencies and contains all geofencing algorithms, GPS management, and telemetry aggregation logic.

## Features

- **Polygon geofencing** — Ray-casting point-in-polygon algorithm for arbitrary polygon zones
- **Circle geofencing** — Haversine great-circle distance for radius-based zones
- **SmartGPS** — Intelligent GPS scheduling based on proximity, movement, activity, and battery state
- **Activity recognition** — Adjusts GPS intervals based on user activity (still, walking, driving, etc.)
- **Dwell detection** — Fire events when a device remains in a zone for a configurable duration
- **Zone clustering** — Performance optimization for large zone sets (100+ zones)
- **Scheduled tracking** — Time-window and day-of-week tracking schedules
- **Telemetry aggregation** — Session-level performance metrics collected natively. Zero PII about your end users; never coordinates, never identifiers.
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
pod 'PolyfenceCore', '~> 1.0.12'
```

### iOS (Swift Package Manager)

Add to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/polyfence/polyfence-core.git", from: "1.0.12")
```

Or in Xcode: File → Add Package Dependencies → paste the repository URL.

### Android (Maven)

```kotlin
implementation("io.polyfence:polyfence-core:1.0.12")
```

### Who this is for

polyfence-core is the mobile/native entry point to the Polyfence platform. If you're integrating geofencing into a mobile app, start here. If you're integrating into a Flutter or React Native app, use polyfence-flutter or polyfence-react-native (they wrap this library). If you're integrating into IoT firmware, use polyfence-embedded. If you're calling the API from a server, use the OpenAPI spec at polyfence.io.

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
  └── polyfence-react-native      React Native bridge (depends on polyfence-core)
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
| `PolyfenceCoreDelegate` | Bridge interface — platform bridges implement this to receive events from the engine. |
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

### Events

`onGeofenceEvent` fires with an `eventType` string. The full set:

| Event | When it fires |
|---|---|
| `ENTER` | The user crossed **into** a zone during active tracking. |
| `EXIT` | The user crossed **out of** a zone during active tracking. |
| `DWELL` | The user has been continuously inside a zone for the configured dwell duration. |
| `RECOVERY_ENTER` | The tracking process was killed and restarted (Doze kill, OOM, force-stop, phone reboot). On the first GPS fix after restart, the user is **inside** a zone that persisted state records as **outside**. |
| `RECOVERY_EXIT` | Same restart trigger as `RECOVERY_ENTER`, but the reverse: on the first fix after restart the user is **outside** a zone persisted state records as **inside**. |

`RECOVERY_ENTER` / `RECOVERY_EXIT` reconcile the persisted `ZonePersistence` state with the actual current location when the tracking process re-inits with empty in-memory state. They exist so the app can tell "the user crossed a boundary while we were dead" apart from "the user just crossed a boundary now."

**These events do NOT fire on GPS signal loss and recovery during an active tracking session.** During a live session, in-memory zone state stays authoritative through GPS blackouts. When GPS returns, the next fix flows through the normal detection path and fires a regular `ENTER` / `EXIT` for any boundary the user actually crossed during the outage. No recovery events are involved.

## Algorithms

These algorithms are implemented identically in Kotlin and Swift for cross-platform parity:

| Algorithm | Purpose | Complexity |
|---|---|---|
| **Haversine** | Great-circle distance between GPS coordinates | O(1) |
| **Ray-casting** | Point-in-polygon detection | O(n) where n = polygon vertices |
| **Point-to-segment distance** | Boundary proximity calculation | O(1) |

## Privacy

All geofencing runs on-device. Zero location data is transmitted by default.

Polyfence collects zero PII and zero identifiable data about your end users. Telemetry is **opt-out** (enabled by default) when used through platform bridges like [polyfence-flutter](https://github.com/polyfence/polyfence-flutter) and [polyfence-react-native](https://github.com/polyfence/polyfence-react-native). The `TelemetryAggregator` in this library collects anonymous aggregate metrics — detection latency, GPS accuracy, battery drain, zone type counts. No GPS coordinates, zone definitions, user identifiers, or PII. Telemetry is one line of code to disable in any bridge — see telemetry docs for [Flutter](https://github.com/polyfence/polyfence-flutter/blob/main/doc/TELEMETRY.md) and [React Native](https://github.com/polyfence/polyfence-react-native/blob/main/doc/TELEMETRY.md) for the exact API. Native consumers building custom bridges decide whether to wire telemetry at all.

## Relationship to Other Repos

| Repository | What It Is |
|---|---|
| **[polyfence-core](https://github.com/polyfence/polyfence-core)** | This repo — shared native engine |
| **[polyfence-flutter](https://github.com/polyfence/polyfence-flutter)** | Flutter plugin that wraps polyfence-core |
| **[polyfence-react-native](https://github.com/polyfence/polyfence-react-native)** | React Native bridge that wraps polyfence-core |

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

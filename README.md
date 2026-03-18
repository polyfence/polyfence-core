# Polyfence Core

[![CI](https://github.com/blackabass/polyfence-core/actions/workflows/ci.yml/badge.svg)](https://github.com/blackabass/polyfence-core/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)

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

## Installation

### iOS (CocoaPods)

```ruby
pod 'PolyfenceCore', '~> 1.0.0'
```

### Android (Maven)

```kotlin
implementation("com.polyfence:polyfence-core:1.0.0")
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
    fun isTrackingEnabled(): Boolean
}
```

```swift
// Swift (iOS)
protocol PolyfenceCoreDelegate: AnyObject {
    func onGeofenceEvent(_ eventData: [String: Any])
    func onLocationUpdate(_ locationData: [String: Any])
    func onPerformanceEvent(_ performanceData: [String: Any])
    func onError(_ errorData: [String: Any])
    func isTrackingEnabled() -> Bool
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

When telemetry is enabled (opt-in), only anonymous aggregate metrics are sent — detection latency, GPS accuracy, battery drain, zone type counts. No GPS coordinates, zone definitions, user identifiers, or PII.

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
cd ios
pod lib lint
```

## Contributing

See [polyfence-flutter CONTRIBUTING.md](https://github.com/blackabass/polyfence-flutter/blob/main/CONTRIBUTING.md) for development guidelines. The same conventions apply here.

## License

MIT — see [LICENSE](LICENSE)

Copyright (c) 2026 Sector7 / Polyfence

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-03-16

Initial release — standalone native geofencing engine extracted from polyfence-plugin.

### Features
- **GeofenceEngine** — Polygon (ray-casting) and circle (haversine) geofencing with dwell detection
- **LocationTracker** — SmartGPS with activity-based interval management and four update strategies (continuous, proximity-based, movement-based, intelligent)
- **ActivityRecognitionManager** — Play Services (Android) / CoreMotion (iOS) activity detection
- **TrackingScheduler** — Time-window and day-of-week tracking schedules
- **SmartGpsConfig** — Accuracy profiles (max, balanced, battery-optimal, adaptive) with configurable proximity, movement, battery, dwell, cluster, schedule, and activity settings
- **ZonePersistence** — Zone state recovery across app restarts via SharedPreferences (Android) / UserDefaults (iOS)
- **TelemetryAggregator** — Native-side session telemetry collection (activity distribution, GPS intervals, zone metrics, device context)
- **PolyfenceCoreDelegate** — Platform-agnostic bridge interface for Flutter, React Native, and native SDK consumers
- **PolyfenceErrorManager** — Structured error reporting with typed errors and correlation IDs
- **PolyfenceDebugCollector** — System status, performance metrics, battery stats, and zone status collection

### Architecture
- Zero Flutter/React Native dependencies — pure Kotlin (Android) and Swift (iOS)
- Published as CocoaPod (iOS) and Maven artifact (Android)
- All platform bridges depend on this shared engine

# Changelog

## 1.0.0

Initial release — standalone native geofencing engine extracted from polyfence-plugin.

### Features
- GeofenceEngine: polygon (ray-casting) and circle (haversine) geofencing
- LocationTracker: SmartGPS with activity-based interval management
- ActivityRecognitionManager: Play Services (Android) / CoreMotion (iOS)
- TrackingScheduler: time window and day-of-week scheduling
- SmartGpsConfig: accuracy profiles (max, balanced, battery-optimal, adaptive)
- ZonePersistence: zone state recovery across app restarts
- TelemetryAggregator (D016): session telemetry collection in native layer
- PolyfenceCoreDelegate: platform-agnostic bridge interface

### Architecture
- Zero Flutter/React Native dependencies
- Published as CocoaPod (iOS) + Maven artifact (Android)
- All platform bridges depend on this shared SDK

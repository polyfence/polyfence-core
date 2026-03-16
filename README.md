# Polyfence Core

Privacy-first polygon and circle geofencing engine for iOS and Android. Platform-agnostic native SDK — no Flutter, no React Native dependencies.

## What It Does

- On-device polygon geofencing (ray-casting algorithm)
- On-device circle geofencing (haversine formula)
- SmartGPS with activity-based tracking intervals
- Background location tracking on iOS and Android
- Activity recognition (CoreMotion / Play Services)
- Zone enter/exit/dwell events
- Configurable accuracy profiles (max, balanced, battery-optimal, adaptive)
- Zone clustering for performance
- Scheduled tracking (time windows, day-of-week)
- Built-in telemetry aggregation (D016)

## Integration

### iOS (CocoaPods)

```ruby
pod 'PolyfenceCore', '~> 1.0.0'
```

### Android (Maven)

```kotlin
implementation("com.polyfence:polyfence-core:1.0.0")
```

## Architecture

This is the shared native engine consumed by platform bridges:

```
polyfence-core           <-- You are here
  |
  +-- polyfence-flutter       (Flutter bridge, depends on polyfence-core)
  +-- polyfence-react-native  (RN bridge, depends on polyfence-core)
  +-- polyfence-intelligence  (ML add-on, depends on polyfence-core)
```

## Privacy

All geofencing runs on-device. Zero location data transmitted by default. Telemetry is anonymous aggregate metrics only (latency, accuracy, battery) — no GPS coordinates, no PII.

## License

MIT

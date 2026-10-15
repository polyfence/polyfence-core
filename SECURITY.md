# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 3.0.x   | Yes       |
| < 3.0   | No        |

## Reporting a Vulnerability

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them responsibly by emailing:

**hello@polyfence.io**

You should receive a response within 48 hours. If for some reason you do not, please follow up via email to ensure we received your original message.

### What to Include

When reporting a vulnerability, please include:

- **Type of vulnerability** (e.g., incorrect boundary detection, memory leak, thread safety issue)
- **Full paths of affected files**
- **Step-by-step instructions** to reproduce the issue
- **Proof of concept** or test code (if possible)
- **Impact assessment** — how severe is this vulnerability?
- **Your contact information** for follow-up questions

### What to Expect

1. **Acknowledgment** within 48 hours
2. **Initial assessment** within 5 business days
3. **Regular updates** as we investigate and develop a fix
4. **Credit** in the security advisory (if you want)

### Our Commitment

- We will keep you informed throughout the process
- We will not take legal action against security researchers who follow this policy
- We will credit you in security advisories (unless you prefer anonymity)
- We aim to patch critical vulnerabilities within 7 days

## Security Architecture

PolyfenceCore is a standalone native geofencing engine with a minimal attack surface:

- **No network calls** — the library never connects to the internet
- **No telemetry sent from here**: the library builds telemetry aggregates in memory but never sends them. The Flutter and React Native bridges send them, as each bridge's TELEMETRY.md describes
- **On-disk persistence is optional**: the engine keeps working zone state **in memory** while running. It creates one folder of its own in the host app's private storage, excluded from device backup (`pending_events` on Android, `polyfence-pending-events` on iOS). Zone events, including where they happened, are written there only when the pending-events queue is on (off by default); if you also turn on OS wake fences (opt-in), crossings the operating system wakes your app for are written to the same queue. A drain removes the stored events and hands them to your app. If an automatic replay finds no listener registered yet, the events go back in the queue; on Android, the undelivered events also go back if the listener throws during replay. Turning the queue off does not delete what is already stored. The folder also keeps a running count of events dropped when the queue was full, with no location in it. **`ZonePersistence`** (attachable via **`setZonePersistence`**, and registered automatically by bundled **`LocationTracker`**) serializes zones and inside/outside state to the **host app's** SharedPreferences (Android) or UserDefaults (iOS), which is **not encrypted** by the library
- **Permissions**: on Android the library requests none; the host app asks for location and activity recognition. On iOS, LocationTracker asks for notification permission when it is set up, for location (While Using) when tracking starts and none has been granted, for Always location only if you call requestPermissions(always: true), and triggers the Motion & Fitness prompt if activity recognition is on
- **On-device processing**: reads positions from the phone's location service and runs haversine distance, ray-casting point-in-polygon and boundary distance checks on the device

### Thread Safety

- Android: `ConcurrentHashMap` for zone state, synchronized access to shared resources
- iOS: `DispatchQueue` serialization for thread-safe state mutations
- Both platforms: engine methods are safe to call from any thread

### Algorithm Parity

The same geofencing algorithms (haversine, ray-casting, point-to-segment distance, false event detection) are implemented in both Kotlin and Swift. Any security-relevant fix must be applied to both implementations.

## Security Best Practices

### For Developers Using PolyfenceCore

1. **Zone Data**
   - Zone coordinates are held in memory by the engine during operation
   - If your integration enables **`ZonePersistence`** (directly or via **`LocationTracker`**), zones and inside/outside state are written to the host app's local storage (SharedPreferences on Android, UserDefaults on iOS) — **not encrypted** by default
   - If you use the engine **without** persistence, nothing is written by the library; you remain responsible for any data you persist yourself
   - For sensitive zones (private addresses, restricted facilities), encrypt coordinates before passing them to the engine or use platform-specific encrypted storage

2. **Location Data**
   - PolyfenceCore processes GPS coordinates on-device only
   - The library never transmits location data anywhere
   - Your app is responsible for how it handles location data obtained from the engine's callbacks

3. **Bridge Interface**
   - `PolyfenceCoreDelegate` is the only communication channel between the engine and the host app/plugin
   - All geofence events, location updates, and errors flow through this interface
   - Validate delegate callbacks if your app forwards them to untrusted contexts

## iOS Deployment Notes

### Time-Critical Alerts (Optional, Downstream)

If your app needs zone events to break through Do Not Disturb / Silent mode / Focus — for example perimeter security, anti-theft, child safety, fall detection, or medication adherence — you'll want Apple's [Critical Alerts entitlement](https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/). PolyfenceCore fires events to your code via `PolyfenceCoreDelegate`; surfacing them with `.criticalAlert` is your app's responsibility and requires this entitlement, applied for via the form linked above.

This is **not** required for normal use cases — standard "you arrived at the office" notifications work fine without it. The entitlement is specifically for time-critical safety / security scenarios where breaking through DND is essential.

## Security Updates

Security updates are released as patch versions (e.g., 3.0.1) and announced via:

- GitHub Security Advisories
- CHANGELOG.md
- Maven Central / CocoaPods release notes

Subscribe to repository releases to get notifications.

## Dependencies

PolyfenceCore has minimal dependencies:

**Android:**
- Google Play Services Location (`com.google.android.gms:play-services-location:21.3.0`) — GPS and activity recognition

**iOS:**
- CoreLocation (system framework) — GPS
- CoreMotion (system framework) — activity recognition

No third-party libraries beyond platform SDKs.

## Contact

- **Security vulnerabilities, privacy questions, or general inquiries**: hello@polyfence.io
- **Technical questions**: Open a GitHub issue with `question` label
- **Commercial support**: https://polyfence.io

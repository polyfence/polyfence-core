# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |

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
- **No data collection** — no telemetry, analytics, or usage tracking
- **No file system access** — no persistent storage (zone state is in-memory only; `ZonePersistence` writes to the host app's storage, not its own)
- **No permissions required** — the library itself requires no device permissions; GPS and activity recognition permissions are requested by the host app
- **Pure computation** — haversine distance, ray-casting point-in-polygon, and boundary distance calculations

### Thread Safety

- Android: `ConcurrentHashMap` for zone state, synchronized access to shared resources
- iOS: `DispatchQueue` serialization for thread-safe state mutations
- Both platforms: engine methods are safe to call from any thread

### Algorithm Parity

The same geofencing algorithms (haversine, ray-casting, point-to-segment distance, false event detection) are implemented in both Kotlin and Swift. Any security-relevant fix must be applied to both implementations.

## Security Best Practices

### For Developers Using PolyfenceCore

1. **Zone Data**
   - Zone coordinates are held in memory by the engine
   - `ZonePersistence` serializes zones to the host app's local storage (SharedPreferences on Android, UserDefaults on iOS) — this is **not encrypted** by default
   - For sensitive zones (private addresses, restricted facilities), encrypt coordinates before passing them to the engine or use platform-specific encrypted storage

2. **Location Data**
   - PolyfenceCore processes GPS coordinates on-device only
   - The library never transmits location data anywhere
   - Your app is responsible for how it handles location data obtained from the engine's callbacks

3. **Bridge Interface**
   - `PolyfenceCoreDelegate` is the only communication channel between the engine and the host app/plugin
   - All geofence events, location updates, and errors flow through this interface
   - Validate delegate callbacks if your app forwards them to untrusted contexts

## Security Updates

Security updates are released as patch versions (e.g., 1.0.1) and announced via:

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

- **Security issues**: hello@polyfence.io
- **General questions**: Open a GitHub issue with `question` label
- **Commercial support**: https://polyfence.io

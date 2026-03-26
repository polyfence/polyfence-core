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
- **No vendor telemetry** — no analytics or usage tracking to Polyfence or third parties
- **On-disk persistence is optional** — the engine keeps working zone state **in memory** while running. It does not create a separate app sandbox or library-owned files. **`ZonePersistence`** (attachable via **`setZonePersistence`**, and registered automatically by bundled **`LocationTracker`**) serializes zones and inside/outside state to the **host app's** SharedPreferences (Android) or UserDefaults (iOS), which is **not encrypted** by the library
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

- **Security vulnerabilities**: hello@polyfence.io
- **Privacy practices (this library)**: see [PRIVACY.md](./PRIVACY.md) — hello@polyfence.io
- **General inquiries**: hello@polyfence.io
- **Technical questions**: Open a GitHub issue with `question` label
- **Commercial support**: https://polyfence.io

# PolyfenceCore — Privacy Policy

**Effective Date:** March 26, 2026
**Last Updated:** March 26, 2026
**Applies to:** PolyfenceCore native library (Kotlin + Swift)

---

## Where this fits in the Polyfence platform

polyfence-core is the mobile surface of the Polyfence platform — the same zones you define once also run on IoT devices (polyfence-embedded) and on the Polyfence server (polyfence.io). Each surface has its own privacy posture. This library has the strongest one: it never makes network calls, never collects, never transmits, never stores. Aggregate telemetry — when you opt into it through a bridge like polyfence-flutter or polyfence-react-native — never includes coordinates, identifiers, or PII.

---

## Overview

PolyfenceCore is a standalone on-device geofencing engine. It performs geometric calculations (haversine distance, ray-casting point-in-polygon, boundary distance) on coordinates your app provides. That's all it does.

### Zero PII about your end users

This library **never collects, transmits, or stores** location data, identifiers, or PII. It makes no network calls to Polyfence, includes no vendor telemetry, and does not send us any data. Any zone or location data remains under **your** app's control.

All geofence math runs on-device by default. The one exception is the opt-in OS wake fences described below, which share zone boundaries — never positions — with the operating system.

---

## What This Library Does NOT Do

- Does not connect to the internet
- Does not phone home, track usage, or send analytics to Polyfence or third parties
- Does not request device permissions (GPS and activity recognition permissions are your app's responsibility)
- Does not share anything with the operating system's geofence service unless you opt in — see below

### OS wake fences (opt-in, off by default)

When the developer enables `osGeofenceWakeEnabled`, Polyfence registers a small number of zone perimeters (coordinates + radius) with the phone's operating system geofence service, so that events can fire when the app is not running. Only zone boundaries are shared with the OS — the user's location is still processed on-device and is never sent to the OS or to us via this mechanism. When `osGeofenceWakeEnabled` is disabled (the default), no zone data is shared with the OS.

On Android those boundaries go to Google Play Services; on iOS, to CoreLocation. Both are components of the device's operating system, not Polyfence services. If you enable this, reflect it in your own privacy policy.

This is also the only part of the library that needs a background-location grant. Base tracking runs as a foreground service and asks for foreground location only, so an integration that leaves wake fences off never requests `ACCESS_BACKGROUND_LOCATION` (Android) or "Always" authorization (iOS), and shares nothing with the OS geofence service.

### Local persistence (optional)

- **By default**, working zone state lives **in memory** only while the engine runs
- If your integration enables **`ZonePersistence`** (you attach it with **`setZonePersistence`**, or you use **`LocationTracker`**, which registers it for you), zones and inside/outside state are written to **your app's** local storage (SharedPreferences on Android, UserDefaults on iOS), not a separate library-owned container. That storage is **not encrypted** by this library

---

## Your Responsibility as a Developer

PolyfenceCore processes GPS coordinates and zone definitions that your app provides. How you obtain, store, and handle that location data is your responsibility.

If your app collects location data from users, you should:

- Have a privacy policy that covers location data collection
- Obtain user consent for location tracking as required by your jurisdiction
- Comply with applicable regulations (GDPR, CCPA, etc.)

PolyfenceCore gives you the geofencing engine. What you build with it — and how you handle your users' data — is up to you.

---

## Related Privacy Policies

- **Polyfence Flutter plugin** (wraps this library, adds optional telemetry): [PRIVACY.md](https://github.com/polyfence/polyfence-flutter/blob/main/PRIVACY.md)
- **Polyfence platform** (polyfence.io SaaS): [polyfence.io/privacy](https://polyfence.io/privacy)

---

## Contact

- **Questions, data requests, security vulnerabilities, or general inquiries:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **Technical support:** [GitHub Issues](https://github.com/polyfence/polyfence-core/issues)

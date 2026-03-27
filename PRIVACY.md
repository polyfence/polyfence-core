# PolyfenceCore — Privacy Policy

**Effective Date:** March 26, 2026
**Last Updated:** March 26, 2026
**Applies to:** PolyfenceCore native library (Kotlin + Swift)

---

## Overview

PolyfenceCore is a standalone on-device geofencing engine. It performs geometric calculations (haversine distance, ray-casting point-in-polygon, boundary distance) on coordinates your app provides. That's all it does.

**This library makes no network calls to Polyfence, includes no vendor telemetry, and does not send us any data.** All geofence math runs on-device. Any zone or location data remains under **your** app's control.

---

## What This Library Does NOT Do

- Does not connect to the internet
- Does not phone home, track usage, or send analytics to Polyfence or third parties
- Does not request device permissions (GPS and activity recognition permissions are your app's responsibility)

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

- **Privacy questions and data requests:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **Security vulnerabilities:** [hello@polyfence.io](mailto:hello@polyfence.io) (or see [SECURITY.md](./SECURITY.md))
- **General inquiries:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **Technical support:** [GitHub Issues](https://github.com/polyfence/polyfence-core/issues)

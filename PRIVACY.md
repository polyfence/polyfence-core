# PolyfenceCore — Privacy Policy

**Effective Date:** March 26, 2026
**Last Updated:** March 26, 2026
**Applies to:** PolyfenceCore native library (Kotlin + Swift)

---

## Overview

PolyfenceCore is a standalone on-device geofencing engine. It performs geometric calculations (haversine distance, ray-casting point-in-polygon, boundary distance) on coordinates your app provides. That's all it does.

**This library makes no network calls, collects no data, and has no telemetry.**

---

## What This Library Does NOT Do

- Does not connect to the internet
- Does not collect, transmit, or store any data
- Does not include analytics, telemetry, or usage tracking
- Does not request device permissions (GPS and activity recognition permissions are your app's responsibility)
- Does not persist data to disk (zone state is held in memory; `ZonePersistence` writes to your app's local storage, not its own)

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

- **Polyfence Flutter plugin** (wraps this library, adds optional telemetry): [PRIVACY.md](https://github.com/blackabass/polyfence-flutter/blob/main/PRIVACY.md)
- **Polyfence platform** (polyfence.io SaaS): [polyfence.io/privacy](https://polyfence.io/privacy)

---

## Contact

- **Privacy questions:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **Security vulnerabilities:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **General support:** [GitHub Issues](https://github.com/blackabass/polyfence-core/issues)

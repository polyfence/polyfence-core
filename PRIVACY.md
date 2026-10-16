# PolyfenceCore — Privacy Policy

**Effective Date:** August 5, 2026
**Last Updated:** October 15, 2026
**Applies to:** PolyfenceCore native library (Kotlin + Swift)

---

## Where this fits in the Polyfence platform

polyfence-core is the mobile surface of the Polyfence platform: the same zones you define once also run on IoT devices (polyfence-embedded) and on the Polyfence server (polyfence.io). Each surface has its own privacy posture. This library has the strongest one: it makes no network calls, so nothing leaves the device by way of this library. It does build telemetry aggregates in memory, for example detection latency, GPS accuracy, battery level and charging, zone counts by size, the hour the session started, the device class and OS version, and some derived from location or motion (average speed at events, average distance to the zone edge at events, activity mix; the dwell-time fields are in the payload but this version leaves them empty). The full list is in each bridge's TELEMETRY.md. A bridge like polyfence-flutter or polyfence-react-native is what sends them. Telemetry is enabled by default, and one line in the bridge turns it off. Those aggregates never include coordinates or end-user identifiers. The bridge adds the host app's package name when it sends them.

---

## Overview

PolyfenceCore is a standalone on-device geofencing engine. It reads positions from the phone's location service, or takes coordinates your app provides, and runs geometric calculations on them (haversine distance, ray-casting point-in-polygon, boundary distance) to tell your app when a device enters, dwells in or leaves a zone.

### Zero PII about your end users

This library makes no network calls and sends us nothing. It reads positions from the phone to check zones, keeps them on the device, and gives your app the position with each zone event. The telemetry aggregates it builds are sent only by the Flutter or React Native bridge, as each bridge's TELEMETRY.md describes ([Flutter](https://github.com/polyfence/polyfence-flutter/blob/main/doc/TELEMETRY.md), [React Native](https://github.com/polyfence/polyfence-react-native/blob/main/doc/TELEMETRY.md)).

All geofence math runs on-device by default. The one exception is the opt-in OS wake fences described below, which share zone boundaries — never positions — with the operating system.

---

## What This Library Does NOT Do

- Does not connect to the internet
- Does not phone home or send analytics to Polyfence or third parties. It builds telemetry aggregates in memory, and only a bridge sends them
- Does not request permissions on Android; your app asks for location and activity recognition. On iOS, LocationTracker asks for notification permission when it is set up, for location (While Using) when tracking starts and none has been granted, for Always location only if you call requestPermissions(always: true), and triggers the Motion & Fitness prompt if you turn on activity recognition
- Does not share anything with the operating system's geofence service unless you opt in — see below

### OS wake fences (opt-in, off by default)

When the developer enables `osGeofenceWakeEnabled`, Polyfence registers a small number of zone perimeters (coordinates + radius) with the phone's operating system geofence service, so that events can fire when the app is not running. Only zone boundaries are shared with the OS — the user's location is still processed on-device and is never sent to the OS or to us via this mechanism. When `osGeofenceWakeEnabled` is disabled (the default), no zone data is shared with the OS.

On Android those boundaries go to Google Play Services; on iOS, to CoreLocation. Both are components of the device's operating system, not Polyfence services. If you enable this, reflect it in your own privacy policy.

This is also the only part of the library that needs a background-location grant. Base tracking needs foreground location only (on Android it runs as a foreground service), so an integration that leaves wake fences off has no need for `ACCESS_BACKGROUND_LOCATION` (Android) or "Always" authorization (iOS), and shares nothing with the OS geofence service. On iOS, LocationTracker asks for Always only if you call requestPermissions(always: true).

### Local persistence (optional)

- With the engine alone, working zone state lives **in memory** only while it runs
- If your integration enables **`ZonePersistence`** (you attach it with **`setZonePersistence`**, or you use **`LocationTracker`**, which registers it for you), zones and inside/outside state are written to **your app's** local storage (SharedPreferences on Android, UserDefaults on iOS), not a separate library-owned container. That storage is **not encrypted** by this library
- If you turn on the **pending-events queue** (off by default), zone events that could not reach your app straight away are written to a file in your app's private storage, excluded from backup, until your app drains them. With the queue on, crossings that an opt-in OS wake fence wakes your app for are written there too. Each event includes the position where it happened. Turning the queue off does not delete events already stored.

---

## Your Responsibility as a Developer

PolyfenceCore reads positions from the phone's location service, or takes coordinates your app provides, and checks them against your zones. It hands each zone event to your app with the position where it happened. How you store, send and handle that data is your responsibility.

If your app collects location data from users, you should:

- Have a privacy policy that covers location data collection
- Obtain user consent for location tracking as required by your jurisdiction
- Comply with applicable regulations (GDPR, CCPA, etc.)

PolyfenceCore gives you the geofencing engine. What you build with it — and how you handle your users' data — is up to you.

---

## Related Privacy Policies

- **Polyfence Flutter plugin** (wraps this library and sends its telemetry aggregates, on by default): [PRIVACY.md](https://github.com/polyfence/polyfence-flutter/blob/main/PRIVACY.md)
- **Polyfence React Native module** (wraps this library and sends its telemetry aggregates, on by default): [PRIVACY.md](https://github.com/polyfence/polyfence-react-native/blob/main/PRIVACY.md)
- **Polyfence platform** (polyfence.io SaaS): [polyfence.io/privacy](https://polyfence.io/privacy)

---

## Contact

- **Questions, data requests, security vulnerabilities, or general inquiries:** [hello@polyfence.io](mailto:hello@polyfence.io)
- **Technical support:** [GitHub Issues](https://github.com/polyfence/polyfence-core/issues)

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **iOS `pausesLocationUpdatesAutomatically` now always `false`** — `SmartGpsConfig.shouldPauseAutomatically()` previously returned `true` for the `balanced`, `batteryOptimal`, and `adaptive` profiles, which let iOS pause CLLocationManager when it considered the device stationary and then suspend the host app. The next time the user crossed a boundary, CLLocationManager arrived at a suspended app (and often at a delegate that had been deallocated) so the ENTER/EXIT/DWELL was dropped. Symptom: iOS RN consumers caught a small fraction of the events that Android RN / Android Flutter / iOS Flutter siblings caught — multi-hour gaps in the Events Log after any stationary period. Geofencing lives or dies on correctness; the slight battery saving from auto-pause was buying app suspension at the cost of every event we exist to deliver. Now always `false` across all accuracy profiles, matching how the Android side stays continuously alive via its foreground service.

### Fixed
- **iOS misuse of `UIApplication.beginBackgroundTask` was triggering iOS termination warnings (and likely contributing to background-suspension kills).** `LocationTracker.startTracking()` was calling `beginBackgroundTask(withName: "PolyfenceLocationTracking")` and only releasing the task ID in `stopTracking()`. iOS treats `beginBackgroundTask` as a finite-work API (≤30 s) and logs `"Background Task X, was created over 30 seconds ago. In applications running in the background, this creates a risk of termination."` once the threshold is exceeded — then may proactively terminate the app for misuse. For continuous background location, the right tools are already in place: `UIBackgroundModes: location` (Info.plist) plus `CLLocationManager.allowsBackgroundLocationUpdates = true`. **Removed** the `beginBackgroundTask`/`endBackgroundTask` helpers and the `backgroundTaskId` field; tracking now relies on the location background mode alone (matching how every reference iOS background-location client works).
- **iOS polygon self-intersection false positives at closure seam** — `GeofenceEngine.ZoneData.fromMap` was rejecting closed polygons supplied with an explicit closing vertex (`first == last`) or with consecutive duplicate points. The CCW segment-intersection test only skipped the literal `(edge 0, edge n-1)` pair, but on a closed input the geometric closure happens between edges `0` and `n-2` (both touch `points[0] == points[n-1]`), so one cross product evaluated to `0` and the algorithm reported a false self-intersection. Real-world geocoded boundaries with explicit closure (London CC's 1098-point polygon, ULEZ, etc.) were silently `throw`-ing through the previously-empty `catch {}` in `LocationTracker.addZone`, leaving the engine with no record of those zones. **Fix:** normalize the polygon before the self-intersect check (strip the trailing duplicate vertex if `first == last`; collapse consecutive duplicates) and downgrade a residual self-intersection from a hard reject to an `NSLog` warning — point-in-polygon (ray casting / even-odd rule) is well-defined for self-intersecting polygons, so we don't gain anything by refusing them.
- **iOS initial ENTER never fires for stationary user when tracking starts inside a zone** — `LocationTracker.reconcileZoneStates` was gated exclusively behind the first `didUpdateLocations` delegate callback, but under `pausesLocationUpdatesAutomatically = true` + the 20 m distance filter, CLLocationManager can defer that callback indefinitely on a stationary device. The user would tap tracking inside a zone and *no* ENTER would fire until they physically moved (or in some cases not at all in the active session). **Fix:** when `startGpsUpdates` finds a cached `locationManager.location`, run `reconcileZoneStates` against it immediately and clear `firstLocationAfterRestart`. Subsequent fresh `didUpdateLocations` callbacks now skip reconcile (already done) and fall through to the normal `checkLocation` path — no behaviour change for the moving case.
- **iOS silent zone-add failures now logged** — `LocationTracker.addZone` previously had `catch {}` with no diagnostic; any `GeofenceEngine.addZone` throw (e.g. polygon validation, missing center) silently disappeared. The bridge would still resolve its addZone promise as if the zone had been added. Now logs `[LocationTracker] Failed to add zone <id>: <error>` so consumers can see why a zone isn't registered.

### Tests
- Added regression coverage for the polygon-validation fix (`testAddZoneAcceptsClosedPolygonWithExplicitClosingVertex`, `testAddZoneCollapsesConsecutiveDuplicateVertices`) and updated `testSelfIntersectingPolygonIsAcceptedWithWarning` to reflect the warn-not-throw contract.
- Added regression coverage for the cached-location reconcile fix (`testReconcileFiresEnterForInsideZonesWhenNoPersistedState`) — verifies the fresh-install branch fires ENTER for every zone the user is inside, matching the tap-tracking-while-stationary UX on the sibling platforms.

## [1.0.6] - 2026-05-26

### Fixed
- **iOS `CLLocationManager` constructed off-main from React Native bridge caused silent loss of all location callbacks after the first cached fix.** Apple delivers `CLLocationManager`'s async delegate callbacks (`didUpdateLocations`, `didChangeAuthorization`, `didFailWithError`, etc.) via the run loop of the thread on which the manager was created. React Native 0.76+ in Bridgeless / New Arch dispatches `RCTEventEmitter` method invocations on a runloop-less background dispatch queue by default; `PolyfenceModule.initialize()` ran there, `LocationTracker()` ran there, and the manager was born on a thread without a CFRunLoop. The cached fix returned synchronously from `manager.location` flowed correctly, but every subsequent `didUpdateLocations` was buffered and eventually discarded, with iOS surfacing `Location callback block not executed in a timely manner` and `Discarding message for event because of too many unprocessed messages, count:N` in the unified log. To the user, GPS appeared frozen on the first reading indefinitely and no zone enter/exit events ever fired for the rest of the session. Flutter was unaffected because `FlutterMethodChannel` dispatches plugin calls on a thread that does have a run loop. **Fix:** `setupLocationManager()` now forces `CLLocationManager` construction onto main with `DispatchQueue.main.sync` (not `.async` — callers rely on `locationManager` being non-nil immediately after `init()` returns, e.g. `startTracking()` guards on it and bails out otherwise), regardless of which bridge instantiates `LocationTracker`. Adds an `os_log("PF-THREAD setupLocationManager isMain=%{public}d", ...)` diagnostic marker so any future regression is immediately visible in device logs.

## [1.0.5] - 2026-04-03

### Added
- **Core version self-reporting** — `PolyfenceCoreVersion.kt` and `PolyfenceCoreVersion.swift` stamp engine version into session telemetry via `TelemetryAggregator`. Bridges get `core_version` automatically through existing telemetry spread. (D043)

## [1.0.4] - 2026-04-01

### Fixed
- **iOS public access control** — `LocationTracker`, `ZonePersistence`, `PolyfenceConfig`, `SmartGpsConfig`, `SmartGpsConfigFactory`, and `Zone` types made `public` for CocoaPods consumers. Without `public`, these types were invisible when imported as a framework module (`import PolyfenceCore`). Android (Kotlin) was unaffected as `internal` is package-level, not module-level.

## [1.0.3] - 2026-04-01

### Fixed
- **Android FGS crash** — `startForeground()` moved before permission check in `startTracking()`. Prevents `ForegroundServiceDidNotStartInTimeException` on Android 14 when app restarts with stale permission state.
- **Android GPS cold-start** — Seed initial location from `fusedLocationClient.lastLocation` after `requestLocationUpdates()`. Mirrors iOS pattern (`requestLocation()` + `locationManager.location`). Stationary devices now get a position immediately.
- **Android distance filter deferral** — `minUpdateDistanceMeters` set to 0 for the initial location request, profile filter applied after first GPS fix. Prevents `ProviderRequest[OFF]` when STILL activity + distance filter combine on stationary devices.

## [1.0.2] - 2026-03-30

### Added
- **Bridge platform identification** — `TelemetryAggregator.setBridgePlatform()` and `SessionTelemetry.bridgePlatform` field. Bridges (Flutter, React Native) set their identity during initialization; carried through telemetry payload as `bridge_platform`.
- **Pending bridge pattern** — `LocationTracker.setBridgePlatform()` stores value when called before Android service exists, applies in `onCreate()`. Matches existing `pendingActivitySettings` pattern.
- **Missing bridge APIs** — `updateSmartConfiguration()` added to `LocationTracker.Companion` (Android). `clearScheduleConfig()`, `resetSmartConfiguration()`, `isTracking()` added to `LocationTracker` (iOS). All thin wrappers required by Flutter and React Native bridges.

### Fixed
- **Thread safety** — `TelemetryAggregator` (Kotlin) unified under single `synchronized(lock)`. Snapshot-only reads in `getSessionTelemetry()` — no mutation of aggregator state.

## [1.0.1] - 2026-03-29

### Added
- **iOS CI** — iOS build, test, and pod lint added to CI workflow, running in parallel with Android.

### Fixed
- **Delegate interface alignment** — `isTrackingEnabled()` added to `PolyfenceCoreDelegate` in both Kotlin and Swift. Published v1.0.0 Maven artifact included this method but the source on main did not, causing build failures for downstream consumers.

## [1.0.0] - 2026-03-24

GA release — hardened from ecosystem-wide audit (33 fixes). Ready for hackathon launch.

### Breaking Changes
- **Android minSdk raised to 24** (was 21) — drops <1.5% device share, eliminates 3 critical API compatibility issues
- **iOS deployment target raised to 14.0** (was 12.0) — drops <3% active devices, enables BackgroundTasks framework

### Added
- **GeoMath** utility class (Kotlin + Swift) — centralized haversine, ray-casting, and point-to-segment-distance algorithms. Eliminates triple duplication across GeofenceEngine, LocationTracker, and ZoneData.
- **GeoMathTest** — 26 unit tests (Kotlin) + 22 tests (Swift) with identical test vectors for cross-platform parity
- **SPM support** — `Package.swift` at repo root (swift-tools-version 5.9, iOS .v14)
- **ProGuard consumer rules** — `consumer-rules.pro` for Android library consumers
- **CI: iOS tests** — Swift test job added to CI pipeline
- **CI: publish gating** — publish workflow requires CI pass + tag-version sync validation
- **SCHEDULE_EXACT_ALARM** permission check before scheduling exact alarms (K11)
- **KDoc threading contract** on PolyfenceCoreDelegate — documents which callbacks are main-thread vs background (K15)
- Quick-start examples in README, CI badges, fixed contributing link

### Fixed
- **Thread safety** — PolyfenceDebugCollector (both platforms), ActivityRecognitionManager (Swift), LocationTracker (Kotlin recentLocations → ConcurrentLinkedDeque), GeofenceEngine (Swift ZoneConfidence sync via DispatchQueue)
- **Force unwraps removed** — SmartGpsConfig.swift (`as!` → `as?` with fallback defaults)
- **Async completion** — GeofenceEngine.addZone (Swift) now takes completion callback instead of returning synchronously
- **Deprecated API** — getSerializableExtra replacement for Android API 33+ (K12)
- **Duplicate telemetry** — removed redundant tracking from GeofenceEngine, TelemetryAggregator is single source
- **Constant naming** — `DEFAULT_DWELL_THRESHOLD_MS` → `DEFAULT_DWELL_THRESHOLD_SECONDS` (value was already in seconds)
- **UserDefaults.synchronize()** calls removed (deprecated, iOS handles persistence automatically)
- **Podspec tag mismatch** — `:tag` now uses `v#{s.version}` to match `v*` tag convention in publish workflow
- Documented blocking behavior of getCpuUsage (K7)

### Changed
- **Internal visibility** — TelemetryAggregator, PolyfenceDebugCollector, PolyfenceErrorManager, PolyfenceErrorRecovery marked `internal` (both platforms). These are implementation details, not public API.
- **SessionTelemetry** — all properties `let` (Swift), immutable after construction
- **AGP 8.7.3**, Kotlin 2.0.21, Gradle 8.11.1 (was AGP 8.1.4, Kotlin 1.9.10, Gradle 8.4)
- **Dependencies** — play-services-location 21.3.0, core-ktx 1.15.0, work-runtime-ktx 2.10.0

### Initial Release (2026-03-16)

Standalone native geofencing engine extracted from polyfence-plugin.

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
- Zero Flutter/React Native dependencies — pure Kotlin (Android) and Swift (iOS)
- Published as CocoaPod (iOS) and Maven artifact (Android)

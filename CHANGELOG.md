# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.12] - 2026-07-15

### Added
- **`LocationTracker.applyAddZoneDirect(context, zoneId, zoneName, zoneData)` / `applyRemoveZoneDirect(context, zoneId)` / `applyClearZonesDirect(context)` on Android** — three companion helpers on the running-Service pattern established by `applyConfigurationDirect` in 1.0.11. Bridges should call these instead of dispatching `ACTION_ADD_ZONE` / `ACTION_REMOVE_ZONE` / `ACTION_CLEAR_ZONES` via `startService` when they want the caller's promise to resolve after the engine and persistence are both updated. Direct-apply routes are synchronous on the running Service instance so `getCurrentZoneStates()` immediately after observes the change; falls back to the Intent transport when the Service isn't running (read-after-write only guaranteed on the direct path). Bug-021.

### Changed
- **iOS `LocationTracker.addZone` / `removeZone` / `clearAllZones` no longer wrap the engine call in `geofenceQueue.async`.** The `GeofenceEngine` methods already use their own `syncQueue.sync` internally for the `zoneStates` write, so the outer wrapper was redundant — it dispatched the mutation onto a background queue and returned before it ran, so an immediately-following `getCurrentZoneStates()` could still see the old state. `addZone` retains its `DispatchQueue.main.async` block for the CLLocationManager health-check / deferred-GPS-start / reconcile logic (those must run on main). Bug-021.

## [1.0.11] - 2026-07-08

### Added
- **`LocationTracker.applyConfigurationDirect(context, configMap)` on Android** — bridges should call this instead of dispatching `ACTION_UPDATE_CONFIG` via `startService` when they want the caller's promise to resolve after the mutation lands. Synchronous on the running Service instance so `updateConfiguration({...})` → `getConfiguration()` on the same thread observes the applied state. Falls back to the Intent transport when the Service isn't running; read-after-write is only guaranteed on the direct path.

## [1.0.10] - 2026-07-04

### Added
- **Battery telemetry capture on both platforms** — `TelemetryAggregator` now stamps session-start and session-end battery percentage and computes drain rate, wired symmetrically from Android's `LocationTracker` and iOS's `LocationTracker`. Available to bridges via the normal telemetry surface.
- **`getLastKnownAccuracy()` accessor on both platforms (BUG-013b core-side)** — bridges can now read the accuracy of the last GPS fix without subscribing to the location stream. Fills a gap where the status payload needed the field but the engine surfaced no read path for it.
- **`dwellDurationMs` in the `DWELL` event map (BUG-009 core)** — dwell time since the initial `ENTER` is now populated on every `DWELL` emit on both platforms, so bridges no longer have to compute it downstream (which required tracking their own per-zone timers).

### Changed (BREAKING)
- **`updateConfiguration` now MERGES over current state instead of REPLACING it (BUG-015)** — a partial call like `updateConfiguration({ "gpsIntervalMs": 5000 })` previously silently reset every unspecified field back to the profile defaults, killing user overrides that had been set earlier in the session. Both platforms now merge the incoming map over the current `SmartGpsConfig`, so unspecified keys retain their current value. **Migration if you depended on reset-to-defaults semantics:** either pass every field explicitly on each `updateConfiguration` call, or call `resetConfiguration()` first and then apply the partial.
- **Android `emitHealthScore` callback is now delivered on a background thread (BUG-010)** — the callback path from `HealthScoreCalculator` back into consumer code was previously dispatched on the main looper, holding the UI while the delegate did whatever it did. Moved to a background `Handler` (companion-scoped, cleaned up on `stopTracking`). **Migration if your `onHealthScore` handler touches UI or non-thread-safe state:** wrap the body in `runOnUiThread` / `Handler(Looper.getMainLooper()).post`, or synchronize appropriately. Regression coverage in `HealthScoreCalculatorThreadingTest`.
- **`runtime_status` map now returns a stable key set with `null` for unknown fields (BUG-013b)** — fields like `lastAccuracy`, `profile`, and `isTracking` were previously omitted from the map while tracking was paused, so callers had to check for key presence. Now every key is always present, with a `null` value where the field is genuinely unknown. **Migration if your code uses `map.containsKey("lastAccuracy")` / `"lastAccuracy" in map`:** switch to an explicit null-check (`map["lastAccuracy"] != null`). Paired with the new `getLastKnownAccuracy()` accessor.

### Fixed
- **Android polygon self-intersection false positives at closure seam (BUG-005)** — `GeofenceEngine.ZoneData.fromMap` was rejecting closed polygons supplied with an explicit closing vertex (`first == last`, the GeoJSON convention) or with consecutive duplicate points. The CCW segment-intersection test only skipped the literal `(edge 0, edge n-1)` pair, but on a closed input the geometric closure happens between edges `0` and `n-2` (both touch `points[0] == points[n-1]`), so one cross product evaluated to `0` and the algorithm reported a false self-intersection. Real-world geocoded country boundaries with explicit closure (Qatar from `geo-boundaries-world-110m`, etc.) were silently `throw`-ing through the bridge's `addZone` path, leaving the engine with no record of those zones. **Fix:** normalize the polygon before the self-intersect check (strip the trailing duplicate vertex if `first == last`; collapse consecutive duplicates) and downgrade a residual self-intersection from a hard reject to a `Log.w` warning — point-in-polygon (ray casting / even-odd rule) is well-defined for self-intersecting polygons, so we don't gain anything by refusing them. Ports the fix shipped on iOS in 1.0.7 to the Android side and restores cross-platform parity.
- **Silent `addZone` failures now surface via `onError` (BUG-006)** — an `addZone` throw from `GeofenceEngine` (polygon validation, missing center, malformed circle, etc.) previously reached an empty `catch {}` on Android and a bare `NSLog` on iOS, then the bridge's promise resolved as if the zone had been added. The engine now dispatches a structured error through `PolyfenceErrorManager` before the bridge sees the throw, so consumers subscribed to the error stream get a diagnosable event instead of a phantom-successful zone that never fires ENTER/EXIT.
- **`SmartGpsConfigFactory.toMap` emitted a partial config shape (BUG-014b)** — several fields (`clusterActiveRadius`, `stationaryDetectionSeconds`, dwell / cluster / schedule / activity blocks) were omitted from the serialized map so `getConfiguration()` returned an incomplete snapshot that bridges then couldn't round-trip through `updateConfiguration`. `toMap` now emits the full shape symmetrically on both platforms.
- **`errorHistory()` returned empty because `reportError` never persisted to `PolyfenceDebugCollector` (BUG-016)** — the developer's error stream fired correctly, but the history buffer was never written, so `getDebugInfo()` reported zero errors even after an obvious failure. `reportError` now records to the debug collector **before** invoking the consumer callback, so a throwing `onError` handler cannot lose the history-write.

### Documented
- **`RECOVERY_ENTER` / `RECOVERY_EXIT` event semantics (BUG-019)** — README's Bridge Interface section now includes an Events reference table that lists every `eventType` the delegate can receive, and explicitly calls out the load-bearing distinction: recovery events fire on tracking-process restart with a persisted-state mismatch (Doze kill / OOM / force-stop / phone reboot), NOT on GPS signal loss and recovery during an active session. The names were misleading readers into expecting the latter; behavior is intentional, gap was documentation.
- iOS Critical Alerts entitlement note added to `SECURITY.md`.

### Tests
- Updated `self-intersecting polygon throws exception` → `self-intersecting polygon is accepted with warning` to reflect the warn-not-throw contract (matches iOS `testSelfIntersectingPolygonIsAcceptedWithWarning`).
- Added `closed polygon with explicit closing vertex is accepted (BUG-005)` using Qatar's exact 9-point boundary from QA's RCA (mirrors iOS `testAddZoneAcceptsClosedPolygonWithExplicitClosingVertex`).
- `HealthScoreCalculatorThreadingTest` — regression guard for BUG-010 confirming `emitHealthScore` runs off the main looper.
- Android + iOS regression tests for BUG-016: `errorHistory` still contains the entry when the developer's `onError` callback throws.

## [1.0.9] - 2026-05-30

### Fixed
- **Fresh-install cold-start race: empty zone baseline locked in, every ENTER suppressed for that session and the next launch.** On a fresh install with no persisted state, the engine could receive its first GPS fix before any bridge `addZone()` calls had landed. The most common trigger: activity-recognition kicked GPS independently of `LocationTracker.startTracking()`'s `hasZones()` defer-gate, so a `STILL` activity transition fired `startGpsUpdates()` ~10 s before the JS layer's API-fetch-and-loop-addZone burst completed. The first fix arrived, `reconcileZoneStates` ran the fresh-install branch with `zones.size == 0`, and `persistAllZoneStates()` wrote `0 zones, inside=0` to disk. Subsequent `addZone` re-reconcile calls evaluated against the same cached (often inaccurate) fix and silently no-op'd. Result: no ENTER fired for any zone in that session, and the bad baseline survived the next cold launch via persisted state — until the user force-stopped the app, which restored zones from storage with `stateRecoveredFromPersistence = true` and exercised the regular reconcile branch instead. iOS did not reproduce (CLLocationManager's synchronous `requestLocation` returns fast enough that zones are present by first fix), but the same guard is applied symmetrically for platform parity and defense-in-depth. **Fix:** `GeofenceEngine.reconcileZoneStates` now early-returns from the fresh-install branch when `zones.isEmpty()`, without persisting an empty baseline. `stateRecoveredFromPersistence` stays `false`, so the next reconcile call — typically driven by `LocationTracker.addZone()` once the bridge finishes its addZone burst — re-enters the branch with zones populated and the existing idempotent `false → true` transition loop fires ENTER for every zone the user is inside. Applied to both `GeofenceEngine.kt` (Android) and `GeofenceEngine.swift` (iOS).

## [1.0.8] - 2026-05-27

### Fixed
- **Android geofence event delegate map was missing `timestamp`.** `LocationTracker.handleGeofenceTransition` built the event dictionary forwarded to `coreDelegate.onGeofenceEvent(...)` without including a `"timestamp"` field, while iOS (`LocationTracker.swift:639`) already emits `Int64(Date().timeIntervalSince1970 * 1000)` for the same event surface. The polyfence-flutter bridge's `_handleGeofenceEvent` validates `eventData['timestamp']` as `int | double` and reports a "Invalid timestamp type: Null" error to consumers when the field is absent. Consumer apps that subscribe to the SDK's error stream saw a red banner per ENTER/EXIT/DWELL on Android, masking real diagnostics. polyfence-react-native parsed the same map but used `Date.now()` silently as a fallback, so the issue was Flutter-visible only — but the platform parity gap was real either way. **Fix:** Android event map now includes `"timestamp" to System.currentTimeMillis()`, matching iOS field name and units (ms since epoch at delegate emission time).

## [1.0.7] - 2026-05-26

### Changed
- **iOS `pausesLocationUpdatesAutomatically` now always `false`** — `SmartGpsConfig.shouldPauseAutomatically()` previously returned `true` for the `balanced`, `batteryOptimal`, and `adaptive` profiles, which let iOS pause CLLocationManager when it considered the device stationary and then suspend the host app. The next time the user crossed a boundary, CLLocationManager arrived at a suspended app (and often at a delegate that had been deallocated) so the ENTER/EXIT/DWELL was dropped. Symptom: iOS RN consumers caught a small fraction of the events that Android RN / Android Flutter / iOS Flutter siblings caught — multi-hour gaps in the Events Log after any stationary period. Geofencing lives or dies on correctness; the slight battery saving from auto-pause was buying app suspension at the cost of every event we exist to deliver. Now always `false` across all accuracy profiles, matching how the Android side stays continuously alive via its foreground service.

### Fixed
- **Multi-zone cold start fired ENTER for only one zone when the user was inside several.** The cached-location reconcile fix above ran exactly once — at the moment `gpsStartDeferred` cleared, which is when the first zone arrived from the bridge. At that instant the engine's zone dict contained just that one zone; the other zones (24 in the QA app, real-world apps often have hundreds) arrived in a burst immediately afterwards but never got their cold-start ENTER because `reconcileZoneStates` did not re-run. The per-tick `checkLocation` path filters by clustering and can exclude a zone the user is inside until it has acquired INSIDE state, which would never happen — so a stationary user was stuck with one ENTER and the rest of their zones silently missing from the state machine. **Fix:** `LocationTracker.addZone` now re-calls `reconcileZoneStates(cachedLocation)` on every zone add when tracking is already running (i.e. for every zone after the first). The fresh-install branch of `reconcileZoneStates` is now idempotent — it reads the previous `zoneStates[zoneId]` value and fires ENTER only on a false → true transition — so repeated calls during the zone-load burst do not emit duplicate ENTERs for zones already marked inside. Applied symmetrically on iOS (`GeofenceEngine.swift` + `LocationTracker.swift`) and Android (`GeofenceEngine.kt` + `LocationTracker.kt`).
- **Clustering: zone INSIDE state was being lost when the cluster set shrank.** When `clusteringEnabled` is true and the user moved beyond the configured `activeRadiusMeters`, the previously-active zone (still marked INSIDE in `zoneStates`) dropped out of `activeZoneIds`, so `getZonesToCheck()` excluded it from evaluation. Result: `checkLocation` never saw the user cross the boundary on the way out → no EXIT event ever fired → stale `zoneStates`, missing notifications, ENTER without a matching EXIT downstream. **Fix:** `getZonesToCheck()` now unions `activeZoneIds` with every zone marked INSIDE in `zoneStates`, so a zone we believe the user is inside is always evaluated regardless of cluster membership. Applied symmetrically on iOS (`GeofenceEngine.swift`) and Android (`GeofenceEngine.kt`).
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
- **Core version self-reporting** — `PolyfenceCoreVersion.kt` and `PolyfenceCoreVersion.swift` stamp engine version into session telemetry via `TelemetryAggregator`. Bridges get `core_version` automatically through existing telemetry spread.

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

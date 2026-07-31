import Foundation
import CoreLocation

/**
 * Registers the top-N-nearest active zones with `CLLocationManager` region
 * monitoring as an OS-managed wake source. The library's own polling engine
 * remains the primary detector — the OS registration only exists so that after
 * full process kill, `locationManager(_:didEnterRegion:)` /
 * `locationManager(_:didExitRegion:)` on `LocationTracker` can wake the app
 * long enough to enqueue the crossing into the pending-events queue for drain
 * on next tracker boot.
 *
 * Off unless `PolyfenceConfig.osGeofenceWakeEnabled` is `true`. When on:
 *  - Selects up to `topN` zones by centroid distance from the last-known fix.
 *    The default `topN = TOP_N_CAP` (20) matches Apple's per-app cap on
 *    `CLCircularRegion` monitoring; a lower value can be supplied via init.
 *  - Registers via `CLLocationManager.startMonitoring(for:)`. CoreLocation
 *    reports only subsequent boundary crossings, so `LocationTracker` pairs
 *    each registration with a `requestState(for:)` call to obtain the
 *    starting state — that is what matches Android's `INITIAL_TRIGGER_ENTER`
 *    for a user already standing inside a zone when monitoring begins.
 *  - Re-registers when the zone set changes (debounced by `debounceMs` to
 *    absorb rapid zone churn) or when the user moves more than
 *    `movementRecalcMeters` from the fix that seeded the current selection.
 *  - Emits `os_geofence_permission_denied` via `onError` (severity warning) and
 *    marks the health field with `registered=0` when `authorizedAlways` is not
 *    granted; the in-process polling engine keeps working unchanged and the
 *    consumer app decides whether to prompt.
 *
 * Every `CLLocationManager` mutation is funnelled onto the main queue by this
 * class — the framework requires it, and the tracker's manager is deliberately
 * constructed on main for the same reason. Internal state is guarded by a
 * private serial queue, which is never held across a main-queue hop.
 */
internal final class OsGeofenceRegistrar {

    /// Apple's per-app cap on simultaneously-monitored `CLCircularRegion` is
    /// 20. Kept as the default `topN` so a consumer that opts in with more
    /// than 20 zones sees the closest 20 covered rather than the OS silently
    /// dropping the entire request. Overridable for tests only.
    static let TOP_N_CAP = 20

    /// Coalesce zone-set churn — a bridge that adds N zones in a tight loop
    /// on startup should produce one re-registration, not N. Window matches
    /// the Android registrar for parity.
    static let DEBOUNCE_MS = 200

    /// Recompute the top-N-nearest set only after the user moves this far
    /// from the fix that seeded the last registration. Below this threshold
    /// the previously-registered set is still the nearest N. Chosen for the
    /// ULEZ / CCZ driving case: at motorway speed this fires roughly every
    /// 40 s, matching cellular-A-GPS re-lock cadence.
    static let MOVEMENT_RECALC_METERS: CLLocationDistance = 1000

    /// Fallback bounding-cover radius for polygon zones. `CLCircularRegion`
    /// only supports circles; the polygon's own containment math still runs
    /// in-engine on drain, so the bounding cover is only a wake trigger.
    static let MIN_POLYGON_COVER_RADIUS_METERS: Double = 100

    /// Region identifier prefix so the registrar's own regions can be
    /// distinguished from any application-side `CLCircularRegion` on the same
    /// manager (`monitoredRegions` contains both).
    static let REGION_ID_PREFIX = "polyfence.os."

    /// Health `lastError` marker for a missing "Always" authorization. Same
    /// wire string as the Android registrar so one consumer branch covers both.
    static let ERROR_BACKGROUND_LOCATION_DENIED = "background_location_denied"

    /// Minimum gap between `os_geofence_permission_denied` reports.
    static let PERMISSION_ERROR_COOLDOWN_SECONDS: TimeInterval = 60

    /// Public health snapshot mirrored into the debug-collector
    /// `systemStatus.osGeofenceRegistrationHealth` map so consumer surfaces
    /// can observe OS-cap hits (`requested > registered`) and permission
    /// drift (`lastError == "background_location_denied"`).
    struct Health {
        let requested: Int
        let registered: Int
        let lastError: String?

        /// `lastError` is always present — NSNull when unset — so a consumer
        /// can branch on its value rather than on key presence, and so the
        /// three-key shape matches the Kotlin registrar exactly.
        func toMap() -> [String: Any] {
            return [
                "requested": requested,
                "registered": registered,
                "lastError": lastError ?? NSNull()
            ]
        }
    }

    private let locationManager: CLLocationManager
    private let topN: Int
    private let debounceMs: Int
    private let movementRecalcMeters: CLLocationDistance
    private let syncQueue = DispatchQueue(label: "io.polyfence.osGeofenceRegistrar")

    private var lastSeed: CLLocation?
    private var pendingWorkItem: DispatchWorkItem?
    private var shutdownRequested = false

    private var currentHealth: Health?
    private var authorizationOverride: CLAuthorizationStatus?
    private var lastPermissionErrorAt: TimeInterval = 0

    init(
        locationManager: CLLocationManager,
        topN: Int = OsGeofenceRegistrar.TOP_N_CAP,
        debounceMs: Int = OsGeofenceRegistrar.DEBOUNCE_MS,
        movementRecalcMeters: CLLocationDistance = OsGeofenceRegistrar.MOVEMENT_RECALC_METERS
    ) {
        self.locationManager = locationManager
        self.topN = topN
        self.debounceMs = debounceMs
        self.movementRecalcMeters = movementRecalcMeters
    }

    /// Test seam: lets a unit test pretend `authorizedAlways` is granted
    /// without provisioning a real `CLLocationManager`, which cannot be
    /// authorized from a headless test process. Do not call from production.
    internal func _setAuthorizationOverrideForTest(_ status: CLAuthorizationStatus) {
        syncQueue.sync { self.authorizationOverride = status }
    }

    /// Snapshot of the last registration attempt as a plain dictionary. `nil`
    /// before the first attempt so callers can distinguish "not yet attempted"
    /// from "attempted, all failed".
    func healthMap() -> [String: Any]? {
        return syncQueue.sync { self.currentHealth?.toMap() }
    }

    /// Ask the OS to re-evaluate the top-N-nearest set. Debounced — repeated
    /// calls within the window coalesce into one registration attempt. Safe
    /// to call from any thread.
    func requestRefresh() {
        syncQueue.async { [weak self] in
            guard let self = self, !self.shutdownRequested else { return }
            self.pendingWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshRegistrationInternal()
            }
            self.pendingWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(self.debounceMs),
                execute: work
            )
        }
    }

    /// Notify the registrar of a fresh location fix. Triggers a recalc only if
    /// the user has moved `movementRecalcMeters` from the fix that seeded the
    /// last registration — below that, the currently registered set is still
    /// the nearest and re-registering would only burn OS quota.
    func onLocationUpdate(_ location: CLLocation) {
        let (seed, alreadyShutdown): (CLLocation?, Bool) = syncQueue.sync {
            (self.lastSeed, self.shutdownRequested)
        }
        if alreadyShutdown { return }
        guard let seedFix = seed else {
            requestRefresh()
            return
        }
        let moved = GeoMath.haversineDistance(
            point1: seedFix.coordinate,
            point2: location.coordinate
        )
        if moved >= movementRecalcMeters {
            requestRefresh()
        }
    }

    /// Remove any currently-registered OS geofences and stop accepting refresh
    /// requests. Safe to call multiple times. Called from
    /// `LocationTracker.stopTracking` and when the consumer flips
    /// `osGeofenceWakeEnabled` back to false.
    func shutdown() {
        syncQueue.sync {
            self.shutdownRequested = true
            self.pendingWorkItem?.cancel()
            self.pendingWorkItem = nil
            self.currentHealth = nil
            self.lastSeed = nil
        }
        // Captures the manager, not self: shutdown() is reachable from
        // LocationTracker.deinit, where a `weak self` would already be nil by
        // the time an async block runs and the regions would leak.
        let manager = locationManager
        runOnMain { OsGeofenceRegistrar.clearStaleRegions(locationManager: manager) }
    }

    /// Removes every region owned by this library from the given manager.
    /// Must run on the main queue — `CLLocationManager` mutation is
    /// main-thread-only, which is also why the tracker constructs its manager
    /// there. iOS keeps monitored regions across app launches, so a consumer
    /// that turns the flag off would otherwise keep being woken by fences from
    /// the session where it was on, with no live registrar able to remove them.
    static func clearStaleRegions(locationManager: CLLocationManager) {
        let stale = locationManager.monitoredRegions.filter {
            $0.identifier.hasPrefix(REGION_ID_PREFIX)
        }
        for region in stale {
            locationManager.stopMonitoring(for: region)
        }
    }

    /// Test seam that bypasses the debounce timer and invokes the registration
    /// pipeline synchronously against the supplied zones + fix.
    internal func refreshNowForTest(zones: [Zone], seed: CLLocation?) {
        applyRegistration(zones: zones, seed: seed)
    }

    // MARK: - Selection (pure, testable)

    struct Candidate {
        let zoneId: String
        let centerLat: Double
        let centerLng: Double
        let radiusMeters: Double
        let distanceMeters: Double

        /// `maxRadius` is `CLLocationManager.maximumRegionMonitoringDistance`.
        /// CoreLocation silently declines to monitor a region larger than that,
        /// so a city-scale polygon's bounding cover must be clamped down rather
        /// than handed over and counted as registered.
        func toRegion(maxRadius: CLLocationDistance = .greatestFiniteMagnitude) -> CLCircularRegion {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
                radius: min(radiusMeters, maxRadius),
                identifier: OsGeofenceRegistrar.REGION_ID_PREFIX + zoneId
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            return region
        }
    }

    internal static func selectTopNNearest(
        zones: [Zone],
        seed: CLLocation?,
        topN: Int
    ) -> [Candidate] {
        if zones.isEmpty || topN <= 0 { return [] }
        let mapped: [Candidate] = zones.compactMap { zone in
            guard let center = candidateCenter(zone),
                  let radius = candidateRadius(zone) else { return nil }
            let distance: Double
            if let seed = seed {
                distance = GeoMath.haversineDistance(
                    point1: seed.coordinate,
                    point2: CLLocationCoordinate2D(latitude: center.0, longitude: center.1)
                )
            } else {
                distance = 0
            }
            return Candidate(
                zoneId: zone.id,
                centerLat: center.0,
                centerLng: center.1,
                radiusMeters: radius,
                distanceMeters: distance
            )
        }
        if seed == nil { return Array(mapped.prefix(topN)) }
        return Array(mapped.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(topN))
    }

    private static func candidateCenter(_ zone: Zone) -> (Double, Double)? {
        if let center = zone.center {
            return (center.latitude, center.longitude)
        }
        if zone.points.isEmpty { return nil }
        let lat = zone.points.reduce(0.0) { $0 + $1.latitude } / Double(zone.points.count)
        let lng = zone.points.reduce(0.0) { $0 + $1.longitude } / Double(zone.points.count)
        return (lat, lng)
    }

    private static func candidateRadius(_ zone: Zone) -> Double? {
        if let radius = zone.radius { return max(radius, 1.0) }
        if zone.points.isEmpty { return nil }
        guard let center = candidateCenter(zone) else { return nil }
        let cLat = center.0
        let cLng = center.1
        let maxDist = zone.points
            .map { GeoMath.haversineDistance(lat1: cLat, lng1: cLng, lat2: $0.latitude, lng2: $0.longitude) }
            .max() ?? 0
        return max(maxDist, MIN_POLYGON_COVER_RADIUS_METERS)
    }

    // MARK: - Registration (main-queue)

    private func refreshRegistrationInternal() {
        if syncQueue.sync(execute: { self.shutdownRequested }) { return }
        guard let tracker = LocationTracker.currentInstanceForOsGeofence else { return }
        let zones = tracker.geofenceEngineForOsGeofence.getCurrentZones()
        // The freshest fix wins over the stored anchor. Reading the anchor
        // first would pin selection to wherever the first registration
        // happened: every later fix would then measure its distance from that
        // frozen point, so past the recalc threshold every fix looks like
        // "moved far enough" while the registered set never actually advances.
        let seedForApply = tracker.lastKnownLocationForOsGeofence
            ?? syncQueue.sync { self.lastSeed }
        applyRegistration(zones: zones, seed: seedForApply)
    }

    private func applyRegistration(zones: [Zone], seed: CLLocation?) {
        // Advance the movement anchor on every ATTEMPT, not only on success.
        // Anchoring on success alone leaves it nil whenever registration keeps
        // failing (permission denied, no zones), and a nil anchor makes
        // onLocationUpdate treat every fix as "moved far enough" — one retry
        // and one onError per GPS fix, forever.
        syncQueue.sync { self.lastSeed = seed }

        let candidates = OsGeofenceRegistrar.selectTopNNearest(
            zones: zones, seed: seed, topN: topN
        )
        if !isAlwaysAuthorized() {
            reportPermissionDenied(requested: zones.count)
            return
        }

        runOnMain { [weak self] in
            guard let self = self else { return }
            // Re-check under the same main-queue hop that performs the
            // registration: a shutdown that landed while this work item was
            // queued would otherwise remove the fences and then have them
            // immediately re-armed by this block, orphaning regions that
            // outlive the registrar (iOS keeps monitored regions across
            // launches, so nothing could ever remove them again).
            if self.syncQueue.sync(execute: { self.shutdownRequested }) { return }

            OsGeofenceRegistrar.clearStaleRegions(locationManager: self.locationManager)

            if candidates.isEmpty {
                self.syncQueue.sync {
                    self.currentHealth = Health(requested: zones.count, registered: 0, lastError: nil)
                }
                return
            }

            let maxRadius = self.locationManager.maximumRegionMonitoringDistance
            var registered = 0
            for candidate in candidates {
                self.locationManager.startMonitoring(for: candidate.toRegion(maxRadius: maxRadius))
                registered += 1
            }
            self.syncQueue.sync {
                self.currentHealth = Health(
                    requested: zones.count,
                    registered: registered,
                    lastError: nil
                )
            }
        }
    }

    /// Records an OS-side rejection reported via
    /// `locationManager(_:monitoringDidFailFor:withError:)`. Without this,
    /// `registered` would count regions handed to CoreLocation rather than
    /// regions CoreLocation accepted, and the health field would read as full
    /// coverage while nothing was actually being monitored.
    func recordMonitoringFailure(region: CLRegion?, error: Error) {
        guard region == nil
            || region!.identifier.hasPrefix(OsGeofenceRegistrar.REGION_ID_PREFIX) else { return }
        syncQueue.sync {
            guard let current = self.currentHealth else { return }
            self.currentHealth = Health(
                requested: current.requested,
                registered: max(0, current.registered - 1),
                lastError: error.localizedDescription
            )
        }
    }

    /// Runs `block` on the main queue, inline when already there.
    ///
    /// Deliberately `async` rather than `sync` off-main: `shutdown()` is
    /// reachable from `LocationTracker.deinit`, which can run on any thread,
    /// and a blocking hop from a deallocating object onto a main queue that
    /// may itself be waiting on that thread would deadlock. Ordering is still
    /// guaranteed — each registration pass is a single work item, and work
    /// items run on main in submission order.
    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func reportPermissionDenied(requested: Int) {
        syncQueue.sync {
            self.currentHealth = Health(
                requested: requested,
                registered: 0,
                lastError: OsGeofenceRegistrar.ERROR_BACKGROUND_LOCATION_DENIED
            )
        }
        // Rate-limited: the registrar retries on zone changes and on movement,
        // so an un-throttled report would push one onError per GPS fix for as
        // long as the grant is missing, evicting every genuine entry from the
        // consumer's bounded error history.
        let shouldReport: Bool = syncQueue.sync {
            let now = Date().timeIntervalSince1970
            guard now - self.lastPermissionErrorAt >= OsGeofenceRegistrar.PERMISSION_ERROR_COOLDOWN_SECONDS
            else { return false }
            self.lastPermissionErrorAt = now
            return true
        }
        guard shouldReport else { return }

        PolyfenceErrorManager.shared.reportError(
            type: "os_geofence_permission_denied",
            message: "\"Always\" location authorization not granted — OS wake fences unavailable",
            context: [
                "severity": "warning",
                "platform": "ios",
                "requested": requested
            ]
        )
    }

    private func isAlwaysAuthorized() -> Bool {
        let override = syncQueue.sync { self.authorizationOverride }
        let status: CLAuthorizationStatus
        if let override = override {
            status = override
        } else if #available(iOS 14.0, *) {
            status = locationManager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        return status == .authorizedAlways
    }
}

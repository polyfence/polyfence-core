package io.polyfence.core

import android.location.Location
import android.util.Log
import io.polyfence.core.utils.GeoMath
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.*
import kotlin.math.abs

/**
 * Core geofencing detection engine
 * Single responsibility: GPS location → zone detection → events
 */
class GeofenceEngine {
    companion object {
        private const val TAG = "GeofenceEngine"

        // State recovery event types
        const val EVENT_RECOVERY_ENTER = "RECOVERY_ENTER"
        const val EVENT_RECOVERY_EXIT = "RECOVERY_EXIT"

        // Dwell event type
        const val EVENT_DWELL = "DWELL"

        // Default dwell threshold (5 minutes)
        const val DEFAULT_DWELL_THRESHOLD_MS = 300000L

        /**
         * Check if polygon is self-intersecting using O(n²) edge intersection test.
         * Used from [ZoneData.fromMap]; must live in companion so nested class can call it.
         * Internal: nested [ZoneData] cannot call companion private members in Kotlin.
         */
        internal fun isPolygonSelfIntersecting(points: List<LatLng>): Boolean {
            if (points.size < 4) return false

            for (i in 0 until points.size - 1) {
                for (j in i + 2 until points.size) {
                    if (i == 0 && j == points.size - 1) continue

                    if (segmentsIntersect(
                            points[i], points[i + 1],
                            points[j], points[(j + 1) % points.size]
                        )) {
                        return true
                    }
                }
            }
            return false
        }

        private fun segmentsIntersect(a1: LatLng, a2: LatLng, b1: LatLng, b2: LatLng): Boolean {
            val d1 = cross(b2.longitude - b1.longitude, b2.latitude - b1.latitude,
                a1.longitude - b1.longitude, a1.latitude - b1.latitude)
            val d2 = cross(b2.longitude - b1.longitude, b2.latitude - b1.latitude,
                a2.longitude - b1.longitude, a2.latitude - b1.latitude)
            val d3 = cross(a2.longitude - a1.longitude, a2.latitude - a1.latitude,
                b1.longitude - a1.longitude, b1.latitude - a1.latitude)
            val d4 = cross(a2.longitude - a1.longitude, a2.latitude - a1.latitude,
                b2.longitude - a1.longitude, b2.latitude - a1.latitude)

            if (sign(d1) != sign(d2) && sign(d3) != sign(d4)) {
                return true
            }
            return false
        }

        private fun cross(ux: Double, uy: Double, vx: Double, vy: Double): Double {
            return ux * vy - uy * vx
        }

        private fun sign(value: Double): Int {
            return when {
                value > 0 -> 1
                value < 0 -> -1
                else -> 0
            }
        }

        internal fun checkPoleWarning(points: List<LatLng>) {
            val polesNear = points.any { abs(it.latitude) > 85.0 }
            if (polesNear) {
                Log.w(TAG, "Polygon zone contains vertices near poles (lat > ±85°) - accuracy will be reduced near poles due to geomagnetic field distortions")
            }
        }
    }

    // Thread-safe zone storage
    private val zones = ConcurrentHashMap<String, ZoneData>()
    private val zoneStates = ConcurrentHashMap<String, Boolean>()

    // Confidence tracking for zone state validation
    private val zoneConfidence = ConcurrentHashMap<String, ZoneConfidence>()

    // Dwell time tracking: zoneId -> entry timestamp (ms)
    private val zoneEntryTimes = ConcurrentHashMap<String, Long>()
    // Track which zones have already fired dwell events this session
    private val dwellEventsFired = ConcurrentHashMap<String, Boolean>()
    // Dwell threshold in milliseconds (configurable)
    private var dwellThresholdMs = DEFAULT_DWELL_THRESHOLD_MS
    // Whether dwell detection is enabled
    private var dwellEnabled = true

    // Configuration for validation
    private var requireConfirmation = true
    private var confirmationPoints = 2
    private var confirmationTimeoutMs = 10000L // 10 seconds

    // Accuracy-aware confirmation thresholds
    private val GOOD_ACCURACY_THRESHOLD = 35.0  // meters - normal confirmation
    private val POOR_ACCURACY_THRESHOLD = 75.0  // meters - stricter confirmation
    private val POOR_ACCURACY_CONFIRMATION_POINTS = 3
    private val POOR_ACCURACY_TIMEOUT_MS = 25_000L  // 25 seconds

    // Boundary hysteresis margin in meters
    private val HYSTERESIS_MARGIN = 20.0

    // GPS accuracy threshold in meters (default: 100m for platform parity)
    private var gpsAccuracyThreshold = 100.0f

    // Zone clustering configuration
    private var clusteringEnabled = false
    private var clusterActiveRadiusMeters = 5000.0
    private var clusterRefreshDistanceMeters = 1000.0
    private var clusterCenterLat: Double? = null
    private var clusterCenterLng: Double? = null
    private val activeZoneIds = ConcurrentHashMap.newKeySet<String>()

    // Event callback - includes detection time in milliseconds
    private var eventCallback: ((String, String, Location, Double) -> Unit)? = null

    // False event detection: track last event per zone for reversal detection
    private val lastEventPerZone = ConcurrentHashMap<String, Pair<String, Long>>() // zoneId -> (eventType, timestamp)
    private val lastEventWasQuickReversal = ConcurrentHashMap<String, Boolean>()
    private var falseEventCount = 0

    // Zone state persistence (injected by LocationTracker)
    private var zonePersistence: ZonePersistence? = null

    // Track if state was recovered from persistence on startup
    private var stateRecoveredFromPersistence = false


    /**
     * Zone confidence tracking
     */
    private data class ZoneConfidence(
        var insideCount: Int = 0,
        var outsideCount: Int = 0,
        var lastDetection: Long = 0L,
        var confirmedState: Boolean = false
    )

    /**
     * Add zone for monitoring using typed configuration
     */
    fun addZone(config: ZoneConfig) {
        @Suppress("DEPRECATION")
        addZone(config.id, config.name, config.toMap())
    }

    /**
     * Add zone for monitoring from a raw map.
     * Prefer [addZone(ZoneConfig)] for type safety.
     */
    @Deprecated(
        message = "Use addZone(ZoneConfig) for type safety",
        replaceWith = ReplaceWith("addZone(ZoneConfig.circle(...)) or addZone(ZoneConfig.polygon(...))")
    )
    fun addZone(zoneId: String, zoneName: String, zoneData: Map<String, Any>) {
        try {
            val zone = ZoneData.fromMap(zoneId, zoneName, zoneData)
            zones[zoneId] = zone
            zoneStates[zoneId] = false // Initially outside
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add zone $zoneId: ${e.message}")
            throw IllegalArgumentException("Invalid zone data for $zoneId", e)
        }
    }

    /**
     * Remove zone from monitoring
     */
    fun removeZone(zoneId: String) {
        zones.remove(zoneId)
        zoneStates.remove(zoneId)
        zoneConfidence.remove(zoneId)
        zoneEntryTimes.remove(zoneId)
        dwellEventsFired.remove(zoneId)

        // Remove persisted state
        zonePersistence?.removeZoneState(zoneId)
    }

    /**
     * Clear all zones
     */
    fun clearAllZones() {
        zones.clear()
        zoneStates.clear()
        zoneConfidence.clear()
        zoneEntryTimes.clear()
        dwellEventsFired.clear()

        // Clear persisted states
        zonePersistence?.clearAllZoneStates()
    }

    /**
 * Get zone name by ID
 */
fun getZoneName(zoneId: String): String? {
    return zones[zoneId]?.name
}

    /**
     * Enhanced configuration method
     */
    fun setValidationConfig(requireConfirmation: Boolean, confirmationPoints: Int = 2, timeoutMs: Long = 10000L) {
        this.requireConfirmation = requireConfirmation
        this.confirmationPoints = confirmationPoints
        this.confirmationTimeoutMs = timeoutMs
    }

    /**
     * Set GPS accuracy threshold in meters
     * Locations with accuracy worse than this are rejected
     * Default: 100m (matches iOS for platform parity)
     */
    fun setGpsAccuracyThreshold(threshold: Float) {
        this.gpsAccuracyThreshold = threshold
    }

    /**
     * Configure dwell detection
     * @param enabled Whether dwell detection is enabled
     * @param thresholdMs How long (ms) device must stay in zone before DWELL fires
     */
    fun setDwellConfig(enabled: Boolean, thresholdMs: Long = DEFAULT_DWELL_THRESHOLD_MS) {
        this.dwellEnabled = enabled
        this.dwellThresholdMs = thresholdMs
        Log.d(TAG, "Dwell config: enabled=$enabled, threshold=${thresholdMs}ms")
    }

    /**
     * Configure zone clustering for large zone sets
     * @param enabled Whether clustering is enabled (default: false)
     * @param activeRadiusMeters Radius to check zones within (default: 5000m)
     * @param refreshDistanceMeters Distance to move before refreshing active cluster (default: 1000m)
     */
    fun setClusterConfig(enabled: Boolean, activeRadiusMeters: Double = 5000.0, refreshDistanceMeters: Double = 1000.0) {
        this.clusteringEnabled = enabled
        this.clusterActiveRadiusMeters = activeRadiusMeters
        this.clusterRefreshDistanceMeters = refreshDistanceMeters
        // Reset cluster center to force refresh on next location update
        this.clusterCenterLat = null
        this.clusterCenterLng = null
        this.activeZoneIds.clear()
        Log.d(TAG, "Cluster config: enabled=$enabled, activeRadius=${activeRadiusMeters}m, refreshDistance=${refreshDistanceMeters}m")
    }

    /**
     * Check if cluster needs to be refreshed based on movement from cluster center
     */
    private fun shouldRefreshCluster(location: Location): Boolean {
        val centerLat = clusterCenterLat ?: return true
        val centerLng = clusterCenterLng ?: return true

        val distance = GeoMath.haversineDistance(centerLat, centerLng, location.latitude, location.longitude)
        return distance >= clusterRefreshDistanceMeters
    }

    /**
     * Refresh the active zone cluster around the given location
     */
    private fun refreshCluster(location: Location) {
        clusterCenterLat = location.latitude
        clusterCenterLng = location.longitude
        activeZoneIds.clear()

        val activatedZonesList = mutableListOf<String>()

        zones.forEach { (zoneId, zone) ->
            val zoneCenter = zone.calculateCenter()
            val distance = GeoMath.haversineDistance(location.latitude, location.longitude, zoneCenter.latitude, zoneCenter.longitude)

            // Include zone if its center is within active radius
            // Also include zones whose boundary might intersect (add zone radius buffer)
            val effectiveRadius = clusterActiveRadiusMeters + (zone.radius ?: 0.0)
            if (distance <= effectiveRadius) {
                activeZoneIds.add(zoneId)
                activatedZonesList.add(zone.name.ifEmpty { zoneId })
            }
        }

        Log.d(TAG, "Cluster refreshed at (${location.latitude}, ${location.longitude}): ${activatedZonesList.size} of ${zones.size} zones active - [${activatedZonesList.joinToString(", ")}]")
    }

    /**
     * Get zones to check based on clustering configuration
     */
    private fun getZonesToCheck(): Map<String, ZoneData> {
        return if (clusteringEnabled && activeZoneIds.isNotEmpty()) {
            zones.filterKeys { it in activeZoneIds }
        } else {
            zones
        }
    }

    /**
     * Update GPS accuracy threshold
     */
    fun setAccuracyThreshold(threshold: Float) {
        // GPS accuracy threshold implementation
    }

    /**
     * Set callback for zone events
     * Callback receives: zoneId, eventType, location, detectionTimeMs
     */
    fun setEventCallback(callback: (String, String, Location, Double) -> Unit) {
        eventCallback = callback
    }

    /**
     * Set zone persistence for state recovery across service restarts
     */
    fun setZonePersistence(persistence: ZonePersistence) {
        this.zonePersistence = persistence
    }

    /**
     * Load persisted zone states on service restart
     * Should be called after zones are loaded but before location updates start
     */
    fun loadPersistedZoneStates() {
        val persistence = zonePersistence ?: return

        if (!persistence.hasPersistedZoneStates()) {
            Log.d(TAG, "No persisted zone states found (fresh install or data wipe)")
            stateRecoveredFromPersistence = false
            return
        }

        val persistedStates = persistence.loadZoneStates()
        if (persistedStates.isEmpty()) {
            Log.d(TAG, "Persisted zone states empty")
            stateRecoveredFromPersistence = false
            return
        }

        // Only load states for zones that are currently registered
        var loadedCount = 0
        persistedStates.forEach { (zoneId, isInside) ->
            if (zones.containsKey(zoneId)) {
                zoneStates[zoneId] = isInside
                loadedCount++
                Log.d(TAG, "Restored state for zone $zoneId: ${if (isInside) "INSIDE" else "OUTSIDE"}")
            }
        }

        stateRecoveredFromPersistence = loadedCount > 0
        Log.i(TAG, "Loaded $loadedCount persisted zone states (${persistedStates.count { it.value }} were inside)")
    }

    /**
     * Reconcile zone states with current location after service restart
     * Fires RECOVERY_ENTER/RECOVERY_EXIT events for mismatches
     * Should be called with first valid location after restart
     */
    fun reconcileZoneStates(location: Location) {
        if (!stateRecoveredFromPersistence) {
            // No persisted state - establish initial state and fire ENTER events for zones we're inside
            Log.d(TAG, "No persisted state - establishing initial state from current location")
            val checkStartTime = System.nanoTime()
            zones.forEach { (zoneId, zone) ->
                val isInside = zone.contains(location)
                zoneStates[zoneId] = isInside

                // Fire ENTER event for zones we're currently inside (fresh install behavior)
                if (isInside) {
                    val detectionTimeMs = (System.nanoTime() - checkStartTime) / 1_000_000.0
                    Log.i(TAG, "Initial state: inside zone $zoneId -> firing ENTER")
                    eventCallback?.invoke(zoneId, "ENTER", location, detectionTimeMs)
                }
            }
            persistAllZoneStates()
            return
        }

        Log.i(TAG, "Reconciling zone states with current location...")
        val checkStartTime = System.nanoTime()
        var reconciliationCount = 0

        zones.forEach { (zoneId, zone) ->
            val persistedState = zoneStates[zoneId] ?: false
            val actualState = zone.contains(location)

            if (persistedState != actualState) {
                reconciliationCount++
                zoneStates[zoneId] = actualState

                val detectionTimeMs = (System.nanoTime() - checkStartTime) / 1_000_000.0

                if (actualState) {
                    // Was outside (persisted), now inside (actual) -> fire RECOVERY_ENTER
                    Log.w(TAG, "State mismatch for zone $zoneId: was OUTSIDE, now INSIDE -> firing RECOVERY_ENTER")
                    eventCallback?.invoke(zoneId, EVENT_RECOVERY_ENTER, location, detectionTimeMs)
                } else {
                    // Was inside (persisted), now outside (actual) -> fire RECOVERY_EXIT
                    Log.w(TAG, "State mismatch for zone $zoneId: was INSIDE, now OUTSIDE -> firing RECOVERY_EXIT")
                    eventCallback?.invoke(zoneId, EVENT_RECOVERY_EXIT, location, detectionTimeMs)
                }
            }
        }

        if (reconciliationCount > 0) {
            Log.i(TAG, "Reconciled $reconciliationCount zone state mismatches")
            persistAllZoneStates()
        } else {
            Log.d(TAG, "All zone states match current location - no reconciliation needed")
        }

        stateRecoveredFromPersistence = false // Reset flag after reconciliation
    }

    /**
     * Persist all current zone states (called after reconciliation or bulk changes)
     */
    private fun persistAllZoneStates() {
        val persistence = zonePersistence ?: return
        persistence.saveZoneStates(zoneStates.toMap())
    }

    /**
     * Persist single zone state change (called on each transition)
     */
    private fun persistZoneState(zoneId: String, isInside: Boolean) {
        val persistence = zonePersistence ?: return
        persistence.saveZoneState(zoneId, isInside)
    }

    /**
     * Get current zone states for health check API
     */
    fun getCurrentZoneStates(): Map<String, Boolean> {
        return zoneStates.toMap()
    }

    /**
     * Check if state was recovered from persistence on last startup
     */
    fun wasStateRecoveredFromPersistence(): Boolean {
        return stateRecoveredFromPersistence
    }



    /**
     * Enhanced check location with precise timing
     */
    fun checkLocation(location: Location) {
        if (!isValidLocation(location)) {
            return
        }

        // Handle clustering: refresh active zones if needed
        if (clusteringEnabled) {
            if (shouldRefreshCluster(location)) {
                refreshCluster(location)
            }
        }

        val overallStartTime = System.nanoTime()
        val speed = if (location.hasSpeed()) location.speed * 3.6 else 0.0 // Convert m/s to km/h
        val accuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0

        var zoneCheckCount = 0
        var totalAlgorithmTime = 0L
        var totalConfidenceTime = 0L

        // Use clustered zones if enabled, otherwise all zones
        val zonesToCheck = getZonesToCheck()

        zonesToCheck.forEach { (zoneId, zone) ->
            zoneCheckCount++
            val zoneCheckStartTime = System.nanoTime() // Start timing for this zone
            val currentState = zoneStates[zoneId] ?: false

            // Precise algorithm timing — apply hysteresis when transitioning
            val algorithmStartTime = System.nanoTime()
            val isInside = zone.containsWithHysteresis(location, currentState)
            val algorithmDuration = System.nanoTime() - algorithmStartTime
            totalAlgorithmTime += algorithmDuration

            // Smart validation: Use confirmation based on speed, zone, and accuracy
            val useConfirmation = if (requireConfirmation) {
                shouldUseConfirmation(speed, zone.radius, accuracy)
            } else {
                false
            }

            val stateChanged: Boolean
            if (useConfirmation) {
                val confidenceStartTime = System.nanoTime()
                stateChanged = processWithConfidence(zoneId, zone, isInside, currentState, System.currentTimeMillis(), location, zoneCheckStartTime)
                val confidenceDuration = System.nanoTime() - confidenceStartTime
                totalConfidenceTime += confidenceDuration
            } else {
                // Original logic for immediate detection
                stateChanged = processImmediate(zoneId, zone, isInside, currentState, location, zoneCheckStartTime)
            }

        }

    }

    // Smart validation: Single point for obvious cases, multi-point for edge cases
    fun shouldUseConfirmation(speed: Double, zoneRadius: Double?, accuracy: Double = 0.0): Boolean {
        return when {
            // Poor GPS accuracy always needs confirmation (prevent flapping)
            accuracy > POOR_ACCURACY_THRESHOLD -> true

            // Large zones always need confirmation (reduce false positives)
            zoneRadius != null && zoneRadius > 200 -> true

            // High speed + reasonable zones + good accuracy = single point OK
            speed > 40 && (zoneRadius == null || zoneRadius > 50) && accuracy <= GOOD_ACCURACY_THRESHOLD -> false

            // Default: Use 2-point for reliability
            else -> true
        }
    }

    /**
     * Process with confidence validation - returns true if state changed
     */
    private fun processWithConfidence(
        zoneId: String,
        zone: ZoneData,
        isInside: Boolean,
        currentState: Boolean,
        currentTime: Long,
        location: Location,
        checkStartTime: Long
    ): Boolean {
        val confidence = zoneConfidence.getOrPut(zoneId) { ZoneConfidence() }
        val accuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0

        // Update confidence counters
        if (isInside) {
            confidence.insideCount++
            confidence.outsideCount = 0
        } else {
            confidence.outsideCount++
            confidence.insideCount = 0
        }

        confidence.lastDetection = currentTime

        // Accuracy-aware: require more confirmation points when GPS is poor
        val requiredCount = if (accuracy > POOR_ACCURACY_THRESHOLD) {
            POOR_ACCURACY_CONFIRMATION_POINTS
        } else {
            confirmationPoints
        }
        val hasConfidence = if (isInside) {
            confidence.insideCount >= requiredCount
        } else {
            confidence.outsideCount >= requiredCount
        }

        // State change with confidence
        if (hasConfidence && currentState != isInside) {
            zoneStates[zoneId] = isInside
            confidence.confirmedState = isInside

            // Persist state change immediately (write-through)
            persistZoneState(zoneId, isInside)

            // Calculate detection time: from start of zone check to now (in milliseconds)
            val detectionTimeMs = (System.nanoTime() - checkStartTime) / 1_000_000.0

            val eventType = if (isInside) "ENTER" else "EXIT"
            trackEventTelemetry(zoneId, eventType)
            eventCallback?.invoke(zoneId, eventType, location, detectionTimeMs)

            // Handle dwell tracking on state change
            handleDwellStateChange(zoneId, isInside, location, checkStartTime)

            // Reset confidence after successful event
            confidence.insideCount = 0
            confidence.outsideCount = 0

            return true // State changed
        }

        // Timeout: reset confidence if no consistent readings (longer timeout for poor accuracy)
        val activeTimeout = if (accuracy > POOR_ACCURACY_THRESHOLD) {
            POOR_ACCURACY_TIMEOUT_MS
        } else {
            confirmationTimeoutMs
        }
        if (currentTime - confidence.lastDetection > activeTimeout) {
            confidence.insideCount = 0
            confidence.outsideCount = 0
        }

        // Check for dwell even if no state change (still inside)
        if (currentState && isInside && dwellEnabled) {
            checkAndFireDwell(zoneId, location, checkStartTime)
        }

        return false // No state change
    }

    /**
     * Original immediate processing - returns true if state changed
     */
    private fun processImmediate(
        zoneId: String,
        zone: ZoneData,
        isInside: Boolean,
        currentState: Boolean,
        location: Location,
        checkStartTime: Long
    ): Boolean {
        if (currentState != isInside) {
            zoneStates[zoneId] = isInside

            // Persist state change immediately (write-through)
            persistZoneState(zoneId, isInside)

            // Calculate detection time: from start of zone check to now (in milliseconds)
            val detectionTimeMs = (System.nanoTime() - checkStartTime) / 1_000_000.0

            val eventType = if (isInside) "ENTER" else "EXIT"
            trackEventTelemetry(zoneId, eventType)
            eventCallback?.invoke(zoneId, eventType, location, detectionTimeMs)

            // Handle dwell tracking on state change
            handleDwellStateChange(zoneId, isInside, location, checkStartTime)

            return true // State changed
        } else if (isInside && dwellEnabled) {
            // Still inside - check for dwell
            checkAndFireDwell(zoneId, location, checkStartTime)
        }
        return false // No state change
    }

    /**
     * Track zone transitions for false-event / reversal detection (parity with iOS).
     */
    private fun trackEventTelemetry(zoneId: String, eventType: String) {
        val now = System.currentTimeMillis()
        var quickReversal = false
        lastEventPerZone[zoneId]?.let { (lastType, lastTime) ->
            val timeSince = now - lastTime
            if (timeSince <= 30_000L && lastType != eventType) {
                falseEventCount++
                quickReversal = true
            }
        }
        lastEventPerZone[zoneId] = Pair(eventType, now)
        lastEventWasQuickReversal[zoneId] = quickReversal
    }

    // --- ML Telemetry: false event detection (for external use only) ---

    /**
     * Whether the most recently emitted event for this zone was a quick opposite transition
     * (e.g. EXIT within 30s of ENTER). Call after the event has been processed.
     */
    fun isRecentReversal(zoneId: String, eventType: String): Boolean {
        val lastEvent = lastEventPerZone[zoneId] ?: return false
        if (lastEvent.first != eventType) return false
        return lastEventWasQuickReversal[zoneId] == true
    }

    /**
     * Handle dwell tracking when zone state changes
     */
    private fun handleDwellStateChange(zoneId: String, isInside: Boolean, location: Location, checkStartTime: Long) {
        if (!dwellEnabled) return

        if (isInside) {
            // Entered zone - start tracking dwell time
            zoneEntryTimes[zoneId] = System.currentTimeMillis()
            dwellEventsFired.remove(zoneId) // Reset dwell flag for new entry
            Log.d(TAG, "Dwell tracking started for zone $zoneId")
        } else {
            // Exited zone - stop tracking dwell time
            zoneEntryTimes.remove(zoneId)
            dwellEventsFired.remove(zoneId)
            Log.d(TAG, "Dwell tracking stopped for zone $zoneId")
        }
    }

    /**
     * Check if dwell threshold reached and fire DWELL event
     */
    private fun checkAndFireDwell(zoneId: String, location: Location, checkStartTime: Long) {
        // Skip if dwell already fired for this zone entry
        if (dwellEventsFired[zoneId] == true) return

        val entryTime = zoneEntryTimes[zoneId] ?: return
        val dwellDuration = System.currentTimeMillis() - entryTime

        if (dwellDuration >= dwellThresholdMs) {
            // Mark as fired to prevent duplicate events
            dwellEventsFired[zoneId] = true

            val detectionTimeMs = (System.nanoTime() - checkStartTime) / 1_000_000.0

            Log.i(TAG, "DWELL event for zone $zoneId after ${dwellDuration}ms")
            eventCallback?.invoke(zoneId, EVENT_DWELL, location, detectionTimeMs)
        }
    }

    /**
     * Validate GPS location
     * Uses configurable GPS accuracy threshold (default: 100m)
     * This ensures platform parity with iOS
     */
    private fun isValidLocation(location: Location): Boolean {
        return location.hasAccuracy() &&
               location.accuracy <= gpsAccuracyThreshold &&
               location.latitude != 0.0 &&
               location.longitude != 0.0
    }

    /**
     * Zone data container
     */
    private data class ZoneData(
        val id: String,
        val name: String,
        val type: ZoneType,
        val center: LatLng? = null,
        val radius: Double? = null,
        val polygon: List<LatLng>? = null
    ) {

        fun contains(location: Location): Boolean {
            return when (type) {
                ZoneType.CIRCLE -> {
                    val zoneCenter = center ?: return false
                    val zoneRadius = radius ?: return false
                    val distance = GeoMath.haversineDistance(location.latitude, location.longitude, zoneCenter.latitude, zoneCenter.longitude)
                    distance <= zoneRadius
                }
                ZoneType.POLYGON -> {
                    val zonePolygon = polygon ?: return false
                    GeoMath.isPointInPolygon(location.latitude, location.longitude, zonePolygon.map { Pair(it.latitude, it.longitude) })
                }
            }
        }

        /**
         * Hysteresis-aware containment check.
         * To transition INTO a zone, the point must be at least [margin] meters inside the boundary.
         * To transition OUT of a zone, the point must be at least [margin] meters outside the boundary.
         * This creates a deadband around the boundary that prevents GPS jitter from causing flapping.
         * When [currentState] matches the raw containment, returns the current state (no change).
         */
        fun containsWithHysteresis(location: Location, currentState: Boolean, margin: Double = 20.0): Boolean {
            return when (type) {
                ZoneType.CIRCLE -> {
                    val zoneCenter = center ?: return false
                    val zoneRadius = radius ?: return false
                    val distance = GeoMath.haversineDistance(location.latitude, location.longitude, zoneCenter.latitude, zoneCenter.longitude)
                    // Clamp effective margin so it never exceeds the zone radius
                    // (prevents negative effective radius for very small/zero-radius zones)
                    val effectiveMargin = margin.coerceAtMost(zoneRadius)
                    if (currentState) {
                        // Currently inside: must be margin meters OUTSIDE boundary to exit
                        distance <= zoneRadius + effectiveMargin
                    } else {
                        // Currently outside: must be margin meters INSIDE boundary to enter
                        distance <= zoneRadius - effectiveMargin
                    }
                }
                ZoneType.POLYGON -> {
                    val zonePolygon = polygon ?: return false
                    val rawInside = GeoMath.isPointInPolygon(location.latitude, location.longitude, zonePolygon.map { Pair(it.latitude, it.longitude) })
                    // For polygons, use point-to-boundary distance for hysteresis
                    val distToBoundary = GeoMath.pointToPolygonDistance(location.latitude, location.longitude, zonePolygon.map { Pair(it.latitude, it.longitude) })
                    if (distToBoundary < margin) {
                        // Within the deadband — maintain current state
                        currentState
                    } else {
                        rawInside
                    }
                }
            }
        }

        /**
         * Calculate the center point of this zone for clustering calculations
         * For circles: returns center
         * For polygons: returns centroid (average of all points)
         */
        fun calculateCenter(): LatLng {
            return when (type) {
                ZoneType.CIRCLE -> center ?: LatLng(0.0, 0.0)
                ZoneType.POLYGON -> {
                    val points = polygon ?: return LatLng(0.0, 0.0)
                    if (points.isEmpty()) return LatLng(0.0, 0.0)
                    val avgLat = points.sumOf { it.latitude } / points.size
                    val avgLng = points.sumOf { it.longitude } / points.size
                    LatLng(avgLat, avgLng)
                }
            }
        }


        companion object {
            fun fromMap(id: String, name: String, data: Map<String, Any>): ZoneData {
                val type = when (data["type"] as? String) {
                    "circle" -> ZoneType.CIRCLE
                    "polygon" -> ZoneType.POLYGON
                    else -> throw IllegalArgumentException("Invalid zone type")
                }

                return when (type) {
                    ZoneType.CIRCLE -> {
                        val center = data["center"] as? Map<*, *>
                            ?: throw IllegalArgumentException("Circle zone missing center")
                        val lat = (center["latitude"] as? Number)?.toDouble()
                            ?: throw IllegalArgumentException("Circle center missing latitude")
                        val lng = (center["longitude"] as? Number)?.toDouble()
                            ?: throw IllegalArgumentException("Circle center missing longitude")
                        val radius = (data["radius"] as? Number)?.toDouble()
                            ?: throw IllegalArgumentException("Circle zone missing radius")

                        ZoneData(id, name, type, LatLng(lat, lng), radius, null)
                    }
                    ZoneType.POLYGON -> {
                        val polygonData = data["polygon"] as? List<*>
                            ?: throw IllegalArgumentException("Polygon zone missing coordinates")

                        val points = polygonData.mapNotNull { point ->
                            val pointMap = point as? Map<*, *> ?: return@mapNotNull null
                            val lat = (pointMap["latitude"] as? Number)?.toDouble() ?: return@mapNotNull null
                            val lng = (pointMap["longitude"] as? Number)?.toDouble() ?: return@mapNotNull null
                            LatLng(lat, lng)
                        }

                        if (points.size < 3) {
                            throw IllegalArgumentException("Polygon must have at least 3 points")
                        }

                        // Check for self-intersecting polygon
                        if (GeofenceEngine.isPolygonSelfIntersecting(points)) {
                            throw IllegalArgumentException("Polygon is self-intersecting and cannot be used for geofencing")
                        }

                        // Warn about poles (reduced accuracy near ±85°)
                        GeofenceEngine.checkPoleWarning(points)

                        ZoneData(id, name, type, null, null, points)
                    }
                }
            }
        }
    }

    enum class ZoneType {
        CIRCLE, POLYGON
    }

    data class LatLng(val latitude: Double, val longitude: Double)




    /**
     * Calculate distance from point to zone boundary in meters.
     * For circles: |distance_to_center - radius|
     * For polygons: minimum distance from point to any polygon edge segment
     */
    private fun calculateDistanceFromBoundary(zone: ZoneData, location: Location): Double {
        return when (zone.type) {
            ZoneType.CIRCLE -> {
                val center = zone.center ?: return Double.MAX_VALUE
                val radius = zone.radius ?: return Double.MAX_VALUE
                val distance = GeoMath.haversineDistance(location.latitude, location.longitude, center.latitude, center.longitude)
                abs(distance - radius)
            }
            ZoneType.POLYGON -> {
                val vertices = zone.polygon ?: return Double.MAX_VALUE
                if (vertices.size < 2) return Double.MAX_VALUE
                var minDist = Double.MAX_VALUE
                for (i in vertices.indices) {
                    val j = (i + 1) % vertices.size
                    val segDist = GeoMath.pointToSegmentDistance(
                        location.latitude, location.longitude,
                        vertices[i].latitude, vertices[i].longitude,
                        vertices[j].latitude, vertices[j].longitude
                    )
                    if (segDist < minDist) minDist = segDist
                }
                minDist
            }
        }
    }


    /**
     * Public accessor for boundary distance, used by LocationTracker for event enrichment.
     */
    fun getDistanceToBoundary(zoneId: String, location: Location): Double {
        val zone = zones[zoneId] ?: return -1.0
        return calculateDistanceFromBoundary(zone, location)
    }

    // --- ML Telemetry: zone metrics ---

    /**
     * Returns zone size distribution bucketed as small (<200m), medium (<1000m), large (>=1000m).
     * For polygons, estimates radius as max distance from centroid to any vertex.
     */
    fun getZoneSizeDistribution(): Map<String, Int> {
        val dist = mutableMapOf("small" to 0, "medium" to 0, "large" to 0)
        zones.values.forEach { zone ->
            val effectiveRadius = when (zone.type) {
                ZoneType.CIRCLE -> zone.radius ?: 0.0
                ZoneType.POLYGON -> {
                    val center = zone.calculateCenter()
                    zone.polygon?.maxOfOrNull { vertex -> GeoMath.haversineDistance(vertex.latitude, vertex.longitude, center.latitude, center.longitude) } ?: 0.0
                }
            }
            when {
                effectiveRadius < 200 -> dist["small"] = dist["small"]!! + 1
                effectiveRadius < 1000 -> dist["medium"] = dist["medium"]!! + 1
                else -> dist["large"] = dist["large"]!! + 1
            }
        }
        return dist
    }


    /**
     * Compute dwell duration in minutes for a zone (if it has an entry time).
     * Used by LocationTracker on EXIT events for per-event enrichment.
     */
    fun getDwellDurationMinutes(zoneId: String): Double? {
        val entryTime = zoneEntryTimes[zoneId] ?: return null
        return (System.currentTimeMillis() - entryTime) / 60_000.0
    }

    /**
     * Reset false event reversal detection for a new session.
     * Note: Zone transition and dwell tracking is managed by TelemetryAggregator.
     */
    fun resetTelemetry() {
        lastEventPerZone.clear()
        lastEventWasQuickReversal.clear()
    }

    /**
     * Get zone complexity metric
     */
    private fun getZoneComplexity(zone: ZoneData): Int {
        return when (zone.type) {
            ZoneType.CIRCLE -> 1
            ZoneType.POLYGON -> zone.polygon?.size ?: 1
        }
    }


    /**
     * Calculate confidence based on GPS accuracy
     */
    private fun calculateConfidence(accuracy: Float): Double {
        return when {
            accuracy <= 10.0f -> 0.95
            accuracy <= 20.0f -> 0.85
            accuracy <= 50.0f -> 0.70
            accuracy <= 100.0f -> 0.50
            else -> 0.30
        }
    }

    private fun accuracyToConfidence(accuracyMeters: Float, confirmed: Boolean): Double {
        var base = (100.0 - accuracyMeters.toDouble()) / 100.0
        if (base < 0.0) base = 0.0
        if (base > 1.0) base = 1.0
        if (confirmed) base = (base + 0.05).coerceAtMost(1.0)
        return String.format(java.util.Locale.US, "%.2f", base).toDouble()
    }

    // ============================================================================
    // ZONE ACCESS FOR PROXIMITY CALCULATION
    // ============================================================================

    /**
     * Get current zones for proximity calculation
     */
    fun getCurrentZones(): List<Zone> {
        return zones.values.map { zoneData ->
            Zone(
                id = zoneData.id,
                name = zoneData.name,
                type = zoneData.type,
                center = zoneData.center,
                radius = zoneData.radius,
                points = zoneData.polygon ?: emptyList()
            )
        }
    }

    /**
     * Thread-safe zone count
     */
    @Synchronized
    fun getZoneCount(): Int = zones.size

    /**
     * Check if any zones are configured
     */
    @Synchronized
    fun hasZones(): Boolean = zones.isNotEmpty()

    /**
     * Zone data class for proximity calculation
     */
    data class Zone(
        val id: String,
        val name: String,
        val type: ZoneType,
        val center: LatLng?,
        val radius: Double?,
        val points: List<LatLng>
    ) {
        val isCircle: Boolean get() = type == ZoneType.CIRCLE
        val isPolygon: Boolean get() = type == ZoneType.POLYGON
    }

}

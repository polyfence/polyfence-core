package io.polyfence.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ServiceController

/**
 * Coverage for the counters and zone figures behind `debugInfo()`.
 *
 * [PolyfenceDebugCollector] keeps its counters on the companion, so they
 * accumulate for the lifetime of the test JVM. Every assertion here is
 * written against the delta across an action rather than an absolute value.
 *
 * Collection happens on a worker thread here because that is where both
 * bridges call it from in production, and the counters are written from the
 * location and geofence callback threads — so a same-thread read would not
 * exercise the monitor that guards them.
 */
@RunWith(RobolectricTestRunner::class)
class PolyfenceDebugCollectorMetricsTest {

    private lateinit var controller: ServiceController<LocationTracker>
    private lateinit var tracker: LocationTracker
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        controller = Robolectric.buildService(LocationTracker::class.java).create()
        tracker = controller.get()
        setIsRunning(true)
        LocationTracker.applyClearZonesDirect(tracker)
    }

    @After
    fun tearDown() {
        LocationTracker.applyClearZonesDirect(tracker)
        setIsRunning(false)
        tracker.onDestroy()
    }

    // -------- helpers --------

    private fun setIsRunning(value: Boolean) {
        // Mirrors LocationTrackerZoneOpsTest: the zone-op guards read a
        // companion `isRunning` compiled to a static field on the enclosing
        // class. Robolectric cannot drive startTracking(), which needs runtime
        // permissions and startForeground ceremony.
        val field = LocationTracker::class.java.getDeclaredField("isRunning")
        field.isAccessible = true
        field.setBoolean(null, value)
    }

    private fun debugInfo(): Map<String, Any> {
        var result: Map<String, Any>? = null
        var failure: Throwable? = null
        val worker = Thread {
            try {
                result = PolyfenceDebugCollector.collectDebugInfo(context)
            } catch (e: Throwable) {
                failure = e
            }
        }
        worker.start()
        worker.join()
        failure?.let { throw it }
        return result!!
    }

    @Suppress("UNCHECKED_CAST")
    private fun performance(): Map<String, Any> = debugInfo()["performance"] as Map<String, Any>

    @Suppress("UNCHECKED_CAST")
    private fun systemStatus(): Map<String, Any> = debugInfo()["systemStatus"] as Map<String, Any>

    @Suppress("UNCHECKED_CAST")
    private fun zones(): Map<String, Any> = debugInfo()["zones"] as Map<String, Any>

    private fun locationUpdateCount(): Int = performance()["totalLocationUpdates"] as Int

    private fun detectionCount(): Int = performance()["totalZoneDetections"] as Int

    private fun averageLatency(): Double = performance()["averageDetectionLatency"] as Double

    private fun restartCount(): Int = performance()["restartCount"] as Int

    private fun circleZone(
        lat: Double = 40.7128,
        lng: Double = -74.0060,
        radius: Double = 100.0
    ): Map<String, Any> = mapOf(
        "type" to "circle",
        "center" to mapOf("latitude" to lat, "longitude" to lng),
        "radius" to radius
    )

    private fun polygonZone(): Map<String, Any> = mapOf(
        "type" to "polygon",
        "polygon" to listOf(
            mapOf("latitude" to 0.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 0.0),
            mapOf("latitude" to 1.0, "longitude" to 1.0),
            mapOf("latitude" to 0.0, "longitude" to 1.0)
        )
    )

    // -------- location updates --------

    @Test
    fun `recordLocationUpdate advances the update count`() {
        val before = locationUpdateCount()

        PolyfenceDebugCollector.recordLocationUpdate(12.5)
        PolyfenceDebugCollector.recordLocationUpdate(8.0)

        assertEquals(before + 2, locationUpdateCount())
    }

    @Test
    fun `recordLocationUpdate publishes the accuracy and stamps the time`() {
        PolyfenceDebugCollector.recordLocationUpdate(37.25)

        val status = systemStatus()
        assertEquals(37.25, status["lastKnownAccuracy"] as Double, 0.0001)
        assertTrue(
            "lastLocationUpdate must be stamped, was ${status["lastLocationUpdate"]}",
            (status["lastLocationUpdate"] as Long) > 0L
        )
    }

    @Test
    fun `a location fix reaches the collector through the tracker`() {
        val before = locationUpdateCount()

        deliverLocation(accuracy = 9.0f)

        assertEquals(before + 1, locationUpdateCount())
        assertEquals(9.0, systemStatus()["lastKnownAccuracy"] as Double, 0.0001)
    }

    // -------- zone detections --------

    @Test
    fun `recordZoneDetection advances the detection count`() {
        val before = detectionCount()

        PolyfenceDebugCollector.recordZoneDetection(4.0)
        PolyfenceDebugCollector.recordZoneDetection(6.0)
        PolyfenceDebugCollector.recordZoneDetection(8.0)

        assertEquals(before + 3, detectionCount())
    }

    @Test
    fun `averageDetectionLatency is the mean of every sample recorded`() {
        val countBefore = detectionCount()
        val sumBefore = averageLatency() * countBefore

        PolyfenceDebugCollector.recordZoneDetection(10.0)
        PolyfenceDebugCollector.recordZoneDetection(20.0)

        val expected = (sumBefore + 30.0) / (countBefore + 2)
        assertEquals(expected, averageLatency(), 0.0001)
    }

    @Test
    fun `sub-millisecond latency contributes to the average`() {
        val countBefore = detectionCount()
        val sumBefore = averageLatency() * countBefore

        PolyfenceDebugCollector.recordZoneDetection(0.4)
        PolyfenceDebugCollector.recordZoneDetection(0.4)

        val sumAfter = averageLatency() * detectionCount()
        assertEquals(0.8, sumAfter - sumBefore, 0.0001)
    }

    @Test
    fun `a zone crossing reaches the collector through the tracker`() {
        val countBefore = detectionCount()
        val sumBefore = averageLatency() * countBefore

        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        deliverLocation(lat = 40.7128, lng = -74.0060)

        assertTrue(
            "expected a detection beyond the $countBefore already recorded",
            detectionCount() > countBefore
        )
        val sumAfter = averageLatency() * detectionCount()
        assertTrue(
            "the crossing must contribute a measured latency",
            sumAfter > sumBefore
        )
    }

    // -------- zone status --------

    @Test
    fun `zone counts come from the running engine`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.applyAddZoneDirect(tracker, "square", "Square", polygonZone())

        val status = zones()
        assertEquals(2, status["activeZones"] as Int)
        assertEquals(1, status["circleZones"] as Int)
        assertEquals(1, status["polygonZones"] as Int)
    }

    @Test
    fun `zone counts follow removals`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        LocationTracker.applyAddZoneDirect(tracker, "gym", "Gym", circleZone(lat = 40.75))
        assertEquals(2, zones()["activeZones"] as Int)

        LocationTracker.applyRemoveZoneDirect(tracker, "gym")
        assertEquals(1, zones()["activeZones"] as Int)

        LocationTracker.applyClearZonesDirect(tracker)
        assertEquals(0, zones()["activeZones"] as Int)
    }

    @Test
    fun `zone counts fall back to zero once the service is gone`() {
        LocationTracker.applyAddZoneDirect(tracker, "office", "Office", circleZone())
        assertEquals(1, zones()["activeZones"] as Int)

        tracker.onDestroy()

        assertEquals(0, zones()["activeZones"] as Int)
    }

    // -------- restarts --------

    @Test
    fun `creating the service again inside one process counts as a restart`() {
        val before = restartCount()

        val second = Robolectric.buildService(LocationTracker::class.java).create()
        second.get().onDestroy()

        assertEquals(before + 1, restartCount())
    }

    // -------- driving a fix through the tracker --------

    /**
     * Hand a location to the tracker's live [android.location.Location]
     * callback, which is the path a real fix from the fused provider takes.
     */
    private fun deliverLocation(
        lat: Double = 40.7128,
        lng: Double = -74.0060,
        accuracy: Float = 5.0f
    ) {
        val location = android.location.Location("test").apply {
            latitude = lat
            longitude = lng
            this.accuracy = accuracy
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = System.nanoTime()
        }

        val field = LocationTracker::class.java.getDeclaredField("locationCallback")
        field.isAccessible = true
        val callback = field.get(tracker) as com.google.android.gms.location.LocationCallback
        callback.onLocationResult(
            com.google.android.gms.location.LocationResult.create(listOf(location))
        )
    }
}

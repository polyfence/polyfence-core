package com.polyfence.core

import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import kotlin.math.abs

class TelemetryAggregatorTest {

    private lateinit var aggregator: TelemetryAggregator

    @Before
    fun setUp() {
        aggregator = TelemetryAggregator()
        aggregator.resetTelemetry()
    }

    // ========================================================================
    // Activity Distribution Tests
    // ========================================================================

    @Test
    fun `activity distribution sums to approximately 1_0`() {
        // Simulate activity changes
        aggregator.recordActivityChange("still")
        Thread.sleep(50)
        aggregator.recordActivityChange("walking")
        Thread.sleep(50)
        aggregator.recordActivityChange("driving")
        Thread.sleep(50)
        aggregator.finalizeActivityTracking()

        val telemetry = aggregator.getSessionTelemetry()
        @Suppress("UNCHECKED_CAST")
        val distribution = telemetry["activity_distribution"] as? Map<String, Double>

        assertNotNull("activity_distribution should not be null", distribution)
        if (distribution != null && distribution.isNotEmpty()) {
            val sum = distribution.values.sum()
            assertTrue(
                "Activity distribution should sum to ~1.0, got $sum",
                abs(sum - 1.0) < 0.01
            )
        }
    }

    @Test
    fun `activity distribution tracks multiple activities`() {
        aggregator.recordActivityChange("still")
        Thread.sleep(30)
        aggregator.recordActivityChange("walking")
        Thread.sleep(30)
        aggregator.finalizeActivityTracking()

        val telemetry = aggregator.getSessionTelemetry()
        @Suppress("UNCHECKED_CAST")
        val distribution = telemetry["activity_distribution"] as? Map<String, Double>

        assertNotNull(distribution)
        assertTrue("Should have 'unknown' from initial state", distribution!!.containsKey("unknown"))
    }

    // ========================================================================
    // False Event Counting Tests
    // ========================================================================

    @Test
    fun `false event counting with 30s window`() {
        // ENTER followed by EXIT within 30s = false event
        aggregator.recordGeofenceEvent(
            zoneId = "zone1",
            eventType = "ENTER",
            distanceM = 10.0,
            speedMps = 1.5,
            accuracyM = 15.0,
            detectionTimeMs = 2.5
        )

        // Immediate reversal (well within 30s)
        aggregator.recordGeofenceEvent(
            zoneId = "zone1",
            eventType = "EXIT",
            distanceM = 10.0,
            speedMps = 1.5,
            accuracyM = 15.0,
            detectionTimeMs = 2.0
        )

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Should detect 1 false event", 1, telemetry["false_event_count"])
    }

    @Test
    fun `same event type does not count as false event`() {
        aggregator.recordGeofenceEvent(
            zoneId = "zone1", eventType = "ENTER",
            distanceM = 10.0, speedMps = 1.5, accuracyM = 15.0, detectionTimeMs = 2.5
        )
        aggregator.recordGeofenceEvent(
            zoneId = "zone1", eventType = "ENTER",
            distanceM = 10.0, speedMps = 1.5, accuracyM = 15.0, detectionTimeMs = 2.0
        )

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Same event type should not be false event", 0, telemetry["false_event_count"])
    }

    @Test
    fun `different zones do not count as false events`() {
        aggregator.recordGeofenceEvent(
            zoneId = "zone1", eventType = "ENTER",
            distanceM = 10.0, speedMps = 1.5, accuracyM = 15.0, detectionTimeMs = 2.5
        )
        aggregator.recordGeofenceEvent(
            zoneId = "zone2", eventType = "EXIT",
            distanceM = 10.0, speedMps = 1.5, accuracyM = 15.0, detectionTimeMs = 2.0
        )

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Different zones should not be false events", 0, telemetry["false_event_count"])
    }

    // ========================================================================
    // GPS Interval Histogram Tests
    // ========================================================================

    @Test
    fun `GPS interval histogram tracks intervals`() {
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 10.0f)
        Thread.sleep(30)
        aggregator.recordGpsUpdate(intervalMs = 10000, accuracyM = 15.0f)
        Thread.sleep(30)
        aggregator.recordGpsUpdate(intervalMs = 30000, accuracyM = 20.0f)
        Thread.sleep(30)

        val telemetry = aggregator.getSessionTelemetry()
        @Suppress("UNCHECKED_CAST")
        val distribution = telemetry["gps_interval_distribution"] as? Map<String, Double>

        assertNotNull("gps_interval_distribution should not be null", distribution)
        if (distribution != null && distribution.isNotEmpty()) {
            val sum = distribution.values.sum()
            assertTrue(
                "GPS interval distribution should sum to ~1.0, got $sum",
                abs(sum - 1.0) < 0.01
            )
        }
    }

    @Test
    fun `average GPS interval is computed correctly`() {
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 10.0f)
        aggregator.recordGpsUpdate(intervalMs = 15000, accuracyM = 10.0f)

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Average interval should be 10000ms", 10000, telemetry["avg_gps_interval_ms"])
    }

    // ========================================================================
    // Zone Size Distribution Tests
    // ========================================================================

    @Test
    fun `zone size distribution returns expected keys`() {
        // Without a GeofenceEngine, these should be absent or default
        val telemetry = aggregator.getSessionTelemetry(geofenceEngine = null)
        assertEquals(0, telemetry["zone_count"])
    }

    // ========================================================================
    // getSessionTelemetry Returns All Expected Keys
    // ========================================================================

    @Test
    fun `getSessionTelemetry returns all expected v2 schema keys`() {
        // Set up some data
        aggregator.setConfig("balanced", "intelligent")
        aggregator.setDeviceInfo("samsung_budget", 13)
        aggregator.setBatteryInfo(85.0, 72.0, false)

        aggregator.recordActivityChange("walking")
        aggregator.recordGpsUpdate(intervalMs = 10000, accuracyM = 15.0f)
        aggregator.recordGeofenceEvent(
            zoneId = "z1", eventType = "ENTER",
            distanceM = 25.0, speedMps = 1.2, accuracyM = 15.0, detectionTimeMs = 3.0
        )
        aggregator.recordDwellComplete(durationMinutes = 12.5)

        val telemetry = aggregator.getSessionTelemetry()

        // Check all v2 schema keys are present
        val expectedKeys = listOf(
            "detections_total",
            "detection_time_avg_ms",
            "detection_time_p95_ms",
            "gps_accuracy_avg_m",
            "session_duration_minutes",
            "error_counts",
            "ttfd_ms",
            "had_detection",
            "gps_ok_ratio",
            "sample_events",
            "accuracy_profile",
            "update_strategy",
            "stationary_ratio",
            "avg_gps_interval_ms",
            "false_event_count",
            "false_event_ratio",
            "avg_gps_accuracy_at_event",
            "avg_speed_at_event_mps",
            "boundary_events_count",
            "zone_count",
            "zone_transition_count",
            "avg_dwell_minutes",
            "device_category",
            "os_version_major",
            "charging_during_session"
        )

        for (key in expectedKeys) {
            assertTrue("Missing expected key: $key", telemetry.containsKey(key))
        }

        // Verify specific values
        assertEquals(1, telemetry["detections_total"])
        assertEquals("balanced", telemetry["accuracy_profile"])
        assertEquals("intelligent", telemetry["update_strategy"])
        assertEquals("samsung_budget", telemetry["device_category"])
        assertEquals(13, telemetry["os_version_major"])
        assertEquals(false, telemetry["charging_during_session"])
        assertEquals(85.0, telemetry["battery_level_start"])
        assertEquals(72.0, telemetry["battery_level_end"])
        assertEquals(true, telemetry["had_detection"])
    }

    // ========================================================================
    // resetTelemetry Tests
    // ========================================================================

    @Test
    fun `resetTelemetry clears all state`() {
        // Record some data
        aggregator.recordActivityChange("walking")
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 10.0f)
        aggregator.recordGeofenceEvent(
            zoneId = "z1", eventType = "ENTER",
            distanceM = 10.0, speedMps = 1.5, accuracyM = 15.0, detectionTimeMs = 2.5
        )
        aggregator.recordError("gps_timeout")
        aggregator.setBatteryInfo(90.0, 80.0, true)

        // Reset
        aggregator.resetTelemetry()

        val telemetry = aggregator.getSessionTelemetry()

        assertEquals(0, telemetry["detections_total"])
        assertEquals(0, telemetry["false_event_count"])
        assertEquals(0, telemetry["zone_transition_count"])
        assertEquals(0, telemetry["boundary_events_count"])
        assertEquals(0, telemetry["sample_events"])
        assertEquals(false, telemetry["had_detection"])

        @Suppress("UNCHECKED_CAST")
        val errors = telemetry["error_counts"] as? Map<String, Int>
        assertTrue("Error counts should be empty after reset", errors?.isEmpty() ?: true)
    }

    // ========================================================================
    // Boundary Events Tests
    // ========================================================================

    @Test
    fun `boundary events counted when distance less than 50m`() {
        aggregator.recordGeofenceEvent(
            zoneId = "z1", eventType = "ENTER",
            distanceM = 30.0, speedMps = 1.0, accuracyM = 10.0, detectionTimeMs = 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId = "z2", eventType = "ENTER",
            distanceM = 100.0, speedMps = 5.0, accuracyM = 20.0, detectionTimeMs = 3.0
        )
        aggregator.recordGeofenceEvent(
            zoneId = "z3", eventType = "EXIT",
            distanceM = 10.0, speedMps = 2.0, accuracyM = 12.0, detectionTimeMs = 1.5
        )

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Should count 2 boundary events (<50m)", 2, telemetry["boundary_events_count"])
    }

    // ========================================================================
    // Detection Timing Tests
    // ========================================================================

    @Test
    fun `detection time average and p95 computed correctly`() {
        // Record 10 events with known detection times
        for (i in 1..10) {
            aggregator.recordGeofenceEvent(
                zoneId = "z${i % 5}", eventType = if (i % 2 == 0) "ENTER" else "EXIT",
                distanceM = 100.0, speedMps = 5.0, accuracyM = 15.0,
                detectionTimeMs = i.toDouble()
            )
        }

        val telemetry = aggregator.getSessionTelemetry()
        val avg = telemetry["detection_time_avg_ms"] as Double
        val p95 = telemetry["detection_time_p95_ms"] as Double

        assertEquals("Average should be 5.5ms", 5.5, avg, 0.01)
        assertTrue("P95 should be >= 9.0ms", p95 >= 9.0)
    }

    // ========================================================================
    // False Event Ratio Tests
    // ========================================================================

    @Test
    fun `false event ratio computed correctly`() {
        // 4 events, 1 false (ENTER then EXIT on same zone within 30s)
        aggregator.recordGeofenceEvent(
            zoneId = "z1", eventType = "ENTER",
            distanceM = 10.0, speedMps = 1.0, accuracyM = 10.0, detectionTimeMs = 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId = "z1", eventType = "EXIT",
            distanceM = 10.0, speedMps = 1.0, accuracyM = 10.0, detectionTimeMs = 2.0
        )
        aggregator.recordGeofenceEvent(
            zoneId = "z2", eventType = "ENTER",
            distanceM = 100.0, speedMps = 5.0, accuracyM = 20.0, detectionTimeMs = 3.0
        )
        aggregator.recordGeofenceEvent(
            zoneId = "z3", eventType = "ENTER",
            distanceM = 200.0, speedMps = 10.0, accuracyM = 25.0, detectionTimeMs = 4.0
        )

        val telemetry = aggregator.getSessionTelemetry()
        val ratio = telemetry["false_event_ratio"] as Double
        assertEquals("False event ratio should be 0.25 (1/4)", 0.25, ratio, 0.01)
    }

    // ========================================================================
    // GPS Health Tests
    // ========================================================================

    @Test
    fun `GPS OK ratio tracks good vs bad readings`() {
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 10.0f)  // good
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 50.0f)  // good
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 150.0f) // bad
        aggregator.recordGpsUpdate(intervalMs = 5000, accuracyM = 200.0f) // bad

        val telemetry = aggregator.getSessionTelemetry()
        val ratio = telemetry["gps_ok_ratio"] as Double
        assertEquals("GPS OK ratio should be 0.5 (2/4)", 0.5, ratio, 0.01)
    }

    // ========================================================================
    // Dwell Duration Tests
    // ========================================================================

    @Test
    fun `average dwell minutes computed correctly`() {
        aggregator.recordDwellComplete(durationMinutes = 10.0)
        aggregator.recordDwellComplete(durationMinutes = 20.0)
        aggregator.recordDwellComplete(durationMinutes = 30.0)

        val telemetry = aggregator.getSessionTelemetry()
        assertEquals("Average dwell should be 20 minutes", 20.0, telemetry["avg_dwell_minutes"] as Double, 0.01)
    }
}

package io.polyfence.core

/**
 * Computes a 0-100 health score from current debug metrics and telemetry state.
 * Pure function — no side effects, no state.
 *
 * Score bands:
 *   90-100  Excellent — everything running well
 *   70-89   Good — minor issues
 *   50-69   Fair — degraded performance, action recommended
 *   0-49    Poor — significant issues
 *
 * Top issue is the single most impactful problem (or null if score >= 90).
 */
object HealthScoreCalculator {

    data class HealthScore(
        val score: Int,
        val topIssue: String?
    )

    /**
     * Calculate health score from current metrics.
     *
     * @param gpsGoodRatio Ratio of GPS readings with accuracy <= 100m (0.0–1.0)
     * @param batteryDrainPctPerHr Estimated battery drain percent per hour
     * @param avgDetectionLatencyMs Average detection latency in milliseconds
     * @param errorCountRecent Number of errors in recent window
     * @param falseEventRatio Ratio of false events to total events (0.0–1.0)
     * @param isTracking Whether tracking is currently active
     * @param activeZoneCount Number of active zones
     */
    fun calculate(
        gpsGoodRatio: Double,
        batteryDrainPctPerHr: Double,
        avgDetectionLatencyMs: Double,
        errorCountRecent: Int,
        falseEventRatio: Double,
        isTracking: Boolean,
        activeZoneCount: Int
    ): HealthScore {
        if (!isTracking) {
            return HealthScore(score = 0, topIssue = "Tracking is not active")
        }

        // Each dimension scores 0-20, total 0-100
        val penalties = mutableListOf<Pair<Int, String>>()

        // GPS accuracy (0-20 points)
        val gpsScore = when {
            gpsGoodRatio >= 0.9 -> 20
            gpsGoodRatio >= 0.7 -> 15
            gpsGoodRatio >= 0.5 -> 10
            gpsGoodRatio >= 0.3 -> 5
            else -> 0
        }
        if (gpsScore < 15) {
            penalties.add(Pair(20 - gpsScore, "GPS accuracy is poor (${(gpsGoodRatio * 100).toInt()}% good readings)"))
        }

        // Battery drain (0-20 points)
        val batteryScore = when {
            batteryDrainPctPerHr <= 2.0 -> 20
            batteryDrainPctPerHr <= 5.0 -> 15
            batteryDrainPctPerHr <= 10.0 -> 10
            batteryDrainPctPerHr <= 20.0 -> 5
            else -> 0
        }
        if (batteryScore < 15) {
            penalties.add(Pair(20 - batteryScore, "Battery drain is high (${batteryDrainPctPerHr.toInt()}%/hr)"))
        }

        // Detection latency (0-20 points)
        val latencyScore = when {
            avgDetectionLatencyMs <= 100.0 -> 20
            avgDetectionLatencyMs <= 500.0 -> 15
            avgDetectionLatencyMs <= 1000.0 -> 10
            avgDetectionLatencyMs <= 3000.0 -> 5
            else -> 0
        }
        if (latencyScore < 15) {
            penalties.add(Pair(20 - latencyScore, "Detection latency is high (${avgDetectionLatencyMs.toInt()}ms)"))
        }

        // Error rate (0-20 points)
        val errorScore = when {
            errorCountRecent == 0 -> 20
            errorCountRecent <= 2 -> 15
            errorCountRecent <= 5 -> 10
            errorCountRecent <= 10 -> 5
            else -> 0
        }
        if (errorScore < 15) {
            penalties.add(Pair(20 - errorScore, "Error rate is elevated ($errorCountRecent recent errors)"))
        }

        // False event ratio (0-20 points)
        val falseEventScore = when {
            falseEventRatio <= 0.05 -> 20
            falseEventRatio <= 0.10 -> 15
            falseEventRatio <= 0.20 -> 10
            falseEventRatio <= 0.40 -> 5
            else -> 0
        }
        if (falseEventScore < 15) {
            penalties.add(Pair(20 - falseEventScore, "False event rate is high (${(falseEventRatio * 100).toInt()}%)"))
        }

        val totalScore = (gpsScore + batteryScore + latencyScore + errorScore + falseEventScore)
            .coerceIn(0, 100)

        // Top issue is the one with the highest penalty
        val topIssue = if (totalScore >= 90) null
            else penalties.maxByOrNull { it.first }?.second

        return HealthScore(score = totalScore, topIssue = topIssue)
    }
}

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
     * Every input must be a measurement. A dimension that cannot be measured
     * is left out rather than defaulted, because a default scores as though
     * the device were performing perfectly on it and inflates the result.
     *
     * @param gpsGoodRatio Ratio of GPS readings with accuracy <= 100m (0.0–1.0),
     *   or null when no fix has been sampled yet
     * @param avgDetectionLatencyMs Average detection latency in milliseconds,
     *   or null when no crossing has been detected yet and there is therefore
     *   nothing to average
     * @param errorCountRecent Number of errors in recent window
     * @param falseEventRatio Ratio of false events to total events (0.0–1.0),
     *   or null when no boundary event has occurred yet
     * @param isTracking Whether tracking is currently active
     * @param activeZoneCount Number of active zones
     */
    fun calculate(
        gpsGoodRatio: Double?,
        avgDetectionLatencyMs: Double?,
        errorCountRecent: Int,
        falseEventRatio: Double?,
        isTracking: Boolean,
        activeZoneCount: Int
    ): HealthScore {
        if (!isTracking) {
            return HealthScore(score = 0, topIssue = "Tracking is not active")
        }

        // Each dimension scores 0-20; whichever could be measured are
        // rescaled to 0-100 at the end so the published bands keep their
        // meaning however many that was.
        val penalties = mutableListOf<Pair<Int, String>>()

        // GPS accuracy (0-20 points). Scored only once a fix has been
        // sampled: with no samples the ratio reads 0, which is the *worst*
        // band, so a device that has simply not started yet would be
        // condemned for a measurement nobody took.
        val gpsScore: Int? = gpsGoodRatio?.let { ratio ->
            val scored = when {
                ratio >= 0.9 -> 20
                ratio >= 0.7 -> 15
                ratio >= 0.5 -> 10
                ratio >= 0.3 -> 5
                else -> 0
            }
            if (scored < 15) {
                penalties.add(Pair(20 - scored, "GPS accuracy is poor (${(ratio * 100).toInt()}% good readings)"))
            }
            scored
        }

        // Detection latency (0-20 points). Scored only once a crossing has
        // been detected: with no samples there is no latency to judge, and
        // scoring the absence would award the best possible band for a
        // dimension nobody measured.
        val latencyScore: Int? = avgDetectionLatencyMs?.let { latency ->
            val scored = when {
                latency <= 100.0 -> 20
                latency <= 500.0 -> 15
                latency <= 1000.0 -> 10
                latency <= 3000.0 -> 5
                else -> 0
            }
            if (scored < 15) {
                penalties.add(Pair(20 - scored, "Detection latency is high (${latency.toInt()}ms)"))
            }
            scored
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

        // False event ratio (0-20 points). Scored only once a boundary event
        // has occurred: with none, the ratio reads 0, which is the *best*
        // band, so an idle device would collect full marks for accuracy it
        // never demonstrated.
        val falseEventScore: Int? = falseEventRatio?.let { ratio ->
            val scored = when {
                ratio <= 0.05 -> 20
                ratio <= 0.10 -> 15
                ratio <= 0.20 -> 10
                ratio <= 0.40 -> 5
                else -> 0
            }
            if (scored < 15) {
                penalties.add(Pair(20 - scored, "False event rate is high (${(ratio * 100).toInt()}%)"))
            }
            scored
        }

        // Rescale over the dimensions actually scored, so an unmeasurable
        // one lowers neither the score nor its ceiling.
        val measured = listOfNotNull(gpsScore, latencyScore, errorScore, falseEventScore)
        val dimensionTotal = measured.sum()
        val available = measured.size * 20
        val totalScore = if (available == 0) 0
            else Math.round(dimensionTotal / available.toDouble() * 100.0).toInt().coerceIn(0, 100)

        // Top issue is the one with the highest penalty
        val topIssue = if (totalScore >= 90) null
            else penalties.maxByOrNull { it.first }?.second

        return HealthScore(score = totalScore, topIssue = topIssue)
    }
}

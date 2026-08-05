import Foundation

/// Computes a 0-100 health score from current debug metrics and telemetry state.
/// Pure function — no side effects, no state.
///
/// Score bands:
///   90-100  Excellent — everything running well
///   70-89   Good — minor issues
///   50-69   Fair — degraded performance, action recommended
///   0-49    Poor — significant issues
///
/// Top issue is the single most impactful problem (or nil if score >= 90).
public struct HealthScore {
    public let score: Int
    public let topIssue: String?
}

public enum HealthScoreCalculator {

    /// Calculate health score from current metrics.
    ///
    /// Every input must be a measurement. A dimension that cannot be measured
    /// is left out rather than defaulted, because a default scores as though
    /// the device were performing perfectly on it and inflates the result.
    ///
    /// - Parameters:
    ///   - gpsGoodRatio: Ratio of GPS readings with accuracy <= 100m (0.0–1.0)
    ///   - avgDetectionLatencyMs: Average detection latency in milliseconds,
    ///     or nil when no crossing has been detected yet and there is
    ///     therefore nothing to average
    ///   - errorCountRecent: Number of errors in recent window
    ///   - falseEventRatio: Ratio of false events to total events (0.0–1.0),
    ///     or nil when no boundary event has occurred yet
    ///   - isTracking: Whether tracking is currently active
    ///   - activeZoneCount: Number of active zones
    public static func calculate(
        gpsGoodRatio: Double,
        avgDetectionLatencyMs: Double?,
        errorCountRecent: Int,
        falseEventRatio: Double?,
        isTracking: Bool,
        activeZoneCount: Int
    ) -> HealthScore {
        guard isTracking else {
            return HealthScore(score: 0, topIssue: "Tracking is not active")
        }

        // Each dimension scores 0-20; whichever could be measured are
        // rescaled to 0-100 at the end so the published bands keep their
        // meaning however many that was.
        var penalties: [(Int, String)] = []

        // GPS accuracy (0-20 points). Always scored, unlike the two below:
        // this figure is only ever read from a scheduled emission minutes into
        // an active session, so no samples by then is a GPS that is failing to
        // deliver, not one that has yet to start.
        let gpsScore: Int
        switch gpsGoodRatio {
        case 0.9...: gpsScore = 20
        case 0.7...: gpsScore = 15
        case 0.5...: gpsScore = 10
        case 0.3...: gpsScore = 5
        default: gpsScore = 0
        }
        if gpsScore < 15 {
            penalties.append((20 - gpsScore, "GPS accuracy is poor (\(Int(gpsGoodRatio * 100))% good readings)"))
        }

        // Detection latency (0-20 points). Scored only once a crossing has
        // been detected: with no samples there is no latency to judge, and
        // scoring the absence would award the best possible band for a
        // dimension nobody measured.
        var latencyScore: Int? = nil
        if let latency = avgDetectionLatencyMs {
            let scored: Int
            switch latency {
            case ...100.0: scored = 20
            case ...500.0: scored = 15
            case ...1000.0: scored = 10
            case ...3000.0: scored = 5
            default: scored = 0
            }
            latencyScore = scored
            if scored < 15 {
                penalties.append((20 - scored, "Detection latency is high (\(Int(latency))ms)"))
            }
        }

        // Error rate (0-20 points)
        let errorScore: Int
        switch errorCountRecent {
        case 0: errorScore = 20
        case 1...2: errorScore = 15
        case 3...5: errorScore = 10
        case 6...10: errorScore = 5
        default: errorScore = 0
        }
        if errorScore < 15 {
            penalties.append((20 - errorScore, "Error rate is elevated (\(errorCountRecent) recent errors)"))
        }

        // False event ratio (0-20 points). Scored only once a boundary event
        // has occurred: with none, the ratio reads 0, which is the *best*
        // band, so an idle device would collect full marks for accuracy it
        // never demonstrated.
        var falseEventScore: Int? = nil
        if let ratio = falseEventRatio {
            let scored: Int
            switch ratio {
            case ...0.05: scored = 20
            case ...0.10: scored = 15
            case ...0.20: scored = 10
            case ...0.40: scored = 5
            default: scored = 0
            }
            falseEventScore = scored
            if scored < 15 {
                penalties.append((20 - scored, "False event rate is high (\(Int(ratio * 100))%)"))
            }
        }

        // Rescale over the dimensions actually scored, so an unmeasurable
        // one lowers neither the score nor its ceiling.
        let measured = [gpsScore, latencyScore, errorScore, falseEventScore].compactMap { $0 }
        let dimensionTotal = measured.reduce(0, +)
        let available = measured.count * 20
        let totalScore = available == 0
            ? 0
            : min(max(Int((Double(dimensionTotal) / Double(available) * 100.0).rounded()), 0), 100)

        let topIssue: String?
        if totalScore >= 90 {
            topIssue = nil
        } else {
            topIssue = penalties.max(by: { $0.0 < $1.0 })?.1
        }

        return HealthScore(score: totalScore, topIssue: topIssue)
    }
}

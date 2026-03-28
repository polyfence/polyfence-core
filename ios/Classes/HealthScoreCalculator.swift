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
    /// - Parameters:
    ///   - gpsGoodRatio: Ratio of GPS readings with accuracy <= 100m (0.0–1.0)
    ///   - batteryDrainPctPerHr: Estimated battery drain percent per hour
    ///   - avgDetectionLatencyMs: Average detection latency in milliseconds
    ///   - errorCountRecent: Number of errors in recent window
    ///   - falseEventRatio: Ratio of false events to total events (0.0–1.0)
    ///   - isTracking: Whether tracking is currently active
    ///   - activeZoneCount: Number of active zones
    public static func calculate(
        gpsGoodRatio: Double,
        batteryDrainPctPerHr: Double,
        avgDetectionLatencyMs: Double,
        errorCountRecent: Int,
        falseEventRatio: Double,
        isTracking: Bool,
        activeZoneCount: Int
    ) -> HealthScore {
        guard isTracking else {
            return HealthScore(score: 0, topIssue: "Tracking is not active")
        }

        // Each dimension scores 0-20, total 0-100
        var penalties: [(Int, String)] = []

        // GPS accuracy (0-20 points)
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

        // Battery drain (0-20 points)
        let batteryScore: Int
        switch batteryDrainPctPerHr {
        case ...2.0: batteryScore = 20
        case ...5.0: batteryScore = 15
        case ...10.0: batteryScore = 10
        case ...20.0: batteryScore = 5
        default: batteryScore = 0
        }
        if batteryScore < 15 {
            penalties.append((20 - batteryScore, "Battery drain is high (\(Int(batteryDrainPctPerHr))%/hr)"))
        }

        // Detection latency (0-20 points)
        let latencyScore: Int
        switch avgDetectionLatencyMs {
        case ...100.0: latencyScore = 20
        case ...500.0: latencyScore = 15
        case ...1000.0: latencyScore = 10
        case ...3000.0: latencyScore = 5
        default: latencyScore = 0
        }
        if latencyScore < 15 {
            penalties.append((20 - latencyScore, "Detection latency is high (\(Int(avgDetectionLatencyMs))ms)"))
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

        // False event ratio (0-20 points)
        let falseEventScore: Int
        switch falseEventRatio {
        case ...0.05: falseEventScore = 20
        case ...0.10: falseEventScore = 15
        case ...0.20: falseEventScore = 10
        case ...0.40: falseEventScore = 5
        default: falseEventScore = 0
        }
        if falseEventScore < 15 {
            penalties.append((20 - falseEventScore, "False event rate is high (\(Int(falseEventRatio * 100))%)"))
        }

        let totalScore = min(max(gpsScore + batteryScore + latencyScore + errorScore + falseEventScore, 0), 100)

        let topIssue: String?
        if totalScore >= 90 {
            topIssue = nil
        } else {
            topIssue = penalties.max(by: { $0.0 < $1.0 })?.1
        }

        return HealthScore(score: totalScore, topIssue: topIssue)
    }
}

import Foundation

/// Shared time-formatting helpers used by dashboard rows and chart axes. Kept in
/// one place so "1시간 30분" and "1h 30m" never drift apart across views.
enum TimeFormatting {
    /// "1시간 23분 45초" — long form for headlines.
    static func longHMS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 && m > 0 { return "\(h)시간 \(m)분" }
        if h > 0 { return "\(h)시간" }
        if m > 0 && s > 0 { return "\(m)분 \(s)초" }
        if m > 0 { return "\(m)분" }
        return "\(s)초"
    }

    /// "01:23:45" — fixed-width form for table rows.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "23%" — for category proportions.
    static func percent(_ part: TimeInterval, of whole: TimeInterval) -> String {
        guard whole > 0 else { return "0%" }
        let pct = (part / whole * 100).rounded()
        return "\(Int(pct))%"
    }
}

import Foundation

/// Dashboard period selection. Each case maps to a contiguous `[start, end]` of
/// local-calendar days; the dashboard renders aggregates over that span.
///
/// Week is Monday–Sunday per spec (`firstWeekday = 2` on `iso8601` calendar).
enum DashboardPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case range  // user-defined [from, to]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day:   return "일별"
        case .week:  return "주별"
        case .month: return "월별"
        case .range: return "기간"
        }
    }
}

/// Closed range of local-calendar days, both endpoints inclusive.
/// Stored as the first instant of each end-day so SQL comparisons against `startAt`
/// remain unambiguous regardless of how the upper bound is rendered.
struct DayRange: Equatable {
    let start: Date  // start-of-day for the first day
    let end: Date    // start-of-day for the last day (inclusive)
    let calendar: Calendar

    /// Inclusive day count (so a single-day range returns 1).
    var dayCount: Int {
        let comps = calendar.dateComponents([.day], from: start, to: end)
        return (comps.day ?? 0) + 1
    }

    /// First day-key (YYYY-MM-DD) and last day-key (YYYY-MM-DD); used to filter the
    /// `day` column in SQL with a BETWEEN clause.
    var dayKeys: (first: String, last: String) {
        (DayKey.string(for: start, calendar: calendar),
         DayKey.string(for: end, calendar: calendar))
    }

    /// All inclusive day-keys in chronological order. Used to align bar-chart
    /// series so missing days render as zero rather than collapsing the axis.
    func enumerateDayKeys() -> [String] {
        var keys: [String] = []
        var cursor = start
        while cursor <= end {
            keys.append(DayKey.string(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    /// Boundary instants for queries against `startAt` (a session-start before
    /// `start` of-day, or after end-of-day, is out of range).
    var startInstant: Date { start }
    var endInstantExclusive: Date {
        calendar.date(byAdding: .day, value: 1, to: end) ?? end
    }
}

enum DashboardRange {
    /// Snap an arbitrary anchor date to the start-of-day in the given calendar.
    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Single-day range anchored at `date`.
    static func day(_ date: Date, calendar: Calendar = .current) -> DayRange {
        let s = calendar.startOfDay(for: date)
        return DayRange(start: s, end: s, calendar: calendar)
    }

    /// Monday → Sunday week containing `date`. Spec §goal — 주 단위는 월요일에서 일요일.
    /// Always returns a 7-day inclusive range.
    static func week(containing date: Date, calendar: Calendar = .current) -> DayRange {
        var cal = calendar
        cal.firstWeekday = 2  // Monday
        cal.minimumDaysInFirstWeek = 4  // ISO-style; irrelevant for this calc but consistent
        let startOfDay = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: startOfDay)  // 1=Sun..7=Sat
        // Days back to the Monday: weekday 2(Mon)→0, 3(Tue)→1, ..., 1(Sun)→6
        let daysBackToMonday = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -daysBackToMonday, to: startOfDay),
              let sunday = cal.date(byAdding: .day, value: 6, to: monday) else {
            return DayRange(start: startOfDay, end: startOfDay, calendar: cal)
        }
        return DayRange(start: monday, end: sunday, calendar: cal)
    }

    /// Calendar month (1st → last day) containing `date`.
    static func month(containing date: Date, calendar: Calendar = .current) -> DayRange {
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: comps),
              let monthRange = calendar.range(of: .day, in: .month, for: firstOfMonth),
              let lastDay = calendar.date(byAdding: .day,
                                          value: monthRange.count - 1,
                                          to: firstOfMonth) else {
            let s = calendar.startOfDay(for: date)
            return DayRange(start: s, end: s, calendar: calendar)
        }
        return DayRange(start: firstOfMonth, end: lastDay, calendar: calendar)
    }

    /// Custom inclusive range. If `from > to`, the endpoints are swapped so the
    /// result is always well-formed for queries.
    static func custom(from: Date, to: Date, calendar: Calendar = .current) -> DayRange {
        let a = calendar.startOfDay(for: from)
        let b = calendar.startOfDay(for: to)
        let (s, e) = a <= b ? (a, b) : (b, a)
        return DayRange(start: s, end: e, calendar: calendar)
    }

    /// Shift a range by `direction` periods of `period` (-1 = previous, +1 = next).
    /// For `.range` the shift is the same number of days as the current span.
    static func shift(_ range: DayRange, period: DashboardPeriod, by direction: Int,
                      calendar: Calendar = .current) -> DayRange {
        switch period {
        case .day:
            let s = calendar.date(byAdding: .day, value: direction, to: range.start) ?? range.start
            return DayRange(start: s, end: s, calendar: calendar)
        case .week:
            let s = calendar.date(byAdding: .day, value: 7 * direction, to: range.start) ?? range.start
            return week(containing: s, calendar: calendar)
        case .month:
            let s = calendar.date(byAdding: .month, value: direction, to: range.start) ?? range.start
            return month(containing: s, calendar: calendar)
        case .range:
            let span = range.dayCount
            let s = calendar.date(byAdding: .day, value: span * direction, to: range.start) ?? range.start
            let e = calendar.date(byAdding: .day, value: span - 1, to: s) ?? s
            return DayRange(start: s, end: e, calendar: calendar)
        }
    }
}

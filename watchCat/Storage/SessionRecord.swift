import Foundation
import GRDB

/// SPEC §F2.2 — one row per (active app, contiguous foreground span). Pause periods
/// (lock / sleep / idle / manual) produce gaps between sessions, not rows of their own.
struct SessionRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "sessions"

    var id: Int64?
    var startAt: Date
    var endAt: Date?
    var bundleID: String
    var displayName: String
    /// Local-calendar day (YYYY-MM-DD) the session is attributed to. Per SPEC §F2.4,
    /// midnight-crossing sessions belong entirely to their start day — denormalized
    /// here so daily aggregation is a cheap indexed GROUP BY.
    var day: String

    enum Columns {
        static let id = Column("id")
        static let startAt = Column("startAt")
        static let endAt = Column("endAt")
        static let bundleID = Column("bundleID")
        static let displayName = Column("displayName")
        static let day = Column("day")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var duration: TimeInterval {
        guard let endAt else { return 0 }
        return endAt.timeIntervalSince(startAt)
    }
}

/// Per-app daily aggregation result returned by `SessionStore.dailyTotals(for:)`.
struct AppTotal: Equatable {
    let bundleID: String
    let displayName: String
    let seconds: TimeInterval
}

enum DayKey {
    /// Local-calendar `YYYY-MM-DD` for `date`. Used to attribute sessions to a day.
    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

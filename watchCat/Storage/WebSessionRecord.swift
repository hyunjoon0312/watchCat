import Foundation
import GRDB

/// SPEC §F3.2 — one row per (Chrome active tab bucket, contiguous span).
/// `bucket` is the aggregation key under the current record unit
/// (domain | url | title), or `(시크릿 모드)` when an incognito tab is
/// active and the user has opted out of incognito detail (§F3.5.1).
struct WebSessionRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "web_sessions"

    var id: Int64?
    var startAt: Date
    var endAt: Date?
    var bucket: String
    var url: String?          // raw URL for drill-down; nil under incognito-bucket
    var title: String?
    var isIncognito: Bool
    var day: String

    enum Columns {
        static let id = Column("id")
        static let startAt = Column("startAt")
        static let endAt = Column("endAt")
        static let bucket = Column("bucket")
        static let url = Column("url")
        static let title = Column("title")
        static let isIncognito = Column("isIncognito")
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

/// Per-bucket daily aggregation for the web sessions table.
struct WebBucketTotal: Equatable {
    let bucket: String
    let seconds: TimeInterval
}

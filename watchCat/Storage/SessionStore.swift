import Foundation
import GRDB

/// Thin GRDB-backed persistence layer for `SessionRecord`. Owns a single
/// `DatabaseQueue`; one instance per app process is enough.
final class SessionStore {
    /// Exposed at module scope so analytics / export extensions in this target
    /// can share the same connection. External callers must still go through
    /// the typed accessors on `SessionStore`.
    let dbQueue: DatabaseQueue

    /// Default file location per SPEC §1 비기능 요건 (저장).
    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("watchCat", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("watchCat.sqlite")
    }

    init(url: URL) throws {
        self.dbQueue = try DatabaseQueue(path: url.path)
        try migrate()
        try closeOrphanedSessions()
    }

    /// In-memory store for tests.
    init() throws {
        self.dbQueue = try DatabaseQueue()
        try migrate()
    }

    /// SPEC-implied recovery: if a previous run died mid-session (force-quit,
    /// crash, debugger detach), rows can be left with `endAt IS NULL`. Live
    /// aggregation would otherwise count those as "still running" forever and
    /// inflate every app's daily total on each menu refresh.
    ///
    /// We close them as zero-length (`endAt = startAt`); the data lost is at
    /// most the duration of one session per app from the last unclean exit.
    /// A future heartbeat column would let us recover most of that span.
    func closeOrphanedSessions() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE \(SessionRecord.databaseTableName)
                SET endAt = startAt
                WHERE endAt IS NULL
                """)
            try db.execute(sql: """
                UPDATE \(WebSessionRecord.databaseTableName)
                SET endAt = startAt
                WHERE endAt IS NULL
                """)
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_sessions") { db in
            try db.create(table: SessionRecord.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime)
                t.column("bundleID", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("day", .text).notNull().indexed()
            }
            try db.create(index: "idx_sessions_day_bundle",
                          on: SessionRecord.databaseTableName,
                          columns: ["day", "bundleID"])
        }
        migrator.registerMigration("v2_web_sessions") { db in
            try db.create(table: WebSessionRecord.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startAt", .datetime).notNull()
                t.column("endAt", .datetime)
                t.column("bucket", .text).notNull()
                t.column("url", .text)
                t.column("title", .text)
                t.column("isIncognito", .boolean).notNull().defaults(to: false)
                t.column("day", .text).notNull().indexed()
            }
            try db.create(index: "idx_web_sessions_day_bucket",
                          on: WebSessionRecord.databaseTableName,
                          columns: ["day", "bucket"])
        }
        migrator.registerMigration("v3_app_categories") { db in
            try db.create(table: AppCategoryRecord.databaseTableName) { t in
                t.column("bundleID", .text).notNull().primaryKey()
                t.column("category", .text).notNull()
            }
        }
        migrator.registerMigration("v4_rename_incognito_bucket") { db in
            // Display-string rename: "(인코그니토)" → "(시크릿 모드)". Old rows must
            // collapse into the new bucket so daily totals stay continuous across
            // the rename instead of splitting into two visually-different rows.
            try db.execute(
                sql: "UPDATE \(WebSessionRecord.databaseTableName) SET bucket = ? WHERE bucket = ?",
                arguments: [URLUtilities.incognitoBucket, "(인코그니토)"]
            )
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Writes

    /// Inserts a new session row. Returns the rowid for follow-up `endSession` calls.
    func startSession(at start: Date, bundleID: String, displayName: String,
                      calendar: Calendar = .current) throws -> Int64 {
        var rec = SessionRecord(
            id: nil,
            startAt: start,
            endAt: nil,
            bundleID: bundleID,
            displayName: displayName,
            day: DayKey.string(for: start, calendar: calendar)
        )
        try dbQueue.write { db in
            try rec.insert(db)
        }
        return rec.id!
    }

    func endSession(id: Int64, at end: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(SessionRecord.databaseTableName) SET endAt = ? WHERE id = ?",
                arguments: [end, id]
            )
        }
    }

    // MARK: - Reads

    /// Per-app totals for a local-calendar day. SPEC §F2.4: a session is attributed
    /// entirely to its **start** day, so we group by the stored `day` column rather
    /// than slicing intervals.
    ///
    /// Open sessions (`endAt IS NULL`) — the row representing the app you're using
    /// right now — count as `asOf - startAt` so the menu's "today" total reflects
    /// elapsed time live instead of showing 0 until you switch apps.
    func dailyTotals(for date: Date, calendar: Calendar = .current,
                     asOf: Date = Date()) throws -> [AppTotal] {
        let dayKey = DayKey.string(for: date, calendar: calendar)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bundleID, displayName,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day = ?
                GROUP BY bundleID, displayName
                ORDER BY seconds DESC
                """, arguments: [asOf, dayKey])
            return rows.map { row in
                AppTotal(
                    bundleID: row["bundleID"],
                    displayName: row["displayName"],
                    seconds: row["seconds"] ?? 0
                )
            }
        }
    }

    func totalSeconds(for date: Date, calendar: Calendar = .current,
                      asOf: Date = Date()) throws -> TimeInterval {
        let totals = try dailyTotals(for: date, calendar: calendar, asOf: asOf)
        return totals.reduce(0) { $0 + $1.seconds }
    }

    /// Helper used by tests / debug — count of rows.
    func allSessions() throws -> [SessionRecord] {
        try dbQueue.read { db in
            try SessionRecord.fetchAll(db)
        }
    }

    // MARK: - Web sessions (SPEC §F3)

    func startWebSession(at start: Date, bucket: String, url: String?, title: String?,
                        isIncognito: Bool, calendar: Calendar = .current) throws -> Int64 {
        var rec = WebSessionRecord(
            id: nil,
            startAt: start,
            endAt: nil,
            bucket: bucket,
            url: url,
            title: title,
            isIncognito: isIncognito,
            day: DayKey.string(for: start, calendar: calendar)
        )
        try dbQueue.write { db in
            try rec.insert(db)
        }
        return rec.id!
    }

    func endWebSession(id: Int64, at end: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(WebSessionRecord.databaseTableName) SET endAt = ? WHERE id = ?",
                arguments: [end, id]
            )
        }
    }

    func webDailyTotals(for date: Date, calendar: Calendar = .current,
                        asOf: Date = Date()) throws -> [WebBucketTotal] {
        let dayKey = DayKey.string(for: date, calendar: calendar)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bucket,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(WebSessionRecord.databaseTableName)
                WHERE day = ?
                GROUP BY bucket
                ORDER BY seconds DESC
                """, arguments: [asOf, dayKey])
            return rows.map { row in
                WebBucketTotal(bucket: row["bucket"], seconds: row["seconds"] ?? 0)
            }
        }
    }

    func allWebSessions() throws -> [WebSessionRecord] {
        try dbQueue.read { db in try WebSessionRecord.fetchAll(db) }
    }

    // MARK: - App categories (SPEC §F5)

    func setCategory(_ category: AppCategory, forBundleID bundleID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(AppCategoryRecord.databaseTableName) (bundleID, category)
                VALUES (?, ?)
                ON CONFLICT(bundleID) DO UPDATE SET category = excluded.category
                """, arguments: [bundleID, category.rawValue])
        }
    }

    func clearCategory(forBundleID bundleID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM \(AppCategoryRecord.databaseTableName) WHERE bundleID = ?
                """, arguments: [bundleID])
        }
    }

    func category(forBundleID bundleID: String) throws -> AppCategory? {
        try dbQueue.read { db in
            let rec = try AppCategoryRecord
                .filter(AppCategoryRecord.Columns.bundleID == bundleID)
                .fetchOne(db)
            return rec?.resolvedCategory
        }
    }

    func categoryMapping() throws -> [String: AppCategory] {
        try dbQueue.read { db in
            let rows = try AppCategoryRecord.fetchAll(db)
            return rows.reduce(into: [:]) { acc, r in
                if let cat = r.resolvedCategory { acc[r.bundleID] = cat }
            }
        }
    }

    /// SPEC §F5.3 — daily totals grouped by category, with an explicit `nil` bucket
    /// for unclassified apps that feeds the KPI '카테고리 미분류 비율'.
    func dailyTotalsByCategory(for date: Date, calendar: Calendar = .current,
                               asOf: Date = Date()) throws -> [CategoryTotal] {
        let appTotals = try dailyTotals(for: date, calendar: calendar, asOf: asOf)
        let mapping = try categoryMapping()
        var bucket: [AppCategory?: TimeInterval] = [:]
        for total in appTotals {
            let cat = mapping[total.bundleID]
            bucket[cat, default: 0] += total.seconds
        }
        // Stable order: defined enum order first, then unclassified at the end.
        let ordered = AppCategory.allCases.compactMap { cat -> CategoryTotal? in
            guard let seconds = bucket[cat] else { return nil }
            return CategoryTotal(category: cat, seconds: seconds)
        }
        if let unclassified = bucket[nil] {
            return ordered + [CategoryTotal(category: nil, seconds: unclassified)]
        }
        return ordered
    }
}

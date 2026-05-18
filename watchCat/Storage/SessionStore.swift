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
        migrator.registerMigration("v5_web_browser_bundle_id") { db in
            // Multi-browser support (Chrome + Safari + Whale). Existing rows
            // were all Chrome by definition — default the column so historical
            // data keeps a correct attribution without forcing a reset.
            try db.alter(table: WebSessionRecord.databaseTableName) { t in
                t.add(column: "browserBundleID", .text)
                    .notNull()
                    .defaults(to: BrowserKind.chrome.bundleID)
            }
            try db.create(index: "idx_web_sessions_day_browser",
                          on: WebSessionRecord.databaseTableName,
                          columns: ["day", "browserBundleID"])
        }
        migrator.registerMigration("v6_user_categories") { db in
            // User-editable category definitions. Built-in IDs match the v3
            // enum raw values so existing app_categories rows keep resolving.
            try db.create(table: AppCategoryDefinitionRecord.databaseTableName) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            for cat in AppCategory.builtIns {
                try db.execute(sql: """
                    INSERT INTO \(AppCategoryDefinitionRecord.databaseTableName)
                    (id, name, colorHex, sortOrder) VALUES (?, ?, ?, ?)
                    """, arguments: [cat.id, cat.name, cat.colorHex, cat.sortOrder])
            }
        }
        migrator.registerMigration("v7_off_intervals") { db in
            // 맥이 꺼져 있던(슬립/종료) 구간을 별도 테이블로 보존. 활동 갭에서
            // "꺼짐"만 따로 색·라벨로 표시하기 위함.
            try db.create(table: OffIntervalRecord.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startAt", .datetime).notNull().indexed()
                t.column("endAt", .datetime)
            }
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

    // MARK: - Off intervals (system sleep / shutdown)

    /// 새 "꺼짐" 구간을 시작. NSWorkspace.willSleepNotification 시점에 호출.
    /// 반환된 id로 wake 이벤트 시 `endOffInterval`을 호출해 닫는다.
    @discardableResult
    func startOffInterval(at start: Date) throws -> Int64 {
        var rec = OffIntervalRecord(id: nil, startAt: start, endAt: nil)
        try dbQueue.write { db in try rec.insert(db) }
        return rec.id!
    }

    func endOffInterval(id: Int64, at end: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(OffIntervalRecord.databaseTableName) SET endAt = ? WHERE id = ?",
                arguments: [end, id]
            )
        }
    }

    /// 앱 시작 시 호출. 부팅 시각을 기준으로 두 가지를 처리한다:
    ///   1. `endAt IS NULL`인 off interval은 wake 이벤트를 못 받았다는 뜻 →
    ///      가장 늦은 시각(부팅 시각 vs startAt)으로 닫는다.
    ///   2. 마지막 session/off의 종료 시각 ~ `bootTime` 사이가 비어 있으면,
    ///      그 사이 맥이 꺼져 있었던 것이므로 off_interval로 사후 기록한다.
    /// `bootTime`은 `kern.boottime`에서 얻은 시스템 부팅 시각. nil이면 (2)는 skip.
    func reconcileOffIntervalsAtLaunch(bootTime: Date?, now: Date = Date()) throws {
        try dbQueue.write { db in
            // (1) 강제 종료/충돌로 닫히지 못한 슬립 구간을 정리.
            try db.execute(sql: """
                UPDATE \(OffIntervalRecord.databaseTableName)
                SET endAt = MAX(startAt, ?)
                WHERE endAt IS NULL
                """, arguments: [bootTime ?? now])

            guard let bootTime else { return }

            // (2) 마지막 활동/슬립 종료 시각 이후 ~ 부팅 직전 사이를 한 덩어리
            //     꺼짐 구간으로 기록. 두 테이블 중 가장 최근 종료 시각을 사용.
            let lastSessionEnd = try Date.fetchOne(db, sql: """
                SELECT MAX(COALESCE(endAt, startAt))
                FROM \(SessionRecord.databaseTableName)
                """)
            let lastOffEnd = try Date.fetchOne(db, sql: """
                SELECT MAX(COALESCE(endAt, startAt))
                FROM \(OffIntervalRecord.databaseTableName)
                """)
            let candidates = [lastSessionEnd, lastOffEnd].compactMap { $0 }
            guard let lastEnd = candidates.max() else { return }
            // 새 부팅 시각이 마지막 활동 이후 + 충분히 떨어져 있어야 의미있는
            // 갭. 30초 이내면 잡음(앱 재기동 직전 종료)으로 보고 skip.
            guard bootTime.timeIntervalSince(lastEnd) > 30 else { return }
            try db.execute(sql: """
                INSERT INTO \(OffIntervalRecord.databaseTableName) (startAt, endAt)
                VALUES (?, ?)
                """, arguments: [lastEnd, bootTime])
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
    /// Apps used for less than this many seconds in the aggregation period
    /// are excluded from every per-app surface (lists, totals, categories).
    /// Brief "just passing through" launches are noise — they crowd the list
    /// without telling the user anything useful.
    static let minimumAppSeconds: TimeInterval = 60

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
                HAVING seconds >= ?
                ORDER BY seconds DESC
                """, arguments: [asOf, dayKey, Self.minimumAppSeconds])
            return rows.map { row in
                AppTotal(
                    bundleID: row["bundleID"],
                    displayName: row["displayName"],
                    seconds: row["seconds"] ?? 0
                )
            }
        }
    }

    /// Merged active intervals for the given day as fractions [0, 1] of the
    /// 24-hour window (midnight → next midnight). Open sessions clamp at
    /// `asOf`. Sessions outside the day are clipped at the boundaries so the
    /// menubar timeline never extends past 24:00 or wraps to the next day.
    func dailyActivityIntervals(for date: Date, calendar: Calendar = .current,
                                asOf: Date = Date()) throws -> [(start: Double, end: Double)] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayKey = DayKey.string(for: date, calendar: calendar)
        let raw: [(Date, Date)] = try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startAt, COALESCE(endAt, ?) AS endAt
                FROM \(SessionRecord.databaseTableName)
                WHERE day = ?
                """, arguments: [asOf, dayKey])
            return rows.map { (($0["startAt"] as Date), ($0["endAt"] as Date)) }
        }
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return [] }
        // Clip to the day window, drop empties, then merge overlapping.
        let clipped: [(Double, Double)] = raw.compactMap { (s, e) in
            let cs = max(s, dayStart)
            let ce = min(e, dayEnd)
            guard ce > cs else { return nil }
            return (cs.timeIntervalSince(dayStart) / span,
                    ce.timeIntervalSince(dayStart) / span)
        }
        .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for iv in clipped {
            if var last = merged.last, iv.0 <= last.1 {
                last.1 = max(last.1, iv.1)
                merged[merged.count - 1] = last
            } else {
                merged.append(iv)
            }
        }
        return merged
    }

    /// `dailyActivityIntervals`의 자매 메서드. `off_intervals` 테이블에 저장된
    /// 슬립/종료 구간을 같은 [0, 1] fraction 형태로 반환. 활동 인터벌과 함께
    /// 타임라인에 그려 휴식 영역에서 꺼짐만 분리해 표시한다.
    func dailyOffIntervals(for date: Date, calendar: Calendar = .current,
                           asOf: Date = Date()) throws -> [(start: Double, end: Double)] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let raw: [(Date, Date)] = try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startAt, COALESCE(endAt, ?) AS endAt
                FROM \(OffIntervalRecord.databaseTableName)
                WHERE startAt < ? AND COALESCE(endAt, ?) > ?
                """, arguments: [asOf, dayEnd, asOf, dayStart])
            return rows.map { (($0["startAt"] as Date), ($0["endAt"] as Date)) }
        }
        let span = dayEnd.timeIntervalSince(dayStart)
        guard span > 0 else { return [] }
        let clipped: [(Double, Double)] = raw.compactMap { (s, e) in
            let cs = max(s, dayStart)
            let ce = min(e, dayEnd)
            guard ce > cs else { return nil }
            return (cs.timeIntervalSince(dayStart) / span,
                    ce.timeIntervalSince(dayStart) / span)
        }
        .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for iv in clipped {
            if var last = merged.last, iv.0 <= last.1 {
                last.1 = max(last.1, iv.1)
                merged[merged.count - 1] = last
            } else {
                merged.append(iv)
            }
        }
        return merged
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
                        isIncognito: Bool,
                        browserBundleID: String = BrowserKind.chrome.bundleID,
                        calendar: Calendar = .current) throws -> Int64 {
        var rec = WebSessionRecord(
            id: nil,
            startAt: start,
            endAt: nil,
            bucket: bucket,
            url: url,
            title: title,
            isIncognito: isIncognito,
            browserBundleID: browserBundleID,
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

    /// Web bucket totals for a single day. When `browserBundleID` is provided,
    /// only sessions originating from that browser are counted — used by the
    /// status menu to attribute page rows under the correct browser. With
    /// `nil`, the result spans every browser.
    func webDailyTotals(for date: Date, browserBundleID: String? = nil,
                        calendar: Calendar = .current,
                        asOf: Date = Date()) throws -> [WebBucketTotal] {
        let dayKey = DayKey.string(for: date, calendar: calendar)
        return try dbQueue.read { db in
            var sql = """
                SELECT bucket,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(WebSessionRecord.databaseTableName)
                WHERE day = ?
                """
            var args: [DatabaseValueConvertible] = [asOf, dayKey]
            if let browserBundleID {
                sql += " AND browserBundleID = ?"
                args.append(browserBundleID)
            }
            sql += " GROUP BY bucket ORDER BY seconds DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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
                """, arguments: [bundleID, category.id])
        }
    }

    func clearCategory(forBundleID bundleID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM \(AppCategoryRecord.databaseTableName) WHERE bundleID = ?
                """, arguments: [bundleID])
        }
    }

    /// Resolved bundleID → AppCategory map. Joins `app_categories` against
    /// `app_category_definitions` so callers get fully-populated structs
    /// (name + color) without a second lookup.
    func categoryMapping() throws -> [String: AppCategory] {
        try dbQueue.read { db in
            let rows = try AppCategoryRecord.fetchAll(db)
            let defs = try AppCategoryDefinitionRecord.fetchAll(db)
            let byID: [String: AppCategory] = Dictionary(uniqueKeysWithValues: defs.map {
                ($0.id, AppCategory(id: $0.id, name: $0.name,
                                    colorHex: $0.colorHex, sortOrder: $0.sortOrder))
            })
            return rows.reduce(into: [:]) { acc, r in
                if let cat = byID[r.category] { acc[r.bundleID] = cat }
            }
        }
    }

    // MARK: - Category definitions CRUD

    func listCategories() throws -> [AppCategory] {
        try dbQueue.read { db in
            try AppCategoryDefinitionRecord
                .order(AppCategoryDefinitionRecord.Columns.sortOrder.asc,
                       AppCategoryDefinitionRecord.Columns.name.asc)
                .fetchAll(db)
                .map { AppCategory(id: $0.id, name: $0.name,
                                   colorHex: $0.colorHex, sortOrder: $0.sortOrder) }
        }
    }

    @discardableResult
    func createCategory(name: String, colorHex: String) throws -> AppCategory {
        let id = UUID().uuidString
        let nextOrder = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sortOrder), -1) + 1
                FROM \(AppCategoryDefinitionRecord.databaseTableName)
                """) ?? 0
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO \(AppCategoryDefinitionRecord.databaseTableName)
                (id, name, colorHex, sortOrder) VALUES (?, ?, ?, ?)
                """, arguments: [id, name, colorHex, nextOrder])
        }
        return AppCategory(id: id, name: name, colorHex: colorHex, sortOrder: nextOrder)
    }

    func updateCategoryDefinition(id: String, name: String, colorHex: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE \(AppCategoryDefinitionRecord.databaseTableName)
                SET name = ?, colorHex = ?
                WHERE id = ?
                """, arguments: [name, colorHex, id])
        }
    }

    /// Persists a new ordering. `ids` is expected to contain every category
    /// in the desired order; any category not in the list keeps its current
    /// sortOrder (defensive against the UI passing a partial list during a
    /// concurrent edit). All rewrites happen in one transaction.
    func reorderCategories(ids: [String]) throws {
        try dbQueue.write { db in
            for (idx, id) in ids.enumerated() {
                try db.execute(sql: """
                    UPDATE \(AppCategoryDefinitionRecord.databaseTableName)
                    SET sortOrder = ? WHERE id = ?
                    """, arguments: [idx, id])
            }
        }
    }

    /// Deletes a category definition. Apps mapped to it become unclassified
    /// (their `app_categories` rows are removed in the same transaction).
    func deleteCategoryDefinition(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM \(AppCategoryRecord.databaseTableName) WHERE category = ?
                """, arguments: [id])
            try db.execute(sql: """
                DELETE FROM \(AppCategoryDefinitionRecord.databaseTableName) WHERE id = ?
                """, arguments: [id])
        }
    }

    /// SPEC §F5.3 — daily totals grouped by category, with an explicit `nil` bucket
    /// for unclassified apps that feeds the KPI '카테고리 미분류 비율'.
    func dailyTotalsByCategory(for date: Date, calendar: Calendar = .current,
                               asOf: Date = Date()) throws -> [CategoryTotal] {
        let appTotals = try dailyTotals(for: date, calendar: calendar, asOf: asOf)
        let mapping = try categoryMapping()
        let categories = try listCategories()
        var bucket: [String?: TimeInterval] = [:]
        for total in appTotals {
            let id = mapping[total.bundleID]?.id
            bucket[id, default: 0] += total.seconds
        }
        let ordered: [CategoryTotal] = categories.compactMap { cat in
            guard let seconds = bucket[cat.id] else { return nil }
            return CategoryTotal(category: cat, seconds: seconds)
        }
        if let unclassified = bucket[nil] {
            return ordered + [CategoryTotal(category: nil, seconds: unclassified)]
        }
        return ordered
    }
}

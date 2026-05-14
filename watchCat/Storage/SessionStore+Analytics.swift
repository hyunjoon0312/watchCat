import Foundation
import GRDB

// MARK: - Aggregation result types

/// Per-day series point (used for stacked bar / line charts).
struct DailySeriesPoint: Equatable {
    let day: String              // YYYY-MM-DD
    let seconds: TimeInterval
}

/// Per-app totals broken out per day, for top-N stacked charts. `daily` is
/// keyed by day-string; missing days are absent (call site fills zeros via
/// `DayRange.enumerateDayKeys()`).
struct AppDailySeries: Equatable {
    let bundleID: String
    let displayName: String
    let totalSeconds: TimeInterval
    let daily: [String: TimeInterval]
}

/// Single (hour-of-day, weekday) cell for the productivity heatmap.
/// `hour` is 0..23 in the local calendar; `weekday` is 1=Mon..7=Sun.
struct HeatmapCell: Equatable {
    let weekday: Int
    let hour: Int
    let seconds: TimeInterval
}

extension SessionStore {

    // MARK: - Range queries (app sessions)

    /// Per-app totals across a closed day range. Open sessions count `asOf - startAt`
    /// just like `dailyTotals(for:)` so live data shows up immediately.
    func appTotals(in range: DayRange, asOf: Date = Date()) throws -> [AppTotal] {
        let (first, last) = range.dayKeys
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bundleID, displayName,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                GROUP BY bundleID, displayName
                ORDER BY seconds DESC
                """, arguments: [asOf, first, last])
            return rows.map {
                AppTotal(bundleID: $0["bundleID"], displayName: $0["displayName"],
                         seconds: $0["seconds"] ?? 0)
            }
        }
    }

    /// Total active seconds for the range.
    func totalSeconds(in range: DayRange, asOf: Date = Date()) throws -> TimeInterval {
        try appTotals(in: range, asOf: asOf).reduce(0) { $0 + $1.seconds }
    }

    /// One series point per day (sum across all apps).
    func dailySeries(in range: DayRange, asOf: Date = Date()) throws -> [DailySeriesPoint] {
        let (first, last) = range.dayKeys
        let rows: [String: TimeInterval] = try dbQueue.read { db in
            let raw = try Row.fetchAll(db, sql: """
                SELECT day,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                GROUP BY day
                """, arguments: [asOf, first, last])
            var out: [String: TimeInterval] = [:]
            for r in raw { out[r["day"]] = r["seconds"] ?? 0 }
            return out
        }
        return range.enumerateDayKeys().map { DailySeriesPoint(day: $0, seconds: rows[$0] ?? 0) }
    }

    /// Top-N apps with per-day breakdown for stacked charts.
    func topAppDailySeries(in range: DayRange, limit: Int = 5,
                           asOf: Date = Date()) throws -> [AppDailySeries] {
        let topApps = Array(try appTotals(in: range, asOf: asOf).prefix(limit))
        guard !topApps.isEmpty else { return [] }
        let (first, last) = range.dayKeys
        let bundleIDs = topApps.map(\.bundleID)
        let placeholders = bundleIDs.map { _ in "?" }.joined(separator: ",")
        var args: [DatabaseValueConvertible] = [asOf, first, last]
        args.append(contentsOf: bundleIDs)
        let perBundle: [String: [String: TimeInterval]] = try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bundleID, day,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                  AND bundleID IN (\(placeholders))
                GROUP BY bundleID, day
                """, arguments: StatementArguments(args))
            var out: [String: [String: TimeInterval]] = [:]
            for r in rows {
                let bid: String = r["bundleID"]
                let day: String = r["day"]
                let sec: TimeInterval = r["seconds"] ?? 0
                out[bid, default: [:]][day] = sec
            }
            return out
        }
        return topApps.map { app in
            AppDailySeries(bundleID: app.bundleID, displayName: app.displayName,
                           totalSeconds: app.seconds,
                           daily: perBundle[app.bundleID] ?? [:])
        }
    }

    /// Category-bucketed totals across the range. `nil` category = unclassified.
    func categoryTotals(in range: DayRange, asOf: Date = Date()) throws -> [CategoryTotal] {
        let apps = try appTotals(in: range, asOf: asOf)
        let mapping = try categoryMapping()
        let categories = try listCategories()
        var bucket: [String?: TimeInterval] = [:]
        for t in apps {
            bucket[mapping[t.bundleID]?.id, default: 0] += t.seconds
        }
        var ordered: [CategoryTotal] = categories.compactMap { cat in
            guard let s = bucket[cat.id] else { return nil }
            return CategoryTotal(category: cat, seconds: s)
        }
        if let unclassified = bucket[nil] {
            ordered.append(CategoryTotal(category: nil, seconds: unclassified))
        }
        return ordered
    }

    /// Web bucket totals across the range (SPEC §F3). Filters by `browserBundleID`
    /// when set (e.g., to attribute page rows under a specific browser in the
    /// dashboard); `nil` aggregates every browser like the old behavior.
    func webBucketTotals(in range: DayRange, browserBundleID: String? = nil,
                         asOf: Date = Date()) throws -> [WebBucketTotal] {
        let (first, last) = range.dayKeys
        return try dbQueue.read { db in
            var sql = """
                SELECT bucket,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(WebSessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                """
            var args: [DatabaseValueConvertible] = [asOf, first, last]
            if let browserBundleID {
                sql += " AND browserBundleID = ?"
                args.append(browserBundleID)
            }
            sql += " GROUP BY bucket ORDER BY seconds DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { WebBucketTotal(bucket: $0["bucket"], seconds: $0["seconds"] ?? 0) }
        }
    }

    /// Productivity heatmap (hour × weekday). We compute by walking sessions in
    /// the range and splitting each session into hour buckets in the local
    /// calendar. Open sessions are clamped at `asOf`.
    ///
    /// This walks sessions in app-memory rather than pure SQL because SQLite
    /// lacks a portable, calendar-aware hour-of-day function in our build, and
    /// the row counts in a single user's day-range are small enough to stay fast.
    func hourWeekdayHeatmap(in range: DayRange, calendar: Calendar = .current,
                             asOf: Date = Date()) throws -> [HeatmapCell] {
        let (first, last) = range.dayKeys
        let sessions: [(Date, Date)] = try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startAt, COALESCE(endAt, ?) AS endAt
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                """, arguments: [asOf, first, last])
            return rows.map { (($0["startAt"] as Date), ($0["endAt"] as Date)) }
        }

        // Bucket: weekday(1..7) × hour(0..23) → seconds
        var grid: [[TimeInterval]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var cal = calendar
        cal.firstWeekday = 2  // Monday

        let rangeStart = range.startInstant
        let rangeEnd = range.endInstantExclusive

        for (s, e) in sessions {
            var cursor = max(s, rangeStart)
            let stop = min(e, rangeEnd)
            while cursor < stop {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: cursor)
                let hour = comps.hour ?? 0
                // weekday of the date piece (1=Sun..7=Sat in default cal)
                let sysWeekday = cal.component(.weekday, from: cursor)
                // remap to Mon=1..Sun=7
                let weekday = ((sysWeekday + 5) % 7) + 1
                // end of this hour
                let hourStart = cal.date(from: comps) ?? cursor
                let hourEnd = cal.date(byAdding: .hour, value: 1, to: hourStart) ?? stop
                let chunkEnd = min(stop, hourEnd)
                let dur = chunkEnd.timeIntervalSince(cursor)
                if dur > 0 {
                    grid[weekday - 1][hour] += dur
                }
                cursor = chunkEnd
            }
        }

        var cells: [HeatmapCell] = []
        cells.reserveCapacity(24 * 7)
        for w in 0..<7 {
            for h in 0..<24 {
                cells.append(HeatmapCell(weekday: w + 1, hour: h, seconds: grid[w][h]))
            }
        }
        return cells
    }

    /// Per-hour seconds across the range — 24 entries (0..23) in clock order, with
    /// missing hours filled in as 0. Used by the dashboard's day-mode 24h timeline.
    ///
    /// Sessions that straddle hour boundaries are split proportionally so a 90-minute
    /// span at 09:30→11:00 contributes 30/60/0 across hours 9, 10, 11.
    func hourlyTotals(in range: DayRange, calendar: Calendar = .current,
                      asOf: Date = Date()) throws -> [DailySeriesPoint] {
        let cells = try hourWeekdayHeatmap(in: range, calendar: calendar, asOf: asOf)
        var perHour: [Int: TimeInterval] = [:]
        for cell in cells { perHour[cell.hour, default: 0] += cell.seconds }
        return (0..<24).map {
            DailySeriesPoint(day: String(format: "%02d", $0), seconds: perHour[$0] ?? 0)
        }
    }

    // MARK: - Retention

    /// Delete rows older than `days` calendar days (counted off `now`). `days == 0`
    /// is treated as "retain forever" and skips deletion entirely so users can opt
    /// out of automatic pruning without losing data.
    ///
    /// Returns the total number of rows removed across all tables (sessions + web).
    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date(),
               calendar: Calendar = .current) throws -> Int {
        guard days > 0 else { return 0 }
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
            return 0
        }
        let cutoffKey = DayKey.string(for: cutoff, calendar: calendar)
        return try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM \(SessionRecord.databaseTableName) WHERE day < ?
                """, arguments: [cutoffKey])
            let s = db.changesCount
            try db.execute(sql: """
                DELETE FROM \(WebSessionRecord.databaseTableName) WHERE day < ?
                """, arguments: [cutoffKey])
            let w = db.changesCount
            return s + w
        }
    }
}

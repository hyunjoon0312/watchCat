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

/// One sample of cumulative active seconds at `minute` minutes past midnight.
/// Used by the day-mode "오늘 vs 어제 누적 활성도" chart.
struct CumulativeMinutePoint: Equatable {
    let minute: Int
    let seconds: TimeInterval
}

/// "Time to first break" insight — the user's first continuous activity span
/// of the day, plus the 14-day baseline for "평소 N분 만에 쉼" comparison.
struct FirstBreakInsight: Equatable {
    let span: (start: Date, end: Date)
    /// Average across the last 14 days excluding `span.start`'s day. `nil` when
    /// no prior day had any activity (e.g., first day of use) — the UI shows
    /// the today number alone without a comparison chip.
    let baselineSeconds: TimeInterval?
    var seconds: TimeInterval { span.end.timeIntervalSince(span.start) }

    static func == (lhs: FirstBreakInsight, rhs: FirstBreakInsight) -> Bool {
        lhs.span.start == rhs.span.start
            && lhs.span.end == rhs.span.end
            && lhs.baselineSeconds == rhs.baselineSeconds
    }
}

/// "Longest deep-work span" insight — longest continuous activity block of
/// the day (any app), plus the 14-day baseline for "평소 최장 N분" comparison.
struct LongestSpanInsight: Equatable {
    let span: (start: Date, end: Date)
    let baselineSeconds: TimeInterval?
    var seconds: TimeInterval { span.end.timeIntervalSince(span.start) }

    static func == (lhs: LongestSpanInsight, rhs: LongestSpanInsight) -> Bool {
        lhs.span.start == rhs.span.start
            && lhs.span.end == rhs.span.end
            && lhs.baselineSeconds == rhs.baselineSeconds
    }
}

extension SessionStore {

    // MARK: - Range queries (app sessions)

    /// Per-app totals across a closed day range. Open sessions count `asOf - startAt`
    /// just like `dailyTotals(for:)` so live data shows up immediately. Apps with
    /// total time below `SessionStore.minimumAppSeconds` are filtered out (short
    /// pass-through launches are noise — see SessionStore for the rationale).
    func appTotals(in range: DayRange, asOf: Date = Date()) throws -> [AppTotal] {
        let (first, last) = range.dayKeys
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bundleID, displayName,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                GROUP BY bundleID, displayName
                HAVING seconds >= ?
                ORDER BY seconds DESC
                """, arguments: [asOf, first, last, SessionStore.minimumAppSeconds])
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

    /// One series point per day (sum across all apps that pass the minimum-
    /// duration threshold, so the chart total matches the app-list total).
    func dailySeries(in range: DayRange, asOf: Date = Date()) throws -> [DailySeriesPoint] {
        let (first, last) = range.dayKeys
        let rows: [String: TimeInterval] = try dbQueue.read { db in
            let raw = try Row.fetchAll(db, sql: """
                SELECT day,
                       SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) AS seconds
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                  AND bundleID IN (
                    SELECT bundleID FROM \(SessionRecord.databaseTableName)
                    WHERE day BETWEEN ? AND ?
                    GROUP BY bundleID
                    HAVING SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) >= ?
                  )
                GROUP BY day
                """, arguments: [asOf, first, last, first, last, asOf, SessionStore.minimumAppSeconds])
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
            // Same threshold filter as appTotals — keep the heatmap and the
            // hourly chart consistent with the app list. Sessions from
            // short-use apps are dropped before they reach the bucketing loop.
            let rows = try Row.fetchAll(db, sql: """
                SELECT startAt, COALESCE(endAt, ?) AS endAt
                FROM \(SessionRecord.databaseTableName)
                WHERE day BETWEEN ? AND ?
                  AND bundleID IN (
                    SELECT bundleID FROM \(SessionRecord.databaseTableName)
                    WHERE day BETWEEN ? AND ?
                    GROUP BY bundleID
                    HAVING SUM((julianday(COALESCE(endAt, ?)) - julianday(startAt)) * 86400.0) >= ?
                  )
                """, arguments: [asOf, first, last, first, last, asOf, SessionStore.minimumAppSeconds])
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

    /// Cumulative active seconds sampled every `stepMinutes` from midnight.
    /// For "today" (calendar-same-day as `asOf`) the series stops at the
    /// current minute so the line doesn't visually project a flat extension
    /// into the future. Past days run the full 24h.
    func cumulativeMinuteSeries(for date: Date, stepMinutes: Int = 5,
                                calendar: Calendar = .current,
                                asOf: Date = Date()) throws -> [CumulativeMinutePoint] {
        let spans = try dailyActivitySpans(for: date, calendar: calendar, asOf: asOf)
        let dayStart = calendar.startOfDay(for: date)
        let isToday = calendar.isDate(date, inSameDayAs: asOf)
        let maxMinute: Int = {
            if isToday {
                let mins = Int(asOf.timeIntervalSince(dayStart) / 60)
                return max(0, min(1440, mins))
            }
            return 1440
        }()
        let step = max(1, stepMinutes)
        var out: [CumulativeMinutePoint] = []
        var minute = 0
        while minute <= maxMinute {
            let cutoff = dayStart.addingTimeInterval(TimeInterval(minute) * 60)
            var cum: TimeInterval = 0
            for span in spans {
                if span.start >= cutoff { break }  // spans are sorted by start
                cum += min(span.end, cutoff).timeIntervalSince(span.start)
            }
            out.append(CumulativeMinutePoint(minute: minute, seconds: cum))
            minute += step
        }
        return out
    }

    // MARK: - Day-rhythm insights

    /// "First break" + 14-day baseline for the given day. Returns `nil` when
    /// the day has no activity at all.
    func firstBreakInsight(on date: Date, baselineDays: Int = 14,
                           calendar: Calendar = .current,
                           asOf: Date = Date()) throws -> FirstBreakInsight? {
        guard let span = try dailyActivitySpans(for: date, calendar: calendar, asOf: asOf).first
            else { return nil }
        let baseline = try averageDailyMetric(endingBefore: date, days: baselineDays,
                                              calendar: calendar, asOf: asOf) { day in
            try dailyActivitySpans(for: day, calendar: calendar, asOf: asOf).first
                .map { $0.end.timeIntervalSince($0.start) }
        }
        return FirstBreakInsight(span: span, baselineSeconds: baseline)
    }

    /// "Longest continuous span" + 14-day baseline for the given day.
    func longestSpanInsight(on date: Date, baselineDays: Int = 14,
                            calendar: Calendar = .current,
                            asOf: Date = Date()) throws -> LongestSpanInsight? {
        let spans = try dailyActivitySpans(for: date, calendar: calendar, asOf: asOf)
        guard let longest = spans.max(by: {
            $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start)
        }) else { return nil }
        let baseline = try averageDailyMetric(endingBefore: date, days: baselineDays,
                                              calendar: calendar, asOf: asOf) { day in
            try dailyActivitySpans(for: day, calendar: calendar, asOf: asOf)
                .map { $0.end.timeIntervalSince($0.start) }.max()
        }
        return LongestSpanInsight(span: longest, baselineSeconds: baseline)
    }

    /// Average a per-day metric over `days` calendar days ending just before
    /// `referenceDay`. Days where `compute` returns nil are skipped so a string
    /// of zero-activity days doesn't drag the "평소" baseline toward 0.
    private func averageDailyMetric(endingBefore referenceDay: Date, days: Int,
                                    calendar: Calendar, asOf: Date,
                                    _ compute: (Date) throws -> TimeInterval?) throws -> TimeInterval? {
        let refStart = calendar.startOfDay(for: referenceDay)
        var values: [TimeInterval] = []
        for offset in 1...max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: refStart)
                else { continue }
            if let v = try compute(day) { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
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

import XCTest
@testable import watchCat

final class AnalyticsQueriesTests: XCTestCase {
    private func makeStore() throws -> SessionStore { try SessionStore() }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c)!
    }

    /// Inserts a closed session row and returns its end timestamp for follow-up.
    @discardableResult
    private func add(_ store: SessionStore, day: Date, hourOffset: Int, durationMin: Int,
                     bundleID: String, name: String) throws -> Date {
        let start = Calendar.current.date(byAdding: .hour, value: hourOffset,
                                          to: Calendar.current.startOfDay(for: day))!
        let id = try store.startSession(at: start, bundleID: bundleID, displayName: name)
        let end = start.addingTimeInterval(TimeInterval(durationMin * 60))
        try store.endSession(id: id, at: end)
        return end
    }

    func test_appTotals_overWeek_sumsAcrossDays() throws {
        let store = try makeStore()
        let mon = date(2026, 5, 11)
        let tue = date(2026, 5, 12)
        try add(store, day: mon, hourOffset: 9, durationMin: 30, bundleID: "x", name: "Xcode")  // 30
        try add(store, day: tue, hourOffset: 9, durationMin: 45, bundleID: "x", name: "Xcode")  // 45
        try add(store, day: mon, hourOffset: 10, durationMin: 15, bundleID: "c", name: "Chrome")
        let week = DashboardRange.week(containing: mon)
        let totals = try store.appTotals(in: week)
        let xcode = totals.first { $0.bundleID == "x" }
        XCTAssertEqual(xcode?.seconds ?? -1, Double((30 + 45) * 60), accuracy: 0.5)
    }

    func test_dailySeries_fillsMissingDaysWithZero() throws {
        let store = try makeStore()
        let mon = date(2026, 5, 11)
        try add(store, day: mon, hourOffset: 9, durationMin: 10, bundleID: "x", name: "Xcode")
        // Skip Tue–Sun
        try add(store, day: date(2026, 5, 14), hourOffset: 9, durationMin: 20, bundleID: "x", name: "Xcode")

        let week = DashboardRange.week(containing: mon)
        let series = try store.dailySeries(in: week)
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series[0].day, "2026-05-11")
        XCTAssertEqual(series[0].seconds, 600, accuracy: 0.5)
        XCTAssertEqual(series[1].seconds, 0)  // Tuesday is zero, not missing
        XCTAssertEqual(series[3].seconds, 1200, accuracy: 0.5)  // Thursday
    }

    func test_topAppDailySeries_returnsAtMostNApps_withPerDayBreakdown() throws {
        let store = try makeStore()
        let day = date(2026, 5, 13)
        try add(store, day: day, hourOffset: 9, durationMin: 100, bundleID: "a", name: "A")
        try add(store, day: day, hourOffset: 11, durationMin: 50, bundleID: "b", name: "B")
        try add(store, day: day, hourOffset: 14, durationMin: 10, bundleID: "c", name: "C")
        let range = DashboardRange.day(day)
        let series = try store.topAppDailySeries(in: range, limit: 2)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].bundleID, "a")
        XCTAssertEqual(series[0].daily["2026-05-13"] ?? -1, Double(100 * 60), accuracy: 0.5)
        XCTAssertEqual(series[1].bundleID, "b")
    }

    func test_heatmap_splitsSessionsAcrossHours() throws {
        let store = try makeStore()
        // Tuesday 2026-05-12 (weekday=Tue = 2 in Mon-first scheme).
        let start = date(2026, 5, 12, 8, 30)  // 8:30
        let end = date(2026, 5, 12, 10, 15)   // ends at 10:15 → 1h45m across 3 hour buckets.
        let id = try store.startSession(at: start, bundleID: "x", displayName: "Xcode")
        try store.endSession(id: id, at: end)

        let day = DashboardRange.day(start)
        let cells = try store.hourWeekdayHeatmap(in: day)
        let tuesdayCells = cells.filter { $0.weekday == 2 }
        let h8 = tuesdayCells.first { $0.hour == 8 }
        let h9 = tuesdayCells.first { $0.hour == 9 }
        let h10 = tuesdayCells.first { $0.hour == 10 }
        // 8:30→9:00 = 30 min, 9:00→10:00 = 60 min, 10:00→10:15 = 15 min.
        XCTAssertEqual(h8?.seconds ?? -1, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(h9?.seconds ?? -1, 60 * 60, accuracy: 0.5)
        XCTAssertEqual(h10?.seconds ?? -1, 15 * 60, accuracy: 0.5)
    }

    func test_hourlyTotals_returns24BucketsAcrossRange_zeroFilled() throws {
        let store = try makeStore()
        // Two sessions on different days that share the same wall-clock hour
        // window — verifies hourlyTotals collapses across the range.
        try add(store, day: date(2026, 5, 12), hourOffset: 9, durationMin: 20,
                bundleID: "x", name: "Xcode")
        try add(store, day: date(2026, 5, 14), hourOffset: 9, durationMin: 40,
                bundleID: "x", name: "Xcode")

        let week = DashboardRange.week(containing: date(2026, 5, 12))
        let hourly = try store.hourlyTotals(in: week)
        XCTAssertEqual(hourly.count, 24)
        XCTAssertEqual(hourly[9].seconds, Double((20 + 40) * 60), accuracy: 0.5,
                       "9시 bucket should contain the union of both days")
        XCTAssertEqual(hourly[3].seconds, 0, "untouched hours stay zero")
        XCTAssertEqual(hourly[0].day, "00")
        XCTAssertEqual(hourly[23].day, "23")
    }

    func test_categoryTotals_inRange_groupsAcrossDays() throws {
        let store = try makeStore()
        try store.setCategory(.productivity, forBundleID: "x")
        try store.setCategory(.entertainment, forBundleID: "y")
        let mon = date(2026, 5, 11)
        try add(store, day: mon, hourOffset: 9, durationMin: 40, bundleID: "x", name: "Xcode")
        try add(store, day: date(2026, 5, 13), hourOffset: 9, durationMin: 20, bundleID: "y", name: "Spotify")
        try add(store, day: date(2026, 5, 13), hourOffset: 10, durationMin: 10, bundleID: "z", name: "Unknown")

        let week = DashboardRange.week(containing: mon)
        let cats = try store.categoryTotals(in: week)
        let prod = cats.first { $0.category == .productivity }
        let ent = cats.first { $0.category == .entertainment }
        let none = cats.first { $0.category == nil }
        XCTAssertEqual(prod?.seconds ?? -1, 40 * 60, accuracy: 0.5)
        XCTAssertEqual(ent?.seconds ?? -1, 20 * 60, accuracy: 0.5)
        XCTAssertEqual(none?.seconds ?? -1, 10 * 60, accuracy: 0.5)
    }
}

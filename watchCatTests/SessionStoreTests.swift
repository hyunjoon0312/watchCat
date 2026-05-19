import XCTest
@testable import watchCat

final class SessionStoreTests: XCTestCase {
    private func makeStore() throws -> SessionStore { try SessionStore() }

    private func dateAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = min
        return Calendar.current.date(from: comps)!
    }

    func test_dayKey_localCalendar() {
        let date = dateAt(2026, 5, 13, 10, 0)
        XCTAssertEqual(DayKey.string(for: date), "2026-05-13")
    }

    func test_startAndEndSession_persistsDuration() throws {
        let store = try makeStore()
        let start = dateAt(2026, 5, 13, 9, 0)
        let id = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        try store.endSession(id: id, at: start.addingTimeInterval(600))  // 10 min

        let totals = try store.dailyTotals(for: start)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(totals[0].seconds, 600, accuracy: 0.01)
    }

    func test_dailyTotals_groupsByApp_sortedDescending() throws {
        let store = try makeStore()
        let day = dateAt(2026, 5, 13, 9, 0)
        let a = try store.startSession(at: day, bundleID: "com.apple.Safari", displayName: "Safari")
        try store.endSession(id: a, at: day.addingTimeInterval(120))
        let b = try store.startSession(at: day.addingTimeInterval(120),
                                       bundleID: "com.google.Chrome", displayName: "Chrome")
        try store.endSession(id: b, at: day.addingTimeInterval(120 + 300))
        let c = try store.startSession(at: day.addingTimeInterval(500),
                                       bundleID: "com.apple.Safari", displayName: "Safari")
        try store.endSession(id: c, at: day.addingTimeInterval(500 + 60))

        let totals = try store.dailyTotals(for: day)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].bundleID, "com.google.Chrome", "Chrome (300s) outranks Safari (180s)")
        XCTAssertEqual(totals[0].seconds, 300, accuracy: 0.01)
        XCTAssertEqual(totals[1].bundleID, "com.apple.Safari")
        XCTAssertEqual(totals[1].seconds, 180, accuracy: 0.01)
    }

    // SPEC §F2.4 — midnight-crossing session belongs entirely to its start day.
    func test_midnightBoundary_assignsToStartDay() throws {
        let store = try makeStore()
        let start = dateAt(2026, 5, 13, 23, 59)
        let end   = dateAt(2026, 5, 14, 0, 30)
        let id = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        try store.endSession(id: id, at: end)

        let day13 = try store.dailyTotals(for: start)
        XCTAssertEqual(day13.count, 1)
        // Whole 31-minute span attributed to 2026-05-13, none to 2026-05-14.
        XCTAssertEqual(day13[0].seconds, 31 * 60, accuracy: 0.5)

        let day14 = try store.dailyTotals(for: end)
        XCTAssertTrue(day14.isEmpty, "no rows should land on the end-day")
    }

    // SPEC §F4.3.1 — gaps between sessions represent paused time and must not be
    // counted toward any app's total. With session-boundary persistence we verify
    // this by leaving a gap between two sessions and asserting the totals exclude it.
    func test_pauseGapIsExcludedFromTotals() throws {
        let store = try makeStore()
        let day = dateAt(2026, 5, 13, 9, 0)
        let a = try store.startSession(at: day, bundleID: "com.apple.Safari", displayName: "Safari")
        try store.endSession(id: a, at: day.addingTimeInterval(60))   // 60s active
        // 600s gap = pause period; no row inserted
        let b = try store.startSession(at: day.addingTimeInterval(660),
                                       bundleID: "com.apple.Safari", displayName: "Safari")
        try store.endSession(id: b, at: day.addingTimeInterval(660 + 30))  // 30s active

        let totals = try store.dailyTotals(for: day)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].seconds, 90, accuracy: 0.01,
                       "only active spans (60s + 30s) count; the 600s pause gap is excluded")
    }

    // Open sessions count as `asOf - startAt`, so the menu's "today" total reflects
    // the app you're currently using live instead of showing 0 until you switch.
    func test_openSession_countsElapsedSinceStart_atAsOf() throws {
        let store = try makeStore()
        let start = dateAt(2026, 5, 13, 9, 0)
        _ = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        let now = start.addingTimeInterval(90)
        let totals = try store.dailyTotals(for: start, asOf: now)
        XCTAssertEqual(totals.first?.seconds ?? -1, 90, accuracy: 0.01)
    }

    func test_openSession_atAsOfEqualsStart_isZero() throws {
        let store = try makeStore()
        let start = dateAt(2026, 5, 13, 9, 0)
        _ = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        let totals = try store.dailyTotals(for: start, asOf: start)
        // A 0-duration open session is below `minimumAppSeconds` (60s) and is
        // filtered out of per-app aggregation — that's the regression guard:
        // the row must not surface as a negative/garbage value.
        XCTAssertTrue(totals.isEmpty)
    }

    /// Regression: prior crashes/force-quits left rows with `endAt IS NULL`. Live
    /// aggregation would count those as "still running" on every menu open and
    /// inflate every app's daily total in lockstep. `closeOrphanedSessions()` runs
    /// on startup and clamps those rows to zero length.
    func test_closeOrphanedSessions_clampsNullEndAtRowsToZeroLength() throws {
        let store = try makeStore()
        let start = dateAt(2026, 5, 13, 9, 0)
        // Three "orphans": open rows from a previous unclean exit, plus a
        // healthy closed row that should be untouched.
        _ = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        _ = try store.startSession(at: start.addingTimeInterval(10),
                                   bundleID: "com.apple.systempreferences",
                                   displayName: "시스템 설정")
        let closedID = try store.startSession(at: start.addingTimeInterval(20),
                                              bundleID: "com.dayflow.watchCat",
                                              displayName: "watchCat")
        try store.endSession(id: closedID, at: start.addingTimeInterval(50))  // 30s closed
        _ = try store.startSession(at: start.addingTimeInterval(40),
                                   bundleID: "com.dayflow.watchCat",
                                   displayName: "watchCat")

        try store.closeOrphanedSessions()

        // Inspect raw rows: `dailyTotals` would filter every row here by the
        // `minimumAppSeconds` threshold, but the regression we're guarding is
        // that orphans get clamped (endAt = startAt) so they no longer read
        // as "still running" when the next session aggregation runs.
        let rows = try store.allSessions()
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.endAt != nil },
                      "closeOrphanedSessions leaves no NULL endAt rows")
        let orphans = rows.filter { row in
            guard let end = row.endAt else { return false }
            return end == row.startAt
        }
        XCTAssertEqual(orphans.count, 3, "3 orphans clamped to zero length")
        let healthy = rows.filter { row in
            guard let end = row.endAt else { return false }
            return end != row.startAt
        }
        XCTAssertEqual(healthy.count, 1)
        XCTAssertEqual(healthy.first?.endAt?.timeIntervalSince(healthy.first!.startAt) ?? -1,
                       30, accuracy: 0.01, "healthy 30s row untouched")
    }
}

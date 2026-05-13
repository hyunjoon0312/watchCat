import XCTest
@testable import watchCat

final class WebSessionStoreTests: XCTestCase {
    private func dateAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c)!
    }

    func test_startAndEnd_persistsDuration() throws {
        let store = try SessionStore()
        let start = dateAt(2026, 5, 13, 10, 0)
        let id = try store.startWebSession(
            at: start, bucket: "github.com", url: nil, title: nil, isIncognito: false
        )
        try store.endWebSession(id: id, at: start.addingTimeInterval(120))
        let totals = try store.webDailyTotals(for: start)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].bucket, "github.com")
        XCTAssertEqual(totals[0].seconds, 120, accuracy: 0.01)
    }

    func test_dailyTotals_groupsByBucket() throws {
        let store = try SessionStore()
        let day = dateAt(2026, 5, 13, 10, 0)
        let a = try store.startWebSession(at: day, bucket: "github.com",
                                          url: nil, title: nil, isIncognito: false)
        try store.endWebSession(id: a, at: day.addingTimeInterval(60))
        let b = try store.startWebSession(at: day.addingTimeInterval(60),
                                          bucket: "news.ycombinator.com",
                                          url: nil, title: nil, isIncognito: false)
        try store.endWebSession(id: b, at: day.addingTimeInterval(60 + 200))
        let c = try store.startWebSession(at: day.addingTimeInterval(300),
                                          bucket: "github.com",
                                          url: nil, title: nil, isIncognito: false)
        try store.endWebSession(id: c, at: day.addingTimeInterval(300 + 90))

        let totals = try store.webDailyTotals(for: day)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].bucket, "news.ycombinator.com", "200s > 150s — bigger first")
        XCTAssertEqual(totals[1].bucket, "github.com")
        XCTAssertEqual(totals[1].seconds, 150, accuracy: 0.01, "60 + 90 = 150")
    }

    func test_browserBundleID_defaultsToChrome_isPersistedExplicitly() throws {
        let store = try SessionStore()
        let day = dateAt(2026, 5, 13, 10, 0)
        // Implicit default (omitted arg).
        let chromeRowID = try store.startWebSession(at: day, bucket: "github.com",
                                                    url: nil, title: nil, isIncognito: false)
        try store.endWebSession(id: chromeRowID, at: day.addingTimeInterval(60))
        // Explicit Safari.
        let safariRowID = try store.startWebSession(
            at: day.addingTimeInterval(70), bucket: "apple.com",
            url: nil, title: nil, isIncognito: false,
            browserBundleID: BrowserKind.safari.bundleID
        )
        try store.endWebSession(id: safariRowID, at: day.addingTimeInterval(130))

        let rows = try store.allWebSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows[0].browserBundleID, BrowserKind.chrome.bundleID,
                       "omitting the arg keeps existing call sites on Chrome")
        XCTAssertEqual(rows[1].browserBundleID, BrowserKind.safari.bundleID)

        let safariOnly = try store.webDailyTotals(
            for: day, browserBundleID: BrowserKind.safari.bundleID
        )
        XCTAssertEqual(safariOnly.count, 1)
        XCTAssertEqual(safariOnly[0].bucket, "apple.com")
    }

    // SPEC §F2.4 applies to web sessions too — entire span attributed to start day.
    func test_midnightBoundary_assignsToStartDay() throws {
        let store = try SessionStore()
        let start = dateAt(2026, 5, 13, 23, 50)
        let end = dateAt(2026, 5, 14, 0, 20)
        let id = try store.startWebSession(
            at: start, bucket: "github.com", url: nil, title: nil, isIncognito: false
        )
        try store.endWebSession(id: id, at: end)
        let totals13 = try store.webDailyTotals(for: start)
        XCTAssertEqual(totals13.count, 1)
        XCTAssertEqual(totals13[0].seconds, 30 * 60, accuracy: 0.5)
        let totals14 = try store.webDailyTotals(for: end)
        XCTAssertTrue(totals14.isEmpty)
    }
}

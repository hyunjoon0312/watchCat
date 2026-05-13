import XCTest
@testable import watchCat

/// Drives `DashboardViewModel` end-to-end against a real in-memory `SessionStore`.
/// Verifies the toolbar wiring (period switching, navigation, jump-to-today, search)
/// without spinning up the SwiftUI view tree.
@MainActor
final class DashboardViewModelTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    private func makeStore() throws -> SessionStore { try SessionStore() }

    @discardableResult
    private func add(_ store: SessionStore, at start: Date, durationMin: Int,
                     bundleID: String, name: String) throws -> Date {
        let id = try store.startSession(at: start, bundleID: bundleID, displayName: name)
        let end = start.addingTimeInterval(TimeInterval(durationMin * 60))
        try store.endSession(id: id, at: end)
        return end
    }

    func test_initialState_isToday_dayPeriod() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        XCTAssertEqual(vm.period, .day)
        XCTAssertEqual(vm.range.dayCount, 1)
    }

    func test_switchingPeriod_recomputesRange() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        vm.anchor = date(2026, 5, 13)
        vm.setPeriod(.week)
        XCTAssertEqual(vm.range.dayCount, 7)
        XCTAssertEqual(DayKey.string(for: vm.range.start), "2026-05-11")
        vm.setPeriod(.month)
        XCTAssertEqual(vm.range.dayCount, 31)
        XCTAssertEqual(DayKey.string(for: vm.range.start), "2026-05-01")
    }

    func test_step_movesAnchor_byOnePeriod() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        vm.anchor = date(2026, 5, 13)
        vm.setPeriod(.week)
        vm.step(by: 1)
        XCTAssertEqual(DayKey.string(for: vm.range.start), "2026-05-18")
        vm.step(by: -2)
        XCTAssertEqual(DayKey.string(for: vm.range.start), "2026-05-04")
    }

    func test_jumpToToday_resetsAnchor() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        vm.anchor = date(2020, 1, 1)
        vm.jumpToToday()
        let today = DayKey.string(for: Date())
        XCTAssertEqual(DayKey.string(for: vm.range.start), today)
    }

    func test_reload_populatesAggregates() throws {
        let store = try makeStore()
        let d = date(2026, 5, 13)
        try add(store, at: d, durationMin: 30, bundleID: "x", name: "Xcode")
        try add(store, at: d.addingTimeInterval(3000), durationMin: 15,
                bundleID: "c", name: "Chrome")
        let vm = DashboardViewModel(store: store)
        vm.anchor = d
        vm.setPeriod(.day)
        vm.reload()
        XCTAssertEqual(vm.appTotals.count, 2)
        XCTAssertEqual(vm.totalSeconds, Double((30 + 15) * 60), accuracy: 0.5)
        XCTAssertEqual(vm.topApp?.bundleID, "x")
    }

    func test_searchFilter_isAppliedToBothAppsAndWeb() throws {
        let store = try makeStore()
        let d = date(2026, 5, 13)
        try add(store, at: d, durationMin: 10, bundleID: "com.apple.dt.Xcode", name: "Xcode")
        try add(store, at: d.addingTimeInterval(700), durationMin: 5,
                bundleID: "com.notion.app", name: "Notion")
        let webID = try store.startWebSession(at: d.addingTimeInterval(800),
                                              bucket: "github.com", url: nil,
                                              title: nil, isIncognito: false)
        try store.endWebSession(id: webID, at: d.addingTimeInterval(900))
        let webID2 = try store.startWebSession(at: d.addingTimeInterval(910),
                                               bucket: "example.com", url: nil,
                                               title: nil, isIncognito: false)
        try store.endWebSession(id: webID2, at: d.addingTimeInterval(1000))

        let vm = DashboardViewModel(store: store)
        vm.anchor = d
        vm.setPeriod(.day)
        vm.reload()

        vm.searchText = "xcode"
        XCTAssertEqual(vm.filteredAppTotals.count, 1)
        XCTAssertEqual(vm.filteredAppTotals.first?.bundleID, "com.apple.dt.Xcode")

        vm.searchText = "GitHub"
        XCTAssertEqual(vm.filteredWebTotals.count, 1)
        XCTAssertEqual(vm.filteredWebTotals.first?.bucket, "github.com")
    }

    func test_peakHour_isHourWithMaxActivity() throws {
        let store = try makeStore()
        let d = date(2026, 5, 13)
        // Strong activity around 14:00.
        try add(store, at: date(2026, 5, 13, 14), durationMin: 50,
                bundleID: "x", name: "Xcode")
        try add(store, at: date(2026, 5, 13, 9), durationMin: 5,
                bundleID: "x", name: "Xcode")
        let vm = DashboardViewModel(store: store)
        vm.anchor = d
        vm.setPeriod(.day)
        vm.reload()
        XCTAssertEqual(vm.peakHour, 14)
    }

    func test_webByBrowser_isPopulatedForEverySupportedBrowser() throws {
        let store = try makeStore()
        let day = date(2026, 5, 13)
        let id = try store.startWebSession(
            at: day.addingTimeInterval(60), bucket: "github.com",
            url: nil, title: nil, isIncognito: false,
            browserBundleID: BrowserKind.chrome.bundleID
        )
        try store.endWebSession(id: id, at: day.addingTimeInterval(120))
        let id2 = try store.startWebSession(
            at: day.addingTimeInterval(200), bucket: "apple.com",
            url: nil, title: nil, isIncognito: false,
            browserBundleID: BrowserKind.safari.bundleID
        )
        try store.endWebSession(id: id2, at: day.addingTimeInterval(280))

        let vm = DashboardViewModel(store: store)
        vm.anchor = day
        vm.setPeriod(.day)
        vm.reload()

        // Every BrowserKind gets a key — even ones with no rows (so the
        // expanded view can render its "no pages" placeholder without an
        // extra synchronous DB hit).
        for kind in BrowserKind.allCases {
            XCTAssertNotNil(vm.webByBrowser[kind.bundleID],
                            "missing key for \(kind.displayName)")
        }
        XCTAssertEqual(vm.webByBrowser[BrowserKind.chrome.bundleID]?.count, 1)
        XCTAssertEqual(vm.webByBrowser[BrowserKind.chrome.bundleID]?.first?.bucket, "github.com")
        XCTAssertEqual(vm.webByBrowser[BrowserKind.safari.bundleID]?.count, 1)
        XCTAssertEqual(vm.webByBrowser[BrowserKind.safari.bundleID]?.first?.bucket, "apple.com")
        XCTAssertEqual(vm.webByBrowser[BrowserKind.whale.bundleID]?.count, 0,
                       "Whale row has no data this day — empty list, not nil")
    }

    func test_previousPeriodComparison_populatesDelta() throws {
        let store = try makeStore()
        let today = date(2026, 5, 13)
        let yesterday = date(2026, 5, 12)
        // Today: 60min. Yesterday: 30min → expect +100% delta.
        try add(store, at: today, durationMin: 60, bundleID: "x", name: "Xcode")
        try add(store, at: yesterday, durationMin: 30, bundleID: "x", name: "Xcode")

        let vm = DashboardViewModel(store: store)
        vm.anchor = today
        vm.setPeriod(.day)
        vm.reload()
        XCTAssertEqual(vm.previousTotalSeconds, 30 * 60, accuracy: 0.5)
        XCTAssertNotNil(vm.delta)
        XCTAssertEqual(vm.delta?.percent ?? 0, 100, accuracy: 0.5)
    }

    func test_previousPeriodName_matchesPeriod() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        vm.setPeriod(.day); XCTAssertEqual(vm.previousPeriodName, "어제")
        vm.setPeriod(.week); XCTAssertEqual(vm.previousPeriodName, "지난 주")
        vm.setPeriod(.month); XCTAssertEqual(vm.previousPeriodName, "지난 달")
        vm.setPeriod(.range); XCTAssertEqual(vm.previousPeriodName, "이전 기간")
    }

    func test_rangeLabel_isHumanReadableForEachPeriod() throws {
        let store = try makeStore()
        let vm = DashboardViewModel(store: store)
        vm.anchor = date(2026, 5, 13)
        vm.setPeriod(.day)
        XCTAssertTrue(vm.rangeLabel.contains("2026년"))
        vm.setPeriod(.week)
        XCTAssertTrue(vm.rangeLabel.contains("월~일"))
        vm.setPeriod(.month)
        XCTAssertTrue(vm.rangeLabel.contains("2026년 5월"))
        vm.rangeStart = date(2026, 5, 1)
        vm.rangeEnd = date(2026, 5, 7)
        vm.setPeriod(.range)
        XCTAssertTrue(vm.rangeLabel.contains("(7일)"))
    }
}

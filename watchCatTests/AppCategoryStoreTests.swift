import XCTest
@testable import watchCat

final class AppCategoryStoreTests: XCTestCase {
    private func dateAt(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c)!
    }

    func test_setAndReadCategory() throws {
        let store = try SessionStore()
        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(try store.category(forBundleID: "com.apple.dt.Xcode"), .productivity)
    }

    func test_setCategory_upsertsOverrides() throws {
        let store = try SessionStore()
        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        try store.setCategory(.entertainment, forBundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(try store.category(forBundleID: "com.apple.dt.Xcode"), .entertainment)
    }

    func test_clearCategory_removesMapping() throws {
        let store = try SessionStore()
        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        try store.clearCategory(forBundleID: "com.apple.dt.Xcode")
        XCTAssertNil(try store.category(forBundleID: "com.apple.dt.Xcode"))
    }

    func test_categoryMapping_returnsAll() throws {
        let store = try SessionStore()
        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        try store.setCategory(.communication, forBundleID: "com.tinyspeck.slackmacgap")
        let mapping = try store.categoryMapping()
        XCTAssertEqual(mapping["com.apple.dt.Xcode"], .productivity)
        XCTAssertEqual(mapping["com.tinyspeck.slackmacgap"], .communication)
        XCTAssertEqual(mapping.count, 2)
    }

    // SPEC §F5.3 — categorized apps aggregate into their bucket; uncategorized apps
    // appear with category == nil so the '미분류' KPI is preserved.
    func test_dailyTotalsByCategory_groupsAndExposesUnclassified() throws {
        let store = try SessionStore()
        let day = dateAt(2026, 5, 13, 9, 0)
        let a = try store.startSession(at: day, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        try store.endSession(id: a, at: day.addingTimeInterval(60))
        let b = try store.startSession(at: day.addingTimeInterval(60),
                                       bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
        try store.endSession(id: b, at: day.addingTimeInterval(60 + 30))
        let c = try store.startSession(at: day.addingTimeInterval(90),
                                       bundleID: "com.unknown.bundle", displayName: "Unknown")
        try store.endSession(id: c, at: day.addingTimeInterval(90 + 10))

        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        try store.setCategory(.communication, forBundleID: "com.tinyspeck.slackmacgap")
        // "com.unknown.bundle" remains unclassified.

        let totals = try store.dailyTotalsByCategory(for: day)
        XCTAssertEqual(totals.count, 3)
        // Stable order: enum order then nil.
        XCTAssertEqual(totals[0].category, .productivity)
        XCTAssertEqual(totals[0].seconds, 60, accuracy: 0.01)
        XCTAssertEqual(totals[1].category, .communication)
        XCTAssertEqual(totals[1].seconds, 30, accuracy: 0.01)
        XCTAssertEqual(totals[2].category, nil, "unclassified bucket is exposed for KPI")
        XCTAssertEqual(totals[2].seconds, 10, accuracy: 0.01)
    }

    // SPEC §F5.2 — re-mapping an app changes historical totals on the next query
    // (no denormalized category column on sessions).
    func test_remappingApp_appliesRetroactively() throws {
        let store = try SessionStore()
        let day = dateAt(2026, 5, 13, 9, 0)
        let a = try store.startSession(at: day, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        try store.endSession(id: a, at: day.addingTimeInterval(120))

        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
        var totals = try store.dailyTotalsByCategory(for: day)
        XCTAssertEqual(totals.first?.category, .productivity)
        XCTAssertEqual(totals.first?.seconds ?? 0, 120, accuracy: 0.01)

        // User re-classifies. Past data must now report under the new category.
        try store.setCategory(.entertainment, forBundleID: "com.apple.dt.Xcode")
        totals = try store.dailyTotalsByCategory(for: day)
        XCTAssertEqual(totals.first?.category, .entertainment)
        XCTAssertEqual(totals.first?.seconds ?? 0, 120, accuracy: 0.01)
    }
}

import XCTest
@testable import watchCat

final class RetentionTests: XCTestCase {
    private func makeStore() throws -> SessionStore { try SessionStore() }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    func test_prune_removesRowsOlderThanCutoff() throws {
        let store = try makeStore()
        // Today = 2026-05-13. Insert one 90-day-old row + one fresh row.
        let now = date(2026, 5, 13)
        let old = Calendar.current.date(byAdding: .day, value: -120, to: now)!
        let recent = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let idOld = try store.startSession(at: old, bundleID: "x", displayName: "Xcode")
        try store.endSession(id: idOld, at: old.addingTimeInterval(600))
        let idRecent = try store.startSession(at: recent, bundleID: "x", displayName: "Xcode")
        try store.endSession(id: idRecent, at: recent.addingTimeInterval(600))

        let removed = try store.prune(olderThanDays: 90, now: now)
        XCTAssertEqual(removed, 1, "only the 120-day-old row should be removed")

        let all = try store.allSessions()
        XCTAssertEqual(all.count, 1)
    }

    func test_prune_zeroDays_isNoOp() throws {
        let store = try makeStore()
        let now = date(2026, 5, 13)
        let old = Calendar.current.date(byAdding: .day, value: -3650, to: now)!
        let id = try store.startSession(at: old, bundleID: "x", displayName: "Xcode")
        try store.endSession(id: id, at: old.addingTimeInterval(60))

        let removed = try store.prune(olderThanDays: 0, now: now)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try store.allSessions().count, 1)
    }

    func test_prune_alsoRemovesWebSessions() throws {
        let store = try makeStore()
        let now = date(2026, 5, 13)
        let old = Calendar.current.date(byAdding: .day, value: -120, to: now)!
        let id = try store.startWebSession(at: old, bucket: "example.com",
                                           url: nil, title: nil, isIncognito: false)
        try store.endWebSession(id: id, at: old.addingTimeInterval(120))

        let removed = try store.prune(olderThanDays: 90, now: now)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try store.allWebSessions().count, 0)
    }

    func test_retentionSettings_defaultIs90AndRejectsUnknownValues() {
        let key = RetentionSettings.userDefaultsKey
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(RetentionSettings.days, 90)

        // Reject an unsupported value: should fall back to default on read.
        UserDefaults.standard.set(42, forKey: key)
        XCTAssertEqual(RetentionSettings.days, 90)

        RetentionSettings.days = 30
        XCTAssertEqual(RetentionSettings.days, 30)

        // 0 is a valid allow-list entry (=무제한).
        RetentionSettings.days = 0
        XCTAssertEqual(RetentionSettings.days, 0)

        UserDefaults.standard.removeObject(forKey: key)
    }
}

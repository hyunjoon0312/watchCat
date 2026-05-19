import XCTest
@testable import watchCat

private extension AppCategory {
    static var productivity:  AppCategory { builtIns.first { $0.id == "productivity"  }! }
    static var entertainment: AppCategory { builtIns.first { $0.id == "entertainment" }! }
}

final class ExportImportTests: XCTestCase {
    private func makeStore() throws -> SessionStore { try SessionStore() }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c)!
    }

    private func seed(_ store: SessionStore) throws {
        let start = date(2026, 5, 13)
        let id = try store.startSession(at: start, bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
        try store.endSession(id: id, at: start.addingTimeInterval(600))
        let id2 = try store.startSession(at: start.addingTimeInterval(700),
                                         bundleID: "com.google.Chrome", displayName: "Chrome")
        try store.endSession(id: id2, at: start.addingTimeInterval(1000))
        let webID = try store.startWebSession(at: start.addingTimeInterval(750),
                                              bucket: "github.com", url: "https://github.com",
                                              title: nil, isIncognito: false)
        try store.endWebSession(id: webID, at: start.addingTimeInterval(900))
        try store.setCategory(.productivity, forBundleID: "com.apple.dt.Xcode")
    }

    func test_export_then_decode_roundTrips() throws {
        let store = try makeStore()
        try seed(store)
        let archive = try store.exportArchive()
        let data = try SessionStore.encodeArchive(archive)
        let decoded = try SessionStore.decodeArchive(data)
        XCTAssertEqual(decoded.sessions.count, 2)
        XCTAssertEqual(decoded.webSessions.count, 1)
        XCTAssertEqual(decoded.categories.count, 1)
        XCTAssertEqual(decoded.schemaVersion, WatchCatArchive.currentSchemaVersion)
    }

    func test_import_merge_preservesExistingRows() throws {
        let src = try makeStore()
        try seed(src)
        let archive = try src.exportArchive()

        let dst = try makeStore()
        let pre = date(2026, 1, 1)
        let id = try dst.startSession(at: pre, bundleID: "com.preexist.App", displayName: "Pre")
        try dst.endSession(id: id, at: pre.addingTimeInterval(60))

        let summary = try dst.importArchive(archive, mode: .merge)
        XCTAssertEqual(summary.sessionsImported, 2)
        XCTAssertEqual(summary.removedBeforeImport, 0)
        XCTAssertEqual(try dst.allSessions().count, 3,
                       "pre-existing row + 2 imported rows")
    }

    func test_import_replace_clearsExistingDataFirst() throws {
        let src = try makeStore()
        try seed(src)
        let archive = try src.exportArchive()

        let dst = try makeStore()
        // Add some throwaway rows we expect to be wiped on .replace.
        let pre = date(2026, 1, 1)
        let id = try dst.startSession(at: pre, bundleID: "x", displayName: "x")
        try dst.endSession(id: id, at: pre.addingTimeInterval(60))
        try dst.setCategory(.entertainment, forBundleID: "x")

        let summary = try dst.importArchive(archive, mode: .replace)
        XCTAssertGreaterThan(summary.removedBeforeImport, 0)
        XCTAssertEqual(try dst.allSessions().count, 2,
                       "after .replace only archived sessions remain")

        // Mapping from archive should be present; pre-existing category for "x" gone.
        let mapping = try dst.categoryMapping()
        XCTAssertEqual(mapping["com.apple.dt.Xcode"], .productivity)
        XCTAssertNil(mapping["x"])
    }

    func test_import_rejectsFutureSchemaVersion() throws {
        let dst = try makeStore()
        let future = WatchCatArchive(
            schemaVersion: WatchCatArchive.currentSchemaVersion + 1,
            exportedAt: Date(), appVersion: "test",
            sessions: [], webSessions: [], categories: []
        )
        XCTAssertThrowsError(try dst.importArchive(future, mode: .merge)) { err in
            guard case ImportError.unsupportedSchema = err else {
                XCTFail("expected unsupportedSchema, got \(err)"); return
            }
        }
    }

    func test_export_to_file_writes_validJSON() throws {
        let store = try makeStore()
        try seed(store)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchCat-export-test-\(UUID().uuidString).json")
        try store.exportArchive(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let decoded = try SessionStore.decodeArchive(data)
        XCTAssertEqual(decoded.sessions.count, 2)
    }

    func test_appTotalsCSV_escapesCommasAndQuotes() {
        let totals = [
            AppTotal(bundleID: "com.test.simple", displayName: "Simple", seconds: 65),
            AppTotal(bundleID: "com.test.weird", displayName: "Has, comma", seconds: 120),
            AppTotal(bundleID: "com.test.q", displayName: "Has \"quote\"", seconds: 30)
        ]
        let range = DashboardRange.day(Date())
        let csv = SessionStore.appTotalsCSV(totals, range: range)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "day_start,day_end,bundleID,displayName,seconds,hms")
        XCTAssertTrue(lines[2].contains("\"Has, comma\""), "comma must be quoted: \(lines[2])")
        XCTAssertTrue(lines[3].contains("\"Has \"\"quote\"\"\""), "quotes must be doubled: \(lines[3])")
    }
}

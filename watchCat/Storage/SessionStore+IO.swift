import Foundation
import GRDB

/// Versioned snapshot of every user-owned table. Stable on disk so a JSON file
/// exported today can still be imported after future schema migrations.
///
/// `schemaVersion` is bumped only when the serialized shape changes in a way
/// that breaks decoders; column additions that round-trip via Codable defaults
/// don't bump it.
struct WatchCatArchive: Codable, Equatable {
    static let currentSchemaVersion: Int = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String?
    var sessions: [Session]
    var webSessions: [WebSession]
    var categories: [Category]

    struct Session: Codable, Equatable {
        var startAt: Date
        var endAt: Date?
        var bundleID: String
        var displayName: String
        var day: String
    }

    struct WebSession: Codable, Equatable {
        var startAt: Date
        var endAt: Date?
        var bucket: String
        var url: String?
        var title: String?
        var isIncognito: Bool
        var day: String
    }

    struct Category: Codable, Equatable {
        var bundleID: String
        var category: String
    }
}

/// Import strategy. `.merge` appends rows without touching existing data;
/// `.replace` deletes every row in user-owned tables first, giving a clean restore.
enum ImportMode {
    case merge
    case replace
}

struct ImportSummary: Equatable {
    let sessionsImported: Int
    let webSessionsImported: Int
    let categoriesImported: Int
    let removedBeforeImport: Int  // when mode == .replace
}

enum ImportError: Error, LocalizedError {
    case malformedJSON(underlying: Error)
    case unsupportedSchema(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .malformedJSON(let e):
            return "백업 파일을 읽을 수 없습니다: \(e.localizedDescription)"
        case .unsupportedSchema(let found, let supported):
            return "지원하지 않는 백업 버전입니다 (파일=\(found), 지원=\(supported))."
        }
    }
}

extension SessionStore {

    // MARK: - Export

    /// Snapshot every user-owned table into an in-memory archive.
    func exportArchive(now: Date = Date(), appVersion: String? = nil) throws -> WatchCatArchive {
        try dbQueue.read { db in
            let sessions = try Row.fetchAll(db, sql: """
                SELECT startAt, endAt, bundleID, displayName, day
                FROM \(SessionRecord.databaseTableName)
                ORDER BY startAt ASC
                """).map { r in
                WatchCatArchive.Session(
                    startAt: r["startAt"], endAt: r["endAt"],
                    bundleID: r["bundleID"], displayName: r["displayName"], day: r["day"]
                )
            }
            let web = try Row.fetchAll(db, sql: """
                SELECT startAt, endAt, bucket, url, title, isIncognito, day
                FROM \(WebSessionRecord.databaseTableName)
                ORDER BY startAt ASC
                """).map { r in
                WatchCatArchive.WebSession(
                    startAt: r["startAt"], endAt: r["endAt"],
                    bucket: r["bucket"], url: r["url"], title: r["title"],
                    isIncognito: r["isIncognito"], day: r["day"]
                )
            }
            let cats = try Row.fetchAll(db, sql: """
                SELECT bundleID, category FROM \(AppCategoryRecord.databaseTableName)
                """).map { r in
                WatchCatArchive.Category(bundleID: r["bundleID"], category: r["category"])
            }
            return WatchCatArchive(
                schemaVersion: WatchCatArchive.currentSchemaVersion,
                exportedAt: now, appVersion: appVersion,
                sessions: sessions, webSessions: web, categories: cats
            )
        }
    }

    /// Serialize an archive to pretty-printed JSON data (UTF-8). Uses ISO8601 date
    /// strings — human-readable in text editors and round-trip-safe.
    static func encodeArchive(_ archive: WatchCatArchive) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(archive)
    }

    static func decodeArchive(_ data: Data) throws -> WatchCatArchive {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(WatchCatArchive.self, from: data)
        } catch {
            throw ImportError.malformedJSON(underlying: error)
        }
    }

    /// Convenience writer: archive → file on disk.
    func exportArchive(to url: URL, now: Date = Date(), appVersion: String? = nil) throws {
        let archive = try exportArchive(now: now, appVersion: appVersion)
        let data = try Self.encodeArchive(archive)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Import

    @discardableResult
    func importArchive(_ archive: WatchCatArchive, mode: ImportMode) throws -> ImportSummary {
        guard archive.schemaVersion <= WatchCatArchive.currentSchemaVersion else {
            throw ImportError.unsupportedSchema(
                found: archive.schemaVersion, supported: WatchCatArchive.currentSchemaVersion
            )
        }
        return try dbQueue.write { db in
            var removed = 0
            if mode == .replace {
                try db.execute(sql: "DELETE FROM \(SessionRecord.databaseTableName)")
                removed += db.changesCount
                try db.execute(sql: "DELETE FROM \(WebSessionRecord.databaseTableName)")
                removed += db.changesCount
                try db.execute(sql: "DELETE FROM \(AppCategoryRecord.databaseTableName)")
                removed += db.changesCount
            }
            // Sessions
            for s in archive.sessions {
                try db.execute(sql: """
                    INSERT INTO \(SessionRecord.databaseTableName)
                        (startAt, endAt, bundleID, displayName, day)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [s.startAt, s.endAt, s.bundleID, s.displayName, s.day])
            }
            for w in archive.webSessions {
                try db.execute(sql: """
                    INSERT INTO \(WebSessionRecord.databaseTableName)
                        (startAt, endAt, bucket, url, title, isIncognito, day)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [w.startAt, w.endAt, w.bucket, w.url, w.title,
                                     w.isIncognito, w.day])
            }
            // Categories: ON CONFLICT keeps merge idempotent — re-importing the
            // same archive twice doesn't error or duplicate, it just overwrites.
            for c in archive.categories {
                try db.execute(sql: """
                    INSERT INTO \(AppCategoryRecord.databaseTableName) (bundleID, category)
                    VALUES (?, ?)
                    ON CONFLICT(bundleID) DO UPDATE SET category = excluded.category
                    """, arguments: [c.bundleID, c.category])
            }
            return ImportSummary(
                sessionsImported: archive.sessions.count,
                webSessionsImported: archive.webSessions.count,
                categoriesImported: archive.categories.count,
                removedBeforeImport: removed
            )
        }
    }

    @discardableResult
    func importArchive(from url: URL, mode: ImportMode) throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        let archive = try Self.decodeArchive(data)
        return try importArchive(archive, mode: mode)
    }

    // MARK: - CSV export (current dashboard view)

    /// CSV of per-app totals for a given range — used by the dashboard "내보내기" button.
    /// Columns: day_range_start, day_range_end, bundleID, displayName, seconds, hms.
    static func appTotalsCSV(_ totals: [AppTotal], range: DayRange) -> String {
        let (first, last) = range.dayKeys
        var lines = ["day_start,day_end,bundleID,displayName,seconds,hms"]
        for t in totals {
            let secs = Int(t.seconds.rounded())
            let hms = String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
            let safeName = csvEscape(t.displayName)
            let safeBundle = csvEscape(t.bundleID)
            lines.append("\(first),\(last),\(safeBundle),\(safeName),\(secs),\(hms)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

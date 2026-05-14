import Foundation
import GRDB
import SwiftUI

/// User-editable app category. Replaces the previous fixed enum so users can
/// add, rename, and delete categories from the dashboard. Identified by a
/// stable string ID — built-in defaults keep their legacy raw values
/// ("productivity", "communication", ...) so existing `app_categories` rows
/// from v3 era continue to resolve after the v6 migration.
struct AppCategory: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var colorHex: String
    var sortOrder: Int

    /// SwiftUI Color resolved from `colorHex`. Falls back to a neutral gray if
    /// the stored value is malformed (corrupt user input shouldn't crash UI).
    var color: Color { ColorHex.color(from: colorHex) ?? Color.gray }

    /// Built-in defaults seeded on first launch (migration v6). Stable IDs
    /// preserve backward compatibility with v3-era category mappings.
    static let builtIns: [AppCategory] = [
        AppCategory(id: "productivity",  name: "생산성",       colorHex: "#6E5CF5", sortOrder: 0),
        AppCategory(id: "communication", name: "커뮤니케이션", colorHex: "#12A8A8", sortOrder: 1),
        AppCategory(id: "entertainment", name: "오락",         colorHex: "#ED6B82", sortOrder: 2),
        AppCategory(id: "other",         name: "기타",         colorHex: "#8C8E9E", sortOrder: 3),
    ]

    /// Fixed swatch palette the picker offers — chosen for perceptual balance
    /// against the dashboard's surfaces. Users pick from these instead of a
    /// freeform color well to keep the donut chart legible.
    static let palette: [String] = [
        "#6E5CF5", // indigo
        "#12A8A8", // teal
        "#ED6B82", // rose
        "#F7B036", // amber
        "#67BD6B", // sage
        "#9F73EE", // violet
        "#FC8C5C", // peach
        "#5C9EEE", // sky
        "#8C8E9E", // slate
    ]
}

/// Row in the user-editable categories table. Lives alongside `AppCategoryRecord`
/// (bundleID → categoryID), which references this table by `id`.
struct AppCategoryDefinitionRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "app_category_definitions"

    var id: String
    var name: String
    var colorHex: String
    var sortOrder: Int

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let colorHex = Column("colorHex")
        static let sortOrder = Column("sortOrder")
    }
}

/// One row per (bundleID → categoryID) mapping. Changes apply retroactively to
/// historical session rows (SPEC §F5.2) because aggregation joins on bundleID
/// at read time — we never denormalize the category into `sessions`.
struct AppCategoryRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "app_categories"

    var bundleID: String
    var category: String  // category id

    enum Columns {
        static let bundleID = Column("bundleID")
        static let category = Column("category")
    }
}

/// Aggregation result for category-level summaries.
struct CategoryTotal: Equatable {
    let category: AppCategory?  // nil = unclassified
    let seconds: TimeInterval
}

/// Hex parser for category swatch storage.
enum ColorHex {
    static func color(from hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >>  8) & 0xFF) / 255
        let b = Double( v        & 0xFF) / 255
        return Color(.displayP3, red: r, green: g, blue: b, opacity: 1)
    }
}

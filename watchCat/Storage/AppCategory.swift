import Foundation
import GRDB

/// SPEC §F5.1 — seed categories shipped with v0.1. Custom user-defined categories
/// are deferred to v0.2 per §7 roadmap.
enum AppCategory: String, CaseIterable, Codable, Equatable {
    case productivity
    case communication
    case entertainment
    case other

    var displayName: String {
        switch self {
        case .productivity:    return "생산성"
        case .communication:   return "커뮤니케이션"
        case .entertainment:   return "오락"
        case .other:           return "기타"
        }
    }
}

/// One row per (bundleID → category) mapping. Changes apply retroactively to
/// historical session rows (SPEC §F5.2) because aggregation joins on bundleID
/// at read time — we never denormalize the category into `sessions`.
struct AppCategoryRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "app_categories"

    var bundleID: String
    var category: String

    enum Columns {
        static let bundleID = Column("bundleID")
        static let category = Column("category")
    }

    var resolvedCategory: AppCategory? { AppCategory(rawValue: category) }
}

/// Aggregation result for category-level summaries.
struct CategoryTotal: Equatable {
    let category: AppCategory?  // nil = unclassified (SPEC §F5.4)
    let seconds: TimeInterval
}

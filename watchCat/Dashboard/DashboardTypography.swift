import SwiftUI

/// Typography tokens for the dashboard. One place to tune the hierarchy — every
/// label in `DashboardView` resolves through here so font sizes can't drift.
///
/// Sizing rationale: Apple's HIG default body for macOS is 13pt, but Korean
/// glyphs render visually smaller than Latin at the same point size. The
/// previous pass leaned heavily on 10–12pt which left section captions and
/// chart axes hard to read. We bumped the baseline body to 14pt, captions to
/// 12pt, and let display/headline sizes scale up proportionally.
extension Font {
    /// Hero metric — "1시간 55분" on the header card. The single biggest
    /// number on the page, sized for confident reading.
    static let dbDisplay = Font.system(size: 52, weight: .bold, design: .rounded)

    /// Section card title (above charts, lists). Was 13pt — now reads as a
    /// proper title without being shouted in uppercase tracking.
    static let dbCardTitle = Font.system(size: 14, weight: .semibold, design: .rounded)

    /// Stat tile primary value (e.g., "Code", "10시", "14"). Bumped from 13pt.
    static let dbStatValue = Font.system(size: 17, weight: .semibold, design: .rounded)

    /// Stat tile / capsule mini-label (uppercase, tracked). Was 10pt — now 11pt.
    static let dbStatLabel = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Default body and row title — list rows, secondary text, picker rows.
    static let dbHeadline = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let dbBody = Font.system(size: 14, weight: .medium, design: .rounded)
    static let dbBodySmall = Font.system(size: 13, design: .rounded)

    /// Caption — chart axis labels, secondary annotations.
    static let dbCaption = Font.system(size: 12, weight: .medium, design: .rounded)
    static let dbCaptionSmall = Font.system(size: 11, weight: .medium, design: .rounded)

    /// Pill / tag text (chips, category badges).
    static let dbTag = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let dbTagSmall = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// Range label below the hero number — was the only small text the user
    /// actually wanted small.
    static let dbContext = Font.system(size: 13, weight: .medium, design: .rounded)
}

/// Letter-spacing presets matching the typography ramp. Korean characters need
/// less tracking than uppercase Latin labels, so we expose two values rather
/// than baking one into every label.
enum DashboardTracking {
    /// Used on uppercase ALL-CAPS labels ("카테고리 분포", "오늘의 시간대별 활성도").
    static let label: CGFloat = 0.6
    /// Used on normal body text where 0 tracking would feel cramped.
    static let body: CGFloat = 0.1
}

import Foundation
import Combine

/// Reactively-computed aggregates shown in the dashboard. The view holds one
/// `DashboardViewModel`; changing `period`, `anchor`, or the custom-range bounds
/// triggers a single recompute pass that re-fetches everything from the store.
@MainActor
final class DashboardViewModel: ObservableObject {
    // MARK: - Selection (driven by the toolbar)

    @Published var period: DashboardPeriod = .day {
        didSet { if oldValue != period { recomputeRange(); reload() } }
    }

    /// Anchor date for `.day`/`.week`/`.month`. For `.range` we use `rangeStart`/`rangeEnd`.
    @Published var anchor: Date = Date() {
        didSet { recomputeRange(); reload() }
    }

    @Published var rangeStart: Date = Date() {
        didSet { if period == .range { recomputeRange(); reload() } }
    }
    @Published var rangeEnd: Date = Date() {
        didSet { if period == .range { recomputeRange(); reload() } }
    }

    @Published private(set) var range: DayRange = DashboardRange.day(Date())

    // MARK: - Filtering (UI sugar)

    @Published var searchText: String = ""

    // MARK: - Data outputs

    @Published private(set) var appTotals: [AppTotal] = []
    @Published private(set) var categoryTotals: [CategoryTotal] = []
    @Published private(set) var webTotals: [WebBucketTotal] = []
    /// Per-browser page breakdown for the app-list drill-down. Keyed by browser
    /// bundle ID so the row can look itself up. Populated for every supported
    /// browser even when empty so the expanded view can render the "no pages"
    /// placeholder without an extra fetch.
    @Published private(set) var webByBrowser: [String: [WebBucketTotal]] = [:]
    @Published private(set) var dailySeries: [DailySeriesPoint] = []
    @Published private(set) var hourlySeries: [DailySeriesPoint] = []
    @Published private(set) var topAppSeries: [AppDailySeries] = []
    @Published private(set) var heatmap: [HeatmapCell] = []
    @Published private(set) var categoryMapping: [String: AppCategory] = [:]
    /// User-editable category list (loaded from `app_category_definitions`).
    /// Drives the AppRow menu and the management UI on the category tab.
    @Published private(set) var categories: [AppCategory] = []
    /// Total seconds for the same-length period immediately before `range`. Used
    /// for the "vs. 지난 기간" delta chip on the header.
    @Published private(set) var previousTotalSeconds: TimeInterval = 0
    @Published private(set) var loadError: String?

    /// Optional: dashboard runs without a DB when in degraded mode; we just show empty state.
    private let store: SessionStore?
    private let calendar: Calendar

    init(store: SessionStore?, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        // Initialize a sensible default range based on the initial period.
        self.rangeStart = calendar.startOfDay(for: Date())
        self.rangeEnd = calendar.startOfDay(for: Date())
        recomputeRange()
        reload()
    }

    // MARK: - Selection helpers

    func setPeriod(_ p: DashboardPeriod) {
        self.period = p
    }

    /// Move the current selection one period earlier / later. `.range` shifts by
    /// its current span; `.today/this-week/this-month` is exposed via `jumpToToday`.
    func step(by direction: Int) {
        switch period {
        case .day, .week, .month:
            let shifted = DashboardRange.shift(range, period: period, by: direction, calendar: calendar)
            self.anchor = shifted.start
        case .range:
            let shifted = DashboardRange.shift(range, period: .range, by: direction, calendar: calendar)
            self.rangeStart = shifted.start
            self.rangeEnd = shifted.end
        }
    }

    func jumpToToday() {
        self.anchor = Date()
        if period == .range {
            let day = DashboardRange.day(Date(), calendar: calendar)
            self.rangeStart = day.start
            self.rangeEnd = day.end
        }
    }

    private func recomputeRange() {
        switch period {
        case .day:
            range = DashboardRange.day(anchor, calendar: calendar)
        case .week:
            range = DashboardRange.week(containing: anchor, calendar: calendar)
        case .month:
            range = DashboardRange.month(containing: anchor, calendar: calendar)
        case .range:
            range = DashboardRange.custom(from: rangeStart, to: rangeEnd, calendar: calendar)
        }
    }

    // MARK: - Recompute

    /// Re-run every aggregate. Called on selection change and via `refresh()` from
    /// the UI after manual data changes (import, retention purge, category edit).
    func reload() {
        guard let store else {
            appTotals = []; categoryTotals = []; webTotals = []
            dailySeries = []; topAppSeries = []; heatmap = []
            loadError = "DB 사용 불가 — 권한 또는 디스크 접근 문제일 수 있습니다."
            return
        }
        do {
            let r = range
            let now = Date()
            self.categories = try store.listCategories()
            self.categoryMapping = try store.categoryMapping()
            self.appTotals = try store.appTotals(in: r, asOf: now)
            self.categoryTotals = try store.categoryTotals(in: r, asOf: now)
            self.webTotals = try store.webBucketTotals(in: r, asOf: now)
            var perBrowser: [String: [WebBucketTotal]] = [:]
            for kind in BrowserKind.allCases {
                perBrowser[kind.bundleID] = try store.webBucketTotals(
                    in: r, browserBundleID: kind.bundleID, asOf: now
                )
            }
            self.webByBrowser = perBrowser
            self.dailySeries = try store.dailySeries(in: r, asOf: now)
            self.hourlySeries = try store.hourlyTotals(in: r, calendar: calendar, asOf: now)
            self.topAppSeries = try store.topAppDailySeries(in: r, limit: 5, asOf: now)
            self.heatmap = try store.hourWeekdayHeatmap(in: r, calendar: calendar, asOf: now)
            let prev = DashboardRange.shift(r, period: period, by: -1, calendar: calendar)
            self.previousTotalSeconds = try store.totalSeconds(in: prev, asOf: now)
            self.loadError = nil
        } catch {
            self.loadError = "데이터 로드 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Derived display

    /// Filtered app totals (case-insensitive substring match against display name).
    var filteredAppTotals: [AppTotal] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return appTotals
        }
        let q = searchText.lowercased()
        return appTotals.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.bundleID.lowercased().contains(q)
        }
    }

    var filteredWebTotals: [WebBucketTotal] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return webTotals
        }
        let q = searchText.lowercased()
        return webTotals.filter { $0.bucket.lowercased().contains(q) }
    }

    var totalSeconds: TimeInterval { appTotals.reduce(0) { $0 + $1.seconds } }

    /// Human-readable label for the currently-selected period.
    var rangeLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        switch period {
        case .day:
            fmt.dateFormat = "yyyy년 M월 d일 (E)"
            return fmt.string(from: range.start)
        case .week:
            fmt.dateFormat = "M월 d일"
            let s = fmt.string(from: range.start)
            let e = fmt.string(from: range.end)
            let yearFmt = DateFormatter()
            yearFmt.locale = Locale(identifier: "ko_KR")
            yearFmt.dateFormat = "yyyy년"
            return "\(yearFmt.string(from: range.start)) · \(s) ~ \(e) (월~일)"
        case .month:
            fmt.dateFormat = "yyyy년 M월"
            return fmt.string(from: range.start)
        case .range:
            fmt.dateFormat = "yyyy.MM.dd"
            return "\(fmt.string(from: range.start)) ~ \(fmt.string(from: range.end)) (\(range.dayCount)일)"
        }
    }

    /// Peak hour (local) by total active time across the range — surfaced as a
    /// header stat ("가장 활발했던 시간대"). Returns nil for ranges with no data.
    var peakHour: Int? {
        var perHour: [Int: TimeInterval] = [:]
        for cell in heatmap { perHour[cell.hour, default: 0] += cell.seconds }
        return perHour.max(by: { $0.value < $1.value })?.key
    }

    /// Most-used app for the range header (top of `appTotals`).
    var topApp: AppTotal? { appTotals.first }

    /// Signed delta vs. the previous comparable period. nil if the previous
    /// period had no data — there's nothing meaningful to compare against.
    var delta: (seconds: TimeInterval, percent: Double)? {
        guard previousTotalSeconds > 0 else { return nil }
        let diff = totalSeconds - previousTotalSeconds
        return (diff, diff / previousTotalSeconds * 100.0)
    }

    /// Persist a user-picked category for an app. Passing `nil` clears it.
    /// Triggers a `reload()` so the dashboard's category aggregates reflect
    /// the change immediately — the categorization joins live at read-time.
    func updateCategory(_ category: AppCategory?, for bundleID: String) {
        guard let store else { return }
        do {
            if let category {
                try store.setCategory(category, forBundleID: bundleID)
            } else {
                try store.clearCategory(forBundleID: bundleID)
            }
            reload()
        } catch {
            self.loadError = "카테고리 저장 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Category definition CRUD

    func addCategory(name: String, colorHex: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try store.createCategory(name: trimmed, colorHex: colorHex)
            reload()
        } catch {
            self.loadError = "카테고리 추가 실패: \(error.localizedDescription)"
        }
    }

    func renameCategory(id: String, name: String, colorHex: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.updateCategoryDefinition(id: id, name: trimmed, colorHex: colorHex)
            reload()
        } catch {
            self.loadError = "카테고리 변경 실패: \(error.localizedDescription)"
        }
    }

    func reorderCategories(ids: [String]) {
        guard let store else { return }
        do {
            try store.reorderCategories(ids: ids)
            reload()
        } catch {
            self.loadError = "카테고리 순서 변경 실패: \(error.localizedDescription)"
        }
    }

    func deleteCategory(id: String) {
        guard let store else { return }
        do {
            try store.deleteCategoryDefinition(id: id)
            reload()
        } catch {
            self.loadError = "카테고리 삭제 실패: \(error.localizedDescription)"
        }
    }

    /// Short label for the "previous period" chip — "어제", "지난 주", "지난 달", "이전 기간".
    var previousPeriodName: String {
        switch period {
        case .day:   return "어제"
        case .week:  return "지난 주"
        case .month: return "지난 달"
        case .range: return "이전 기간"
        }
    }
}

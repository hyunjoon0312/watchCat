import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI dashboard. The layout is structurally stable across period swaps —
/// the same cards always render in the same slots, only their inner chart and
/// list contents swap. That stability is what fixes the "window resizes and
/// clips" issue from the previous version.
struct DashboardView: View {
    @StateObject private var vm: DashboardViewModel
    @State private var exporterDocument: TextDocument?
    @State private var showExporter = false
    @State private var defaultExportName = "watchCat-export"
    /// Bundle IDs of browser rows the user has expanded to see per-page breakdown.
    /// Multiple browsers can be expanded simultaneously so users can compare
    /// "what did I read in Chrome vs. Safari today?" side by side.
    @State private var expandedBrowsers: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    init(store: SessionStore?) {
        _vm = StateObject(wrappedValue: DashboardViewModel(store: store))
    }

    var body: some View {
        ZStack(alignment: .top) {
            (scheme == .dark
             ? DashboardPalette.backgroundGradientDark
             : DashboardPalette.backgroundGradient)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 16)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let err = vm.loadError {
                            errorBanner(err)
                        }
                        headerCard
                        primaryChartCard
                        listsCard
                    }
                    .padding(.horizontal, 26).padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Hidden Button hosting the ⌘T shortcut. Sits in `.background` of the
        // root view so it doesn't share an `HStack` row with the visible "오늘"
        // chip — earlier attempts at putting it next to / overlaying the chip
        // caused SwiftUI to collapse the chip's label width to zero on macOS.
        .background {
            Button("") { vm.jumpToToday() }
                .keyboardShortcut("t", modifiers: [.command])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 1140, minHeight: 700)
        .fileExporter(
            isPresented: $showExporter,
            document: exporterDocument,
            contentType: .commaSeparatedText,
            defaultFilename: defaultExportName
        ) { _ in }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            // Segmented period control — kept native; .segmented reads cleanly
            // and supports keyboard. The width is fixed so swapping periods
            // doesn't reflow the toolbar horizontally.
            Picker("기간", selection: Binding(get: { vm.period }, set: { vm.setPeriod($0) })) {
                ForEach(DashboardPeriod.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .frame(width: 300)
            .labelsHidden()

            // Navigation cluster — fixed-width center so toolbar width is stable.
            HStack(spacing: 6) {
                circleButton(systemImage: "chevron.left") { vm.step(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                periodDateControl
                    .fixedSize(horizontal: true, vertical: false)
                circleButton(systemImage: "chevron.right") { vm.step(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                // Render as an HStack-wrapped Text chip with onTapGesture. The
                // previous `Button("오늘")` collapsed the label to zero width on
                // macOS (the pill rendered as an empty oval). ⌘T is preserved
                // as a separate Button placed at the bottom of the toolbar so
                // it doesn't sit on top of this chip.
                HStack(spacing: 0) {
                    Text("오늘")
                        .font(.dbTag)
                        .foregroundColor(DashboardPalette.accent)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(DashboardPalette.accentSoft))
                .contentShape(Capsule(style: .continuous))
                .chipButton { vm.jumpToToday() }
                .help("오늘 ⌘T")
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("앱 · 도메인 검색", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.dbBody)
                    .frame(width: 180)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointingCursor()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.55 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.15), lineWidth: 1)
            )

            // Same NSButton label-stripping issue as the "오늘" pill — render
                // as a Text chip with onTapGesture.
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 12, weight: .bold))
                Text("CSV")
                    .font(.dbTag)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(DashboardPalette.accent))
            .contentShape(Capsule(style: .continuous))
            .chipButton { exportCurrentViewCSV() }
            .help("현재 보기의 앱 합계를 CSV로 내보내기")
        }
    }

    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(.background.opacity(scheme == .dark ? 0.55 : 0.9))
                )
                .overlay(Circle().strokeBorder(.secondary.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingCursor()
    }

    /// Period-appropriate date control — all are chip+popover style, so there's
    /// no more "cursor stuck on year" friction the user called out.
    @ViewBuilder
    private var periodDateControl: some View {
        switch vm.period {
        case .day:
            DateChip(label: dayLabel(vm.range.start), selection: $vm.anchor)
        case .week:
            DateChip(
                label: weekLabel(vm.range),
                selection: Binding(
                    get: { vm.range.start },
                    set: { vm.anchor = $0 }
                ),
                transform: { DashboardRange.week(containing: $0).start }
            )
        case .month:
            MonthChip(date: $vm.anchor)
        case .range:
            HStack(spacing: 6) {
                DateChip(label: shortDate(vm.rangeStart), selection: $vm.rangeStart)
                Text("~").foregroundStyle(.secondary).font(.system(size: 13, weight: .bold))
                DateChip(label: shortDate(vm.rangeEnd), selection: $vm.rangeEnd)
            }
        }
    }

    // MARK: - Header card (the visual anchor)

    private var headerCard: some View {
        DashboardCard {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(vm.rangeLabel)
                        .font(.dbContext)
                        .foregroundStyle(.secondary)
                        .tracking(DashboardTracking.body)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TimeFormatting.longHMS(vm.totalSeconds))
                            .font(.dbDisplay)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        deltaChip
                    }

                    HStack(spacing: 20) {
                        miniStat(icon: "trophy.fill",
                                 tint: DashboardPalette.highlight,
                                 label: "가장 많이 쓴 앱",
                                 value: vm.topApp?.displayName ?? "—",
                                 sub: vm.topApp.map { TimeFormatting.longHMS($0.seconds) })
                        miniStat(icon: "sun.max.fill",
                                 tint: DashboardPalette.accent,
                                 label: "활발한 시간대",
                                 value: vm.peakHour.map { "\($0)시" } ?? "—",
                                 sub: nil)
                        miniStat(icon: "square.grid.2x2.fill",
                                 tint: DashboardPalette.accent,
                                 label: "기록된 앱",
                                 value: "\(vm.appTotals.count)",
                                 sub: nil)
                    }
                }
                Spacer(minLength: 0)

                // Category mini-legend with proportion bars — readable at a glance,
                // doesn't require the category tab to be open.
                if !vm.categoryTotals.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("카테고리 분포")
                            .font(.dbStatLabel)
                            .tracking(DashboardTracking.label)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(vm.categoryTotals, id: \.category) { ct in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(DashboardPalette.color(for: ct.category))
                                    .frame(width: 9, height: 9)
                                Text(ct.category?.name ?? "미분류")
                                    .font(.dbBody)
                                Spacer()
                                Text(TimeFormatting.percent(ct.seconds, of: vm.totalSeconds))
                                    .font(.dbTag)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 240)
                }
            }
        }
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let d = vm.delta {
            let up = d.seconds >= 0
            let color = up ? DashboardPalette.deltaUp : DashboardPalette.deltaDown
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                Text(String(format: "%@%.0f%%", up ? "+" : "", d.percent))
                    .font(.dbTag)
                    .monospacedDigit()
                Text("· \(vm.previousPeriodName)")
                    .font(.dbCaptionSmall)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
        }
    }

    private func miniStat(icon: String, tint: Color, label: String,
                          value: String, sub: String?) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.dbStatLabel)
                    .tracking(DashboardTracking.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.dbStatValue)
                    .lineLimit(1)
                if let sub {
                    Text(sub).font(.dbCaption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Primary chart card

    /// Single card slot that hosts whichever chart is right for the period.
    /// Always present in the layout, so swapping periods doesn't cause the
    /// content height to leap and reflow everything below.
    private var primaryChartCard: some View {
        DashboardCard(
            title: vm.period == .day ? "오늘의 시간대별 활성도" : "기간 추이",
            action: AnyView(
                Text(chartLegend)
                    .font(.dbStatLabel)
                    .tracking(DashboardTracking.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            )
        ) {
            if vm.totalSeconds == 0 {
                emptyState(message: "선택한 기간에 기록된 활동이 없습니다",
                           icon: "moon.zzz")
                    .frame(height: 220)
            } else if vm.period == .day {
                HourlyTimelineChart(series: vm.hourlySeries, peakHour: vm.peakHour)
                    .frame(height: 240)
            } else {
                DailySeriesBarChart(series: vm.dailySeries, period: vm.period)
                    .frame(height: 240)
            }

            // Only show the weekday×hour heatmap when the range spans multiple
            // weekdays — for a single day the timeline above already covers it.
            if vm.range.dayCount >= 7 && vm.totalSeconds > 0 {
                Divider().padding(.vertical, 8)
                Text("요일 × 시간 패턴")
                    .font(.dbStatLabel)
                    .tracking(DashboardTracking.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                WeekHourHeatmap(cells: vm.heatmap)
                    .frame(height: 200)
            }
        }
    }

    private var chartLegend: String {
        switch vm.period {
        case .day:   return "0시 — 23시"
        case .week:  return "월 — 일"
        case .month: return "월간"
        case .range: return "\(vm.range.dayCount)일"
        }
    }

    // MARK: - Lists card

    private var listsCard: some View {
        DashboardCard {
            TabView {
                appsTab.tabItem { Label("앱", systemImage: "square.stack.3d.up.fill") }
                categoriesTab.tabItem { Label("카테고리", systemImage: "tag.fill") }
                webTab.tabItem { Label("웹페이지", systemImage: "globe") }
            }
            .controlSize(.large)
            .frame(minHeight: 380)
        }
    }

    private var appsTab: some View {
        let totals = vm.filteredAppTotals
        let max = totals.first?.seconds ?? 1
        return Group {
            if totals.isEmpty {
                emptyState(message: "이 기간에 기록된 앱이 없습니다", icon: "app.dashed")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(totals.enumerated()), id: \.element.bundleID) { idx, t in
                            AppRow(
                                rank: idx + 1, total: t, max: max,
                                category: vm.categoryMapping[t.bundleID],
                                grandTotal: vm.totalSeconds,
                                browser: BrowserKind.from(bundleID: t.bundleID),
                                browserPages: vm.webByBrowser[t.bundleID] ?? [],
                                isExpanded: bindingForExpansion(of: t.bundleID),
                                onCategoryChange: { cat in
                                    vm.updateCategory(cat, for: t.bundleID)
                                },
                                allCategories: vm.categories
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func bindingForExpansion(of bundleID: String) -> Binding<Bool> {
        Binding(
            get: { expandedBrowsers.contains(bundleID) },
            set: { newValue in
                if newValue { expandedBrowsers.insert(bundleID) }
                else { expandedBrowsers.remove(bundleID) }
            }
        )
    }

    private var categoriesTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            if vm.categoryTotals.isEmpty || vm.totalSeconds == 0 {
                emptyState(message: "이 기간에 기록된 데이터가 없습니다", icon: "circle.dashed")
            } else {
                HStack(alignment: .center, spacing: 28) {
                    Chart(vm.categoryTotals, id: \.category) { ct in
                        SectorMark(
                            angle: .value("seconds", ct.seconds),
                            innerRadius: .ratio(0.62),
                            angularInset: 2
                        )
                        .foregroundStyle(DashboardPalette.color(for: ct.category))
                        .cornerRadius(4)
                    }
                    .frame(width: 240, height: 240)
                    .chartLegend(.hidden)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.categoryTotals, id: \.category) { ct in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DashboardPalette.color(for: ct.category))
                                    .frame(width: 12, height: 12)
                                Text(ct.category?.name ?? "미분류")
                                    .font(.dbHeadline)
                                Spacer()
                                Text(TimeFormatting.longHMS(ct.seconds))
                                    .font(.dbBody)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(TimeFormatting.percent(ct.seconds, of: vm.totalSeconds))
                                    .font(.dbHeadline)
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                                    .foregroundStyle(DashboardPalette.color(for: ct.category))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
            CategoryManagementSection(
                categories: vm.categories,
                onAdd: { name, hex in vm.addCategory(name: name, colorHex: hex) },
                onRename: { id, name, hex in vm.renameCategory(id: id, name: name, colorHex: hex) },
                onDelete: { id in vm.deleteCategory(id: id) }
            )
        }
    }

    private var webTab: some View {
        let totals = vm.filteredWebTotals
        let max = totals.first?.seconds ?? 1
        return Group {
            if totals.isEmpty {
                emptyState(message: "이 기간에 기록된 웹페이지가 없습니다", icon: "globe.badge.chevron.backward")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(totals.enumerated()), id: \.element.bucket) { idx, w in
                            WebRow(rank: idx + 1, total: w, max: max)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func emptyState(message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DashboardPalette.accentMuted)
            Text(message)
                .font(.dbBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.dbBody)
            Spacer()
            Button("다시 시도") { vm.reload() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.14)))
    }

    // MARK: - Date label helpers

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd (E)"
        return f.string(from: d)
    }
    private func weekLabel(_ r: DayRange) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd"
        let endShort = DateFormatter(); endShort.locale = Locale(identifier: "ko_KR")
        endShort.dateFormat = "MM.dd"
        return "\(f.string(from: r.start)) ~ \(endShort.string(from: r.end))"
    }
    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: d)
    }

    private func exportCurrentViewCSV() {
        let csv = SessionStore.appTotalsCSV(vm.appTotals, range: vm.range)
        let (first, last) = vm.range.dayKeys
        defaultExportName = "watchCat-\(first)_to_\(last)"
        exporterDocument = TextDocument(text: csv, contentType: .commaSeparatedText)
        showExporter = true
    }
}

// MARK: - 24-hour timeline chart (day mode)

/// 24 bars (0..23) with the peak hour highlighted in the brand color. This is
/// the centerpiece for day-mode viewing — much easier to read than a 7×24 heatmap
/// for a single day.
private struct HourlyTimelineChart: View {
    let series: [DailySeriesPoint]
    let peakHour: Int?

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { idx, point in
                BarMark(
                    x: .value("hour", idx),
                    y: .value("minutes", point.seconds / 60.0)
                )
                .foregroundStyle(
                    idx == peakHour ? DashboardPalette.highlight : DashboardPalette.accent
                )
                .cornerRadius(4)
                .annotation(position: .top) {
                    if idx == peakHour && point.seconds > 0 {
                        Text(TimeFormatting.longHMS(point.seconds))
                            .font(.dbCaptionSmall)
                            .monospacedDigit()
                            .foregroundStyle(DashboardPalette.highlight)
                    }
                }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisTick().foregroundStyle(.secondary.opacity(0.3))
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text("\(h)시")
                            .font(.dbCaptionSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let m = v.as(Double.self) {
                        Text(m >= 60 ? String(format: "%.0fh", m / 60.0)
                                     : String(format: "%.0fm", m))
                            .font(.dbCaptionSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in plot.padding(.top, 8) }
    }
}

// MARK: - Daily-series bar chart (week / month / range)

private struct DailySeriesBarChart: View {
    let series: [DailySeriesPoint]
    let period: DashboardPeriod

    var body: some View {
        let peakValue = series.map { $0.seconds }.max() ?? 0
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { idx, p in
                BarMark(
                    x: .value("day", labelForIndex(idx, day: p.day)),
                    y: .value("hours", p.seconds / 3600.0)
                )
                .foregroundStyle(
                    p.seconds == peakValue && peakValue > 0
                        ? DashboardPalette.highlight
                        : DashboardPalette.accent
                )
                .cornerRadius(5)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let h = v.as(Double.self) {
                        Text(String(format: "%.0fh", h))
                            .font(.dbCaptionSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(series.count, 10))) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                AxisValueLabel().font(.dbCaptionSmall)
            }
        }
    }

    /// Display labels per period. Week uses 월~일 weekday names, others use M/D.
    private func labelForIndex(_ idx: Int, day: String) -> String {
        if period == .week {
            let names = ["월", "화", "수", "목", "금", "토", "일"]
            return names[idx % 7]
        }
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
}

// MARK: - Week × hour heatmap (only shown for ranges ≥ 7 days)

private struct WeekHourHeatmap: View {
    let cells: [HeatmapCell]
    private let weekdayLabels = ["월", "화", "수", "목", "금", "토", "일"]

    var body: some View {
        let maxValue = cells.map { $0.seconds }.max() ?? 1

        Chart(cells, id: \.id) { cell in
            RectangleMark(
                xStart: .value("hourStart", cell.hour),
                xEnd: .value("hourEnd", cell.hour + 1),
                yStart: .value("dayStart", weekdayLabels[(cell.weekday - 1).clamped(to: 0...6)]),
                yEnd: .value("dayEnd", weekdayLabels[(cell.weekday - 1).clamped(to: 0...6)])
            )
            .foregroundStyle(intensityColor(cell.seconds, max: maxValue))
            .cornerRadius(3)
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.0))
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text("\(h)")
                            .font(.dbCaptionSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(.dbCaptionSmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func intensityColor(_ value: TimeInterval, max: TimeInterval) -> Color {
        guard max > 0 else { return DashboardPalette.cellEmpty }
        let t = value / max
        if t <= 0.001 { return DashboardPalette.cellEmpty }
        // Three-stop gradient: empty → low → high. Smooth perceptual ramp so
        // moderately-busy hours don't visually disappear next to peaks.
        let low = DashboardPalette.cellLow
        let high = DashboardPalette.cellHigh
        return Color.interpolate(low, high, t: t)
    }
}

private extension Color {
    static func interpolate(_ a: Color, _ b: Color, t: Double) -> Color {
        // NSColor conversion gives us RGBA components; we lerp linearly.
        let ca = NSColor(a).usingColorSpace(.displayP3) ?? .black
        let cb = NSColor(b).usingColorSpace(.displayP3) ?? .black
        let clamped = max(0, min(1, t))
        let r = ca.redComponent + (cb.redComponent - ca.redComponent) * clamped
        let g = ca.greenComponent + (cb.greenComponent - ca.greenComponent) * clamped
        let bl = ca.blueComponent + (cb.blueComponent - ca.blueComponent) * clamped
        let al = ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * clamped
        return Color(.displayP3, red: r, green: g, blue: bl, opacity: al)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension HeatmapCell {
    var id: String { "\(weekday)-\(hour)" }
}

// MARK: - Rows

private struct AppRow: View {
    let rank: Int
    let total: AppTotal
    let max: TimeInterval
    let category: AppCategory?
    let grandTotal: TimeInterval
    /// Non-nil for known browsers (Chrome / Safari / Whale). Drives the
    /// disclosure chevron + pointing-hand cursor; non-browser rows render
    /// identically to the previous version.
    let browser: BrowserKind?
    let browserPages: [WebBucketTotal]
    @Binding var isExpanded: Bool
    let onCategoryChange: (AppCategory?) -> Void
    /// Full list of user-defined categories shown in the picker menu. Passed
    /// in by the parent (DashboardView) so AppRow doesn't need to reach into
    /// the view model directly.
    let allCategories: [AppCategory]

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    /// Cap the drill-down list at this many pages so a Chrome row with 200
    /// domains doesn't blow up the dashboard height. Anything past this gets
    /// summarized as "그 외 N개 · …".
    private static let pageLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if isExpanded && browser != nil {
                pagesSection
                    .padding(.leading, 38)   // align with the row title (rank gutter)
                    .padding(.trailing, 10)
                    .padding(.top, 8).padding(.bottom, 10)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
        )
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var rowBackground: Color {
        if isExpanded {
            return DashboardPalette.accentSoft.opacity(scheme == .dark ? 0.45 : 0.55)
        }
        if isHovering && browser != nil {
            return DashboardPalette.accentSoft.opacity(scheme == .dark ? 0.28 : 0.32)
        }
        return .clear
    }

    private var mainRow: some View {
        HStack(spacing: 14) {
            rankBadge

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if browser != nil {
                        // Disclosure indicator only on browser rows. Rotates
                        // smoothly so the affordance reads as "this is alive".
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DashboardPalette.accent)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                    }
                    Text(total.displayName)
                        .font(.dbHeadline)
                        .lineLimit(1)
                    categoryPicker
                    if browser != nil, isExpanded {
                        Text("\(browserPages.count)개 페이지")
                            .font(.dbTagSmall)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 1.5)
                            .background(Capsule().fill(.secondary.opacity(0.12)))
                    }
                    Spacer()
                    Text(TimeFormatting.longHMS(total.seconds))
                        .font(.dbBody)
                        .monospacedDigit()
                    Text(TimeFormatting.percent(total.seconds, of: grandTotal))
                        .font(.dbTag)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [barColor.opacity(0.78), barColor],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if browser != nil {
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .onTapGesture {
            // Only browser rows are tappable; non-browser rows are static info.
            guard browser != nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        }
    }

    /// Inline category picker. Renders the existing colored chip when a
    /// category is set, or a muted "분류" pill when unset. Either form opens
    /// a Menu that lets the user pick / clear the category — the change is
    /// persisted via `onCategoryChange`.
    private var categoryPicker: some View {
        Menu {
            if allCategories.isEmpty {
                Text("카테고리가 없습니다")
            } else {
                ForEach(allCategories) { cat in
                    Button {
                        onCategoryChange(cat)
                    } label: {
                        if category?.id == cat.id {
                            Label(cat.name, systemImage: "checkmark")
                        } else {
                            Text(cat.name)
                        }
                    }
                }
            }
            if category != nil {
                Divider()
                Button("분류 해제", role: .destructive) { onCategoryChange(nil) }
            }
        } label: {
            if let c = category {
                Text(c.name)
                    .font(.dbTagSmall)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(DashboardPalette.color(for: c).opacity(0.18)))
                    .foregroundStyle(DashboardPalette.color(for: c))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "tag")
                        .font(.system(size: 9, weight: .semibold))
                    Text("분류")
                        .font(.dbTagSmall)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.secondary.opacity(0.14)))
                .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var pagesSection: some View {
        if browserPages.isEmpty {
            Text("이 기간에 기록된 페이지가 없습니다")
                .font(.dbCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let visiblePages = Array(browserPages.prefix(Self.pageLimit))
            let leftover = browserPages.dropFirst(Self.pageLimit)
            let leftoverSeconds = leftover.reduce(0) { $0 + $1.seconds }
            let pageMax = browserPages.first?.seconds ?? 1

            VStack(spacing: 6) {
                ForEach(Array(visiblePages.enumerated()), id: \.element.bucket) { _, page in
                    PageDrillDownRow(page: page, max: pageMax, grandTotal: total.seconds)
                }
                if !leftover.isEmpty {
                    HStack {
                        Text("그 외 \(leftover.count)개 페이지")
                            .font(.dbCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(TimeFormatting.longHMS(leftoverSeconds))
                            .font(.dbCaption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1.0, total.seconds / max)
    }

    /// Bar color follows the app's category — productivity=indigo, communication=teal,
    /// entertainment=rose, other=stone, unclassified=accent. Carries useful info
    /// into the bar itself instead of leaving it a uniform indigo wash.
    private var barColor: Color {
        category.map { DashboardPalette.color(for: $0) } ?? DashboardPalette.accent
    }

    /// Tinted rank pill — gold for the top app, accent for #2/#3, plain for the rest.
    /// Gives the eye a single attractor when scanning a long list.
    @ViewBuilder
    private var rankBadge: some View {
        if rank == 1 {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DashboardPalette.highlight))
        } else if rank <= 3 {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(DashboardPalette.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DashboardPalette.accentSoft))
        } else {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

/// One page line inside an expanded browser row. Visually lighter than the
/// main `AppRow` — no rank, smaller progress bar — so it reads as a child
/// of the parent row rather than a peer in the list.
private struct PageDrillDownRow: View {
    let page: WebBucketTotal
    let max: TimeInterval
    let grandTotal: TimeInterval

    var body: some View {
        let tint = DashboardPalette.stableColor(for: page.bucket)
        HStack(spacing: 10) {
            // Tinted dot acts as a per-domain swatch — once a user knows
            // "teal = github", they spot it across sessions without reading.
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(page.bucket)
                        .font(.dbBody)
                        .lineLimit(1)
                    Spacer()
                    Text(TimeFormatting.longHMS(page.seconds))
                        .font(.dbBodySmall)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(TimeFormatting.percent(page.seconds, of: grandTotal))
                        .font(.dbTagSmall)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(width: 44, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.10))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [tint.opacity(0.55), tint],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1.0, page.seconds / max)
    }
}

private struct WebRow: View {
    let rank: Int
    let total: WebBucketTotal
    let max: TimeInterval

    var body: some View {
        let tint = DashboardPalette.stableColor(for: total.bucket)
        HStack(spacing: 14) {
            rankBadge(rank: rank, tint: tint)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(total.bucket)
                        .font(.dbHeadline)
                        .lineLimit(1)
                    Spacer()
                    Text(TimeFormatting.longHMS(total.seconds))
                        .font(.dbBody)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [tint.opacity(0.62), tint],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// Gold for #1, tinted soft pill for #2/#3, plain for the rest. Matches
    /// the app-row rank styling so the two tabs feel coherent.
    @ViewBuilder
    private func rankBadge(rank: Int, tint: Color) -> some View {
        if rank == 1 {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DashboardPalette.highlight))
        } else if rank <= 3 {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.18)))
        } else {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1.0, total.seconds / max)
    }
}

// MARK: - FileDocument for CSV export

struct TextDocument: FileDocument {
    var text: String
    var contentType: UTType

    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .json] }
    static var writableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .json] }

    init(text: String, contentType: UTType) {
        self.text = text
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            self.text = str
        } else {
            self.text = ""
        }
        self.contentType = .commaSeparatedText
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Category management (inline editor on the category tab)

/// Inline CRUD UI for user-editable categories. Lives at the bottom of the
/// category tab so users can rename / recolor / delete categories or add new
/// ones without leaving the dashboard. Edits commit on focus-out or Enter;
/// deletes prompt for confirmation (an app mapped to the category becomes
/// unclassified, which is irreversible without re-tagging).
private struct CategoryManagementSection: View {
    let categories: [AppCategory]
    let onAdd: (String, String) -> Void
    let onRename: (String, String, String) -> Void
    let onDelete: (String) -> Void

    @State private var showingAddSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("카테고리 관리")
                    .font(.dbCardTitle)
                    .tracking(DashboardTracking.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("카테고리 추가").font(.dbTag)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(DashboardPalette.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }

            if categories.isEmpty {
                Text("아직 추가된 카테고리가 없습니다")
                    .font(.dbBody)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(categories) { cat in
                        CategoryEditRow(
                            category: cat,
                            onRename: { newName, newHex in
                                onRename(cat.id, newName, newHex)
                            },
                            onDelete: { onDelete(cat.id) }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            CategoryAddSheet(
                onSave: { name, hex in
                    onAdd(name, hex)
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false }
            )
        }
    }
}

private struct CategoryEditRow: View {
    let category: AppCategory
    let onRename: (String, String) -> Void
    let onDelete: () -> Void

    @State private var nameDraft: String
    @State private var hexDraft: String
    @State private var showingDeleteAlert = false
    @State private var showingColorPicker = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    init(category: AppCategory, onRename: @escaping (String, String) -> Void,
         onDelete: @escaping () -> Void) {
        self.category = category
        self.onRename = onRename
        self.onDelete = onDelete
        _nameDraft = State(initialValue: category.name)
        _hexDraft = State(initialValue: category.colorHex)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showingColorPicker = true
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(ColorHex.color(from: hexDraft) ?? Color.gray)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .pointingCursor()
            .popover(isPresented: $showingColorPicker, arrowEdge: .bottom) {
                ColorPalettePopover(
                    selectedHex: hexDraft,
                    onPick: { picked in
                        hexDraft = picked
                        showingColorPicker = false
                        commit()
                    }
                )
            }

            TextField("이름", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.dbHeadline)
                .focused($nameFocused)
                .onSubmit { commit() }
                .onChange(of: nameFocused) { focused in
                    if !focused { commit() }
                }

            Spacer()

            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.secondary.opacity(scheme == .dark ? 0.16 : 0.08)))
            }
            .buttonStyle(.plain)
            .pointingCursor()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(scheme == .dark ? 0.45 : 0.6))
        )
        .alert("'\(category.name)' 카테고리를 삭제할까요?", isPresented: $showingDeleteAlert) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { onDelete() }
        } message: {
            Text("이 카테고리로 분류된 앱은 모두 미분류로 돌아갑니다.")
        }
    }

    private func commit() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameDraft = category.name
            return
        }
        if trimmed != category.name || hexDraft != category.colorHex {
            onRename(trimmed, hexDraft)
        }
    }
}

/// Modal sheet for creating a new category. Keeps the row layout clean
/// (a single "+ 카테고리 추가" button on the section header) while giving
/// new-category creation enough room for both name + color picker.
private struct CategoryAddSheet: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var hex: String = AppCategory.palette[0]
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 카테고리").font(.dbCardTitle)

            VStack(alignment: .leading, spacing: 6) {
                Text("이름").font(.dbStatLabel).foregroundStyle(.secondary)
                TextField("예: 학습, 운동, 게임…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("색상").font(.dbStatLabel).foregroundStyle(.secondary)
                ColorPaletteGrid(selectedHex: hex, onPick: { hex = $0 })
            }

            HStack {
                Spacer()
                Button("취소") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("추가") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onSave(trimmed, hex) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }
}

/// Compact swatch grid used by both the popover (from row edit) and the
/// add-sheet. 9 colors fit on two rows; the current pick gets a ring.
private struct ColorPaletteGrid: View {
    let selectedHex: String
    let onPick: (String) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(AppCategory.palette, id: \.self) { hex in
                Button {
                    onPick(hex)
                } label: {
                    Circle()
                        .fill(ColorHex.color(from: hex) ?? Color.gray)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .strokeBorder(hex == selectedHex
                                              ? Color.primary
                                              : Color.white.opacity(0.4),
                                              lineWidth: hex == selectedHex ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }
        }
    }
}

private struct ColorPalettePopover: View {
    let selectedHex: String
    let onPick: (String) -> Void

    var body: some View {
        ColorPaletteGrid(selectedHex: selectedHex, onPick: onPick)
            .padding(12)
    }
}

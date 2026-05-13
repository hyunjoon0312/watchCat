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
        .frame(minWidth: 980, minHeight: 700)
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
                    .frame(minWidth: 200)
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
                Text("→").foregroundStyle(.secondary).font(.system(size: 12, weight: .bold))
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
                                Text(ct.category?.displayName ?? "미분류")
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
                            AppRow(rank: idx + 1, total: t, max: max,
                                   category: vm.categoryMapping[t.bundleID],
                                   grandTotal: vm.totalSeconds)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var categoriesTab: some View {
        Group {
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
                                Text(ct.category?.displayName ?? "미분류")
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
            }
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
        f.dateFormat = "yyyy년 M월 d일 (E)"
        return f.string(from: d)
    }
    private func weekLabel(_ r: DayRange) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return "\(f.string(from: r.start)) — \(f.string(from: r.end))"
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

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(total.displayName)
                        .font(.dbHeadline)
                        .lineLimit(1)
                    if let c = category {
                        Text(c.displayName)
                            .font(.dbTagSmall)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(DashboardPalette.color(for: c).opacity(0.18)))
                            .foregroundStyle(DashboardPalette.color(for: c))
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
                                colors: [DashboardPalette.accent.opacity(0.85),
                                         DashboardPalette.accent],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.opacity(0.0001))
        )
    }

    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1.0, total.seconds / max)
    }
}

private struct WebRow: View {
    let rank: Int
    let total: WebBucketTotal
    let max: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.dbTagSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardPalette.accent)
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
                                colors: [DashboardPalette.cellLow,
                                         DashboardPalette.cellHigh],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
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

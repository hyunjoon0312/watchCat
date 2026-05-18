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
                        if vm.period == .day && vm.totalSeconds > 0 {
                            dayTimelineCard
                        }
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
                TextField("앱 · 웹페이지 검색", text: $vm.searchText)
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
                    .fill(DashboardPalette.surfaceMuted(dark: scheme == .dark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DashboardPalette.surfaceBorder(dark: scheme == .dark), lineWidth: 1)
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
                    Circle().fill(DashboardPalette.surfaceMuted(dark: scheme == .dark))
                )
                .overlay(Circle().strokeBorder(DashboardPalette.surfaceBorder(dark: scheme == .dark), lineWidth: 1))
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

    // MARK: - Day activity timeline card

    /// Activity/rest 24-hour bar — same data the menubar popover uses, but
    /// rendered taller with a hover tooltip that names the segment under the
    /// cursor (range + duration). Day mode only.
    private var dayTimelineCard: some View {
        DashboardCard(
            title: "활동 · 휴식 시간",
            action: AnyView(
                Text("0시 — 24시")
                    .font(.dbStatLabel)
                    .tracking(DashboardTracking.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            )
        ) {
            DashboardDayTimeline(
                intervals: vm.dayActivityIntervals,
                offIntervals: vm.dayOffIntervals,
                anchor: vm.range.start
            )
        }
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
                onDelete: { id in vm.deleteCategory(id: id) },
                onReorder: { ids in vm.reorderCategories(ids: ids) }
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

// MARK: - 24-hour activity / rest bar (day mode, dashboard variant)

/// Dashboard-sized activity/rest timeline. Same data shape as the menubar
/// popover's `DayTimeline`, rendered taller and with a hover tooltip so the
/// user can read off the exact start/end and duration of any segment without
/// reaching for the menubar.
private struct DashboardDayTimeline: View {
    /// Merged active intervals expressed as `[0, 1]` fractions of the 24-hour
    /// day. The complement of these is "rest".
    let intervals: [(start: Double, end: Double)]
    /// 슬립/종료 구간(꺼짐). 휴식과 시각·라벨이 분리되어 표시된다.
    let offIntervals: [(start: Double, end: Double)]
    /// Start-of-day for the date being shown — used so hover labels show wall
    /// clock times in the user's calendar (e.g. "09:42") rather than fractions.
    let anchor: Date
    @Environment(\.colorScheme) private var scheme
    /// Hover state. Stores both the bar-relative fraction (for positioning the
    /// tooltip) and the resolved hovered segment (active or rest).
    @State private var hover: HoverInfo?

    /// 3-hour grid (0, 3, …, 24) — same cadence as the popover. Wider on the
    /// dashboard, but the visual rhythm matches the popover bar so people who
    /// learned to read it there have nothing to relearn.
    private static let tickHours = [0, 3, 6, 9, 12, 15, 18, 21, 24]
    /// 막대 바깥 컨테이너의 모서리 — 캡슐을 떼고 "약간만" 둥근 사각형으로.
    private static let barCornerRadius: CGFloat = 4
    /// 내부 활동/꺼짐 세그먼트의 모서리. 컨테이너보다 약간 더 작게 잡아
    /// 클립될 때 자연스럽게 라인이 맞도록 함.
    private static let segmentCornerRadius: CGFloat = 3

    private struct HoverInfo: Equatable {
        let fraction: Double
        let kind: SegmentKind
        let startFrac: Double
        let endFrac: Double
    }
    private enum SegmentKind: Equatable { case active, rest, off }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    bar(width: geo.size.width)
                    // 마우스 위치로 호버 정보를 갱신. 매 픽셀 이동마다 세그먼트
                    // 룩업을 다시 돌리지만 인터벌은 보통 < 50개라 비용은 무시.
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                let frac = min(1, max(0, pt.x / geo.size.width))
                                hover = resolveHover(at: frac)
                            case .ended:
                                hover = nil
                            }
                        }
                    if let h = hover {
                        tooltip(for: h, width: geo.size.width)
                            .offset(x: tooltipX(for: h.fraction, width: geo.size.width),
                                    y: -54)
                    }
                }
            }
            .frame(height: 28)

            tickRow
        }
    }

    /// The bar itself: rest background, gridlines, active segments, "now" tick.
    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous)
                .fill(restColor)

            ForEach(Self.tickHours.dropFirst().dropLast(), id: \.self) { h in
                Rectangle()
                    .fill(.primary.opacity(scheme == .dark ? 0.18 : 0.10))
                    .frame(width: 1)
                    .offset(x: width * Double(h) / 24.0)
            }

            // 꺼짐 구간을 먼저 그림: 활동 구간이 그 위에 덮이는 일은 거의
            // 없지만(슬립 중에는 세션이 안 열리므로), 만에 하나 겹치더라도
            // 활동이 시각적으로 우선이 되도록 순서를 둠. 모서리는 살짝만
            // 둥글려 "막대"라는 느낌(캡슐의 알약 형태가 아닌)을 유지.
            ForEach(offIntervals.indices, id: \.self) { idx in
                let iv = offIntervals[idx]
                let w = max(2, width * (iv.end - iv.start))
                RoundedRectangle(cornerRadius: Self.segmentCornerRadius, style: .continuous)
                    .fill(offColor)
                    .frame(width: w)
                    .offset(x: width * iv.start)
            }

            ForEach(intervals.indices, id: \.self) { idx in
                let iv = intervals[idx]
                let w = max(2, width * (iv.end - iv.start))
                RoundedRectangle(cornerRadius: Self.segmentCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(colors: [activeStart, activeEnd],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: w)
                    .offset(x: width * iv.start)
            }

            // 미래 영역(아직 오지 않은 시각)을 옅게 덮어 "휴식과 다르다"는
            // 신호를 시각적으로도 줌. 캡슐 모양으로 클립되도록 ZStack 전체에
            // .clipShape(Capsule())을 마지막에 적용.
            if isToday && nowFraction < 1 {
                Rectangle()
                    .fill(scheme == .dark
                          ? Color.black.opacity(0.45)
                          : Color.white.opacity(0.62))
                    .frame(width: max(0, width * (1 - nowFraction)))
                    .offset(x: width * nowFraction)
            }

            if isToday {
                Rectangle()
                    .fill(.primary.opacity(0.85))
                    .frame(width: 1.5)
                    .offset(x: width * nowFraction)
            }

            if let h = hover {
                Rectangle()
                    .fill(.primary.opacity(0.55))
                    .frame(width: 1)
                    .offset(x: width * h.fraction)
            }
        }
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: Self.barCornerRadius, style: .continuous))
    }

    private var tickRow: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Self.tickHours, id: \.self) { h in
                    Text("\(h)")
                        .font(.dbCaptionSmall)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .offset(x: tickX(for: h, totalWidth: geo.size.width, label: "\(h)"))
                }
            }
        }
        .frame(height: 14)
    }

    private var legend: some View {
        let activeSeconds = intervals.reduce(0.0) { $0 + ($1.end - $1.start) } * 86400
        let offSeconds = offIntervals.reduce(0.0) { $0 + ($1.end - $1.start) } * 86400
        // 오늘이라면 "아직 지나지 않은 시간"을 휴식에 포함하지 않음. 휴식은
        // (지나간 시간 − 활동 − 꺼짐)으로 정의해서 세 합계의 합이 elapsed와
        // 일치하도록 한다.
        let elapsedSeconds = elapsedFraction * 86400
        let restSeconds = max(0, elapsedSeconds - activeSeconds - offSeconds)
        return HStack(spacing: 18) {
            legendItem(color: activeStart, label: "활동", seconds: activeSeconds)
            legendItem(color: restColor, label: "휴식", seconds: restSeconds)
            legendItem(color: offColor, label: "꺼짐", seconds: offSeconds)
            Spacer()
            Text("막대 위로 마우스를 올리면 세부 정보 표시")
                .font(.dbCaptionSmall)
                .foregroundStyle(.secondary)
        }
    }

    private func legendItem(color: Color, label: String, seconds: TimeInterval) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.dbBody)
                .foregroundStyle(.primary)
            Text(TimeFormatting.longHMS(seconds))
                .font(.dbBody)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Tooltip card. Two lines: the time range covered by the segment plus its
    /// duration. Kept compact so it doesn't obscure neighbouring segments at
    /// pixel-level precision.
    private func tooltip(for h: HoverInfo, width: CGFloat) -> some View {
        let startDate = anchor.addingTimeInterval(h.startFrac * 86400)
        let endDate = anchor.addingTimeInterval(h.endFrac * 86400)
        let duration = (h.endFrac - h.startFrac) * 86400
        let title: String = {
            switch h.kind {
            case .active: return "활동"
            case .rest:   return "휴식"
            case .off:    return "꺼짐"
            }
        }()
        let tint: Color = {
            switch h.kind {
            case .active: return activeStart
            case .rest:   return restAccent
            case .off:    return offColor
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.dbStatLabel)
                    .foregroundStyle(.primary)
                Text(TimeFormatting.longHMS(duration))
                    .font(.dbStatLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("\(clockLabel(startDate)) ~ \(clockLabel(endDate))")
                .font(.dbCaptionSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DashboardPalette.surfaceCard(dark: scheme == .dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DashboardPalette.surfaceBorder(dark: scheme == .dark), lineWidth: 1)
        )
        .shadow(color: DashboardPalette.surfaceShadow(dark: scheme == .dark),
                radius: 6, x: 0, y: 3)
        .allowsHitTesting(false)
    }

    /// Find the active segment that contains `frac`. If none does, fall back to
    /// describing the surrounding rest gap so the tooltip is informative across
    /// the entire bar (not just over filled regions). Returns nil over the
    /// "not yet" region of today — that area isn't a real rest period.
    private func resolveHover(at frac: Double) -> HoverInfo? {
        if frac > elapsedFraction { return nil }
        // 우선순위: 활동 > 꺼짐 > 휴식. 활동과 꺼짐은 거의 겹치지 않지만 만에
        // 하나 겹쳤을 때 사용자에게 더 중요한 정보(=활동)를 우선 표시.
        for iv in intervals where iv.start <= frac && frac <= iv.end {
            return HoverInfo(fraction: frac, kind: .active,
                             startFrac: iv.start, endFrac: iv.end)
        }
        for iv in offIntervals where iv.start <= frac && frac <= iv.end {
            return HoverInfo(fraction: frac, kind: .off,
                             startFrac: iv.start, endFrac: iv.end)
        }
        // 휴식 구간 = 그 외. 활동/꺼짐 인터벌의 합집합 바깥 경계를 찾아 구간을
        // 좁힌다. upper는 미래 영역(elapsedFraction)으로도 잘림.
        var lower = 0.0
        var upper = elapsedFraction
        let edges = (intervals + offIntervals).sorted { $0.start < $1.start }
        for iv in edges {
            if iv.end <= frac { lower = max(lower, iv.end) }
            if iv.start >= frac { upper = min(upper, iv.start); break }
        }
        return HoverInfo(fraction: frac, kind: .rest,
                         startFrac: lower, endFrac: upper)
    }

    /// Clamp the tooltip so it doesn't overflow the card edges. ~200pt wide
    /// is the maximum we ever need for "활동 · 1시간 23분 / 09:42 ~ 11:05".
    private func tooltipX(for frac: Double, width: CGFloat) -> CGFloat {
        let approx: CGFloat = 200
        let raw = width * frac - approx / 2
        return max(0, min(width - approx, raw))
    }

    private func tickX(for hour: Int, totalWidth: CGFloat, label: String) -> CGFloat {
        let frac = CGFloat(hour) / 24.0
        let approxWidth: CGFloat = label.count <= 1 ? 8 : 14
        let centered = totalWidth * frac - approxWidth / 2
        if hour == 0 { return 0 }
        if hour == 24 { return totalWidth - approxWidth }
        return centered
    }

    private func clockLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private var activeStart: Color {
        Color(.displayP3, red: 0.49, green: 0.42, blue: 0.99, opacity: 1)
    }
    private var activeEnd: Color {
        Color(.displayP3, red: 0.37, green: 0.30, blue: 0.92, opacity: 1)
    }
    /// 휴식: 활동(인디고)과 명도가 충분히 다르고 꺼짐과도 한눈에 갈리도록
    /// 라이트는 아주 밝은 라벤더 그레이, 다크는 중간 회색으로 잡았다.
    private var restColor: Color {
        scheme == .dark
            ? Color(.displayP3, red: 0.42, green: 0.40, blue: 0.46, opacity: 1)
            : Color(.displayP3, red: 0.90, green: 0.88, blue: 0.93, opacity: 1)
    }
    /// 꺼짐: 휴식과의 명도 차를 크게 벌려 막대에서 즉시 구분되도록 함. 라이트
    /// 모드에서는 짙은 슬레이트(거의 차콜)로, 다크 모드에서는 활동(인디고)과
    /// 헷갈리지 않게 푸른빛이 거의 없는 거의 검정에 가까운 회색으로.
    private var offColor: Color {
        scheme == .dark
            ? Color(.displayP3, red: 0.08, green: 0.08, blue: 0.10, opacity: 1)
            : Color(.displayP3, red: 0.26, green: 0.25, blue: 0.30, opacity: 1)
    }
    /// Slightly more saturated dot for the rest tooltip — the bar itself uses
    /// a quiet neutral, but a tiny dot in the popover needs to be visible.
    private var restAccent: Color {
        scheme == .dark
            ? Color(.displayP3, red: 0.55, green: 0.53, blue: 0.60, opacity: 1)
            : Color(.displayP3, red: 0.62, green: 0.60, blue: 0.66, opacity: 1)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(anchor)
    }

    /// "지금까지 흘러간 시간"의 0–1 비율. 과거 날짜는 1.0(24시간 모두 흐름),
    /// 오늘이면 자정부터 현재까지의 비율. 휴식 합계와 호버 가능한 영역의 상한
    /// 둘 다 이 값을 기준으로 계산해, 미래 시간이 휴식으로 둔갑하지 않음.
    private var elapsedFraction: Double {
        isToday ? nowFraction : 1.0
    }

    private var nowFraction: Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return 0 }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / span))
    }
}

// MARK: - 24-hour timeline chart (day mode)

/// 24 bars (0..23) with the peak hour highlighted in the brand color. This is
/// the centerpiece for day-mode viewing — much easier to read than a 7×24 heatmap
/// for a single day.
private struct HourlyTimelineChart: View {
    let series: [DailySeriesPoint]
    let peakHour: Int?
    /// Index (0–23) of the hour the user is currently hovering over. Used to
    /// surface per-hour minute counts that aren't visible in the bare bar chart
    /// — before this, only the peak hour had a number above it, so all other
    /// bars were "guess the height" reads.
    @State private var hoveredHour: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { idx, point in
                BarMark(
                    x: .value("hour", idx),
                    y: .value("minutes", point.seconds / 60.0)
                )
                .foregroundStyle(barColor(idx: idx))
                .cornerRadius(4)
                .annotation(position: .top) {
                    annotation(for: idx, point: point)
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            // chartOverlay covers the whole chart, including the
                            // y-axis gutter. Translate to plot-area coords first,
                            // then ask the chart proxy for the value at that x.
                            let origin = geo[proxy.plotAreaFrame].origin
                            let local = CGPoint(x: pt.x - origin.x, y: pt.y - origin.y)
                            if let raw: Double = proxy.value(atX: local.x) {
                                let idx = Int(raw.rounded())
                                // 빈 시간대(0초)에 호버하면 피크 라벨이 사라져
                                // 플롯 상단 여유가 바뀌면서 y축이 흔들리는 듯
                                // 보였음. 데이터가 있는 시간대만 호버 상태로
                                // 잡아서, 피크 annotation 위치가 유지되도록 함.
                                if (0...23).contains(idx),
                                   idx < series.count,
                                   series[idx].seconds > 0 {
                                    hoveredHour = idx
                                } else {
                                    hoveredHour = nil
                                }
                            } else {
                                hoveredHour = nil
                            }
                        case .ended:
                            hoveredHour = nil
                        }
                    }
            }
        }
    }

    /// Highlight the peak hour (gold) and the hovered hour (deeper accent), so
    /// the eye tracks the cursor's column as the user scans the bar chart.
    private func barColor(idx: Int) -> Color {
        if idx == hoveredHour {
            return DashboardPalette.accent
        }
        if idx == peakHour {
            return DashboardPalette.highlight
        }
        return DashboardPalette.accent.opacity(0.78)
    }

    /// Label rules: hovered hour wins (shows precise duration), peak hour as
    /// fallback. Other hours stay unlabeled to avoid axis clutter — the bar
    /// height plus the y-axis still gives an approximate read.
    @ViewBuilder
    private func annotation(for idx: Int, point: DailySeriesPoint) -> some View {
        if idx == hoveredHour && point.seconds > 0 {
            HourBadge(hour: idx, seconds: point.seconds,
                      tint: DashboardPalette.accent,
                      isHover: true)
        } else if idx == peakHour && hoveredHour == nil && point.seconds > 0 {
            HourBadge(hour: idx, seconds: point.seconds,
                      tint: DashboardPalette.highlight,
                      isHover: false)
        }
    }
}

/// Floating label that surfaces "Nh Mm at HHh" for the hovered or peak bar.
/// Pulled out so the hover and peak presentations share styling — earlier they
/// drifted apart (peak was plain text, hover was a chip) and looked unrelated.
private struct HourBadge: View {
    let hour: Int
    let seconds: TimeInterval
    let tint: Color
    let isHover: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("\(hour)시")
                .font(.dbCaptionSmall)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(TimeFormatting.longHMS(seconds))
                .font(.dbCaptionSmall)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, isHover ? 7 : 0)
        .padding(.vertical, isHover ? 2 : 0)
        .background(
            Group {
                if isHover {
                    Capsule().fill(tint.opacity(0.14))
                }
            }
        )
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
                    Image(nsImage: AppIconProvider.icon(for: total.bundleID, size: 18))
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
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
            FaviconView(host: page.bucket, size: 14)
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
                    FaviconView(host: total.bucket, size: 18)
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
    let onReorder: ([String]) -> Void

    @State private var showingAddSheet = false
    /// Local in-flight order while a drag is happening. Synced from `categories`
    /// in `.onChange` so external edits (add/rename/delete via reload) flow in
    /// without stomping a drag in progress.
    @State private var workingOrder: [AppCategory] = []
    @State private var draggingID: String?

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

            if workingOrder.isEmpty {
                Text("아직 추가된 카테고리가 없습니다")
                    .font(.dbBody)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(workingOrder) { cat in
                        CategoryEditRow(
                            category: cat,
                            isDragging: draggingID == cat.id,
                            onRename: { newName, newHex in
                                onRename(cat.id, newName, newHex)
                            },
                            onDelete: { onDelete(cat.id) }
                        )
                        .onDrag {
                            draggingID = cat.id
                            return NSItemProvider(object: cat.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: CategoryDropDelegate(
                            target: cat,
                            workingOrder: $workingOrder,
                            draggingID: $draggingID,
                            commit: { ids in onReorder(ids) }
                        ))
                    }
                }
            }
        }
        .onAppear { workingOrder = categories }
        .onChange(of: categories) { newValue in
            // Only sync if not actively dragging — otherwise the reorder would
            // snap back to the server order mid-gesture.
            if draggingID == nil { workingOrder = newValue }
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

/// Reorders `workingOrder` when a row is dragged over another row. Commits
/// the final order to the store on drop completion via `commit`. SwiftUI's
/// `.draggable` / `.dropDestination` API would be cleaner but it's iOS17+;
/// `.onDrag` + DropDelegate works on macOS 14.
private struct CategoryDropDelegate: DropDelegate {
    let target: AppCategory
    @Binding var workingOrder: [AppCategory]
    @Binding var draggingID: String?
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggingID, sourceID != target.id,
              let from = workingOrder.firstIndex(where: { $0.id == sourceID }),
              let to = workingOrder.firstIndex(where: { $0.id == target.id })
        else { return }
        if workingOrder[to].id != sourceID {
            withAnimation(.easeInOut(duration: 0.18)) {
                workingOrder.move(fromOffsets: IndexSet(integer: from),
                                  toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        commit(workingOrder.map { $0.id })
        draggingID = nil
        return true
    }
}

private struct CategoryEditRow: View {
    let category: AppCategory
    let isDragging: Bool
    let onRename: (String, String) -> Void
    let onDelete: () -> Void

    @State private var nameDraft: String
    @State private var hexDraft: String
    @State private var showingDeleteAlert = false
    @State private var showingColorPicker = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    init(category: AppCategory, isDragging: Bool,
         onRename: @escaping (String, String) -> Void,
         onDelete: @escaping () -> Void) {
        self.category = category
        self.isDragging = isDragging
        self.onRename = onRename
        self.onDelete = onDelete
        _nameDraft = State(initialValue: category.name)
        _hexDraft = State(initialValue: category.colorHex)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help("드래그해서 순서 변경")

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
                .fill(DashboardPalette.surfaceMuted(dark: scheme == .dark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DashboardPalette.surfaceBorder(dark: scheme == .dark), lineWidth: 1)
        )
        .opacity(isDragging ? 0.4 : 1.0)
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
        let columns = Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6)
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

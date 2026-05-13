import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var animator: MascotAnimator?
    private let stateController = RecordingStateController.shared
    private let sessionStore: SessionStore?
    private var stateSubscription: AnyCancellable?
    private var bucketSubscription: AnyCancellable?
    private var resultSubscription: AnyCancellable?
    private var currentChromeBucket: String?
    private var lastChromeResult: ChromeTabResult?

    /// SPEC §F3.4 — number of per-page rows to show under the Chrome summary row.
    private static let chromePageRowLimit = 5

    /// SPEC §F3.5.2 — sticky row right below the status line that appears only
    /// when AppleScript is denied. Persisted as an ivar (not rebuilt with the
    /// summary) so it reacts the instant `WebSessionRecorder` notices the
    /// denial, not only on menu open.
    private let permissionAlertItem = NSMenuItem(
        title: "⚠︎ Chrome 탭 권한 필요 — 클릭해 설정 열기",
        action: nil, keyEquivalent: ""
    )

    // Stateful menu items kept as ivars so we can update titles when state changes.
    private let statusLineItem = NSMenuItem(title: "기록 중", action: nil, keyEquivalent: "")
    private let pauseToggleItem = NSMenuItem(title: "일시중지", action: nil, keyEquivalent: "p")
    /// Header + up to 3 app rows for today (SPEC §F1.4 / §F2.3). Rebuilt on menu open.
    private let summaryHeaderItem = NSMenuItem(title: "오늘 요약", action: nil, keyEquivalent: "")
    private var summaryRows: [NSMenuItem] = []

    init(sessionStore: SessionStore?) {
        self.sessionStore = sessionStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        attachButton()
        observeState()
        apply(state: stateController.state)
    }

    private func attachButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        animator = MascotAnimator(button: button)
    }

    private func buildMenu() {
        menu.delegate = self
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        permissionAlertItem.target = self
        permissionAlertItem.action = #selector(openAutomationSettings)
        permissionAlertItem.isHidden = true
        menu.addItem(permissionAlertItem)

        menu.addItem(.separator())

        summaryHeaderItem.isEnabled = false
        menu.addItem(summaryHeaderItem)
        // Summary rows are inserted between header and the next separator at menu-open time.

        menu.addItem(.separator())

        pauseToggleItem.action = #selector(togglePause)
        pauseToggleItem.target = self
        menu.addItem(pauseToggleItem)

        menu.addItem(.separator())

        let dashboard = NSMenuItem(title: "대시보드 열기...", action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        menu.addItem(dashboard)

        let settings = NSMenuItem(title: "설정 열기...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "watchCat 종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshTodaySummary()
    }

    private func refreshTodaySummary() {
        // Drop previous summary rows.
        for row in summaryRows { menu.removeItem(row) }
        summaryRows.removeAll()

        guard let store = sessionStore else {
            insertSummaryRow(NSMenuItem(title: "  (DB 사용 불가)", action: nil, keyEquivalent: ""))
            return
        }

        let appTotals: [AppTotal]
        let categoryTotals: [CategoryTotal]
        let mapping: [String: AppCategory]
        do {
            appTotals = try store.dailyTotals(for: Date())
            categoryTotals = try store.dailyTotalsByCategory(for: Date())
            mapping = try store.categoryMapping()
        } catch {
            insertSummaryRow(NSMenuItem(title: "  (요약 불러오기 실패)", action: nil, keyEquivalent: ""))
            return
        }

        if appTotals.isEmpty {
            insertSummaryRow(NSMenuItem(title: "  기록된 세션이 아직 없습니다", action: nil, keyEquivalent: ""))
            return
        }

        // Category section — SPEC §F5.3.
        for ct in categoryTotals {
            let label = ct.category?.displayName ?? "미분류"
            let item = NSMenuItem(title: "  [\(label)] \(Self.format(seconds: ct.seconds))",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            insertSummaryRow(item)
        }
        if !categoryTotals.isEmpty {
            insertSummaryRow(NSMenuItem.separator())
        }

        // Per-app rows with a category-assignment submenu.
        let webTotals: [WebBucketTotal] = (try? store.webDailyTotals(for: Date())) ?? []
        for total in appTotals.prefix(3) {
            let cat = mapping[total.bundleID]
            let catLabel = cat?.displayName ?? "미분류"
            let title = "  \(total.displayName) — \(Self.format(seconds: total.seconds))  ·  \(catLabel)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = makeCategorySubmenu(bundleID: total.bundleID, current: cat)
            insertSummaryRow(item)

            // SPEC §F3.4 — under the Chrome row, surface per-page top-N so users
            // can see *which* pages contributed to the Chrome total without
            // opening a separate window.
            if total.bundleID == ChromeTabReader.chromeBundleID {
                if webTotals.isEmpty {
                    let empty = NSMenuItem(title: "      (페이지 기록 없음)", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    insertSummaryRow(empty)
                } else {
                    for web in webTotals.prefix(Self.chromePageRowLimit) {
                        let pageItem = NSMenuItem(
                            title: "      └ \(web.bucket) — \(Self.format(seconds: web.seconds))",
                            action: nil, keyEquivalent: ""
                        )
                        pageItem.isEnabled = false
                        insertSummaryRow(pageItem)
                    }
                }
            }
        }

        let totalSeconds = appTotals.reduce(0) { $0 + $1.seconds }
        let totalItem = NSMenuItem(title: "  합계 — \(Self.format(seconds: totalSeconds))",
                                   action: nil, keyEquivalent: "")
        totalItem.isEnabled = false
        insertSummaryRow(totalItem)
    }

    private func makeCategorySubmenu(bundleID: String, current: AppCategory?) -> NSMenu {
        let sub = NSMenu()
        for cat in AppCategory.allCases {
            let item = NSMenuItem(title: cat.displayName,
                                  action: #selector(setCategoryFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = ["bundleID": bundleID, "category": cat.rawValue]
            if current == cat { item.state = .on }
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let clear = NSMenuItem(title: "미분류로 되돌리기",
                               action: #selector(setCategoryFromMenu(_:)),
                               keyEquivalent: "")
        clear.target = self
        clear.representedObject = ["bundleID": bundleID]  // no "category" key → clears
        if current == nil { clear.state = .on }
        sub.addItem(clear)
        return sub
    }

    @objc private func setCategoryFromMenu(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: String],
              let bundleID = dict["bundleID"] else { return }
        do {
            if let raw = dict["category"], let cat = AppCategory(rawValue: raw) {
                try sessionStore?.setCategory(cat, forBundleID: bundleID)
            } else {
                try sessionStore?.clearCategory(forBundleID: bundleID)
            }
        } catch {
            NSLog("[watchCat] category change failed: \(error.localizedDescription)")
        }
    }

    private func insertSummaryRow(_ item: NSMenuItem) {
        let headerIndex = menu.index(of: summaryHeaderItem)
        let insertAt = headerIndex + 1 + summaryRows.count
        menu.insertItem(item, at: insertAt)
        summaryRows.append(item)
    }

    private static func format(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d시간 %d분", h, m) }
        if m > 0 { return String(format: "%d분 %d초", m, s) }
        return String(format: "%d초", s)
    }

    private func observeState() {
        stateSubscription = stateController.$state.sink { [weak self] state in
            Task { @MainActor in self?.apply(state: state) }
        }
    }

    /// Wires the Chrome page label into the status line. Called from `AppDelegate`
    /// after both the recorder and the status bar exist.
    func attach(webRecorder: WebSessionRecorder) {
        bucketSubscription = webRecorder.$currentBucket.sink { [weak self] bucket in
            Task { @MainActor in
                self?.currentChromeBucket = bucket
                self?.apply(state: RecordingStateController.shared.state)
            }
        }
        resultSubscription = webRecorder.$lastResult.sink { [weak self] result in
            Task { @MainActor in
                self?.lastChromeResult = result
                self?.refreshPermissionAlert()
                self?.apply(state: RecordingStateController.shared.state)
            }
        }
    }

    /// Show/hide the sticky permission warning row based on the latest tab-read
    /// result. We only flag `.permissionDenied` (TCC errAEEventNotPermitted /
    /// user cancelled) — other failures are transient and don't need a banner.
    private func refreshPermissionAlert() {
        let denied: Bool
        if case .permissionDenied = lastChromeResult { denied = true } else { denied = false }
        permissionAlertItem.isHidden = !denied
    }

    @objc private func openAutomationSettings() {
        if let url = PermissionKind.appleEvents.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func apply(state: RecordingState) {
        switch state {
        case .recording:
            animator?.setMode(.recording)
            let permissionDenied: Bool
            if case .permissionDenied = lastChromeResult { permissionDenied = true } else { permissionDenied = false }
            if permissionDenied {
                // Chrome time is still being captured, but tab info is blocked —
                // be explicit about *why* page rows aren't appearing.
                statusLineItem.title = "기록 중 — Chrome 탭 권한 필요"
                statusItem.button?.toolTip = "watchCat — Chrome 탭 권한이 없어 페이지 단위 기록 불가"
            } else if let bucket = currentChromeBucket, !bucket.isEmpty {
                statusLineItem.title = "기록 중 · Chrome / \(bucket)"
                statusItem.button?.toolTip = "watchCat — 기록 중 · Chrome / \(bucket)"
            } else {
                statusLineItem.title = "기록 중"
                statusItem.button?.toolTip = "watchCat — 기록 중"
            }
            pauseToggleItem.title = "일시중지"
        case .paused(let reason):
            animator?.setMode(.paused)
            statusLineItem.title = "일시중지 — \(reason.displayLabel)"
            pauseToggleItem.title = "재개"
            statusItem.button?.toolTip = "watchCat — 일시중지 (\(reason.displayLabel))"
        }
    }

    @objc private func togglePause() {
        stateController.toggleManualPause()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openDashboard() {
        DashboardWindowController.shared.show(store: sessionStore)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

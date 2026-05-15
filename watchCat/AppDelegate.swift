import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var inactivityMonitor: InactivityMonitor?
    private var sessionStore: SessionStore?
    private var activeAppTracker: ActiveAppTracker?
    private var sessionRecorder: SessionRecorder?
    private var webSessionRecorder: WebSessionRecorder?
    private var browserTabReader: BrowserTabReader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip app startup when launched as the XCTest host — otherwise onboarding
        // and permission prompts block the test runner from connecting.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        if activateExistingInstanceIfRunning() {
            NSApp.terminate(nil)
            return
        }

        // Apply the user's theme preference before any window opens so the
        // appearance is already correct on first paint instead of flashing
        // from system → user-chosen.
        _ = ThemeManager.shared

        do {
            let url = try SessionStore.defaultDatabaseURL()
            sessionStore = try SessionStore(url: url)
            // SPEC §1 — apply user-configured retention on every launch. Cheap
            // when nothing is over the limit (indexed DELETE) and prevents the
            // DB from growing unbounded across sessions.
            if let store = sessionStore {
                do {
                    let removed = try store.prune(olderThanDays: RetentionSettings.days)
                    if removed > 0 {
                        NSLog("[watchCat] retention prune removed \(removed) rows")
                    }
                } catch {
                    NSLog("[watchCat] retention prune failed: \(error.localizedDescription)")
                }
            }
        } catch {
            NSLog("[watchCat] SessionStore init failed: \(error.localizedDescription)")
        }

        SettingsWindowController.shared.sessionStoreProvider = { [weak self] in self?.sessionStore }
        statusBarController = StatusBarController(sessionStore: sessionStore)
        inactivityMonitor = InactivityMonitor(state: .shared)

        if let store = sessionStore {
            let tracker = ActiveAppTracker()
            activeAppTracker = tracker
            let reader = BrowserTabReader()
            browserTabReader = reader

            // Both recorders register listeners on the tracker. Web recorder must
            // attach its listener before SessionRecorder.start() runs the initial
            // notification, otherwise it would miss the very first activation.
            let webRecorder = WebSessionRecorder(
                store: store, tracker: tracker, state: .shared, reader: reader
            )
            webSessionRecorder = webRecorder
            let recorder = SessionRecorder(store: store, tracker: tracker, state: .shared)
            sessionRecorder = recorder
            // Order: WebSessionRecorder.start() only registers listener + state sink.
            // SessionRecorder.start() then triggers tracker.start() which fans out
            // to both listeners.
            webRecorder.start()
            recorder.start()
            statusBarController?.attach(webRecorder: webRecorder)
        }

        if !AppState.shared.hasCompletedOnboarding {
            // First run: enable Launch-at-Login by default per SPEC §F0.3, then show onboarding.
            PermissionManager.shared.setLaunchAtLogin(true)
            OnboardingWindowController.shared.show()
        }
    }

    /// SPEC §F1.3.2 — close open sessions before exit so the next launch doesn't
    /// see them as still-running and inflate today's totals via live aggregation.
    func applicationWillTerminate(_ notification: Notification) {
        sessionRecorder?.stop()
        webSessionRecorder?.stop()
    }

    /// SPEC §F1.3.1 — only one watchCat process runs at a time.
    /// Returns true if another instance was already running (caller should terminate self).
    private func activateExistingInstanceIfRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        others.first?.activate()
        return true
    }
}

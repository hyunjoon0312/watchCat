import Foundation
import Combine

/// SPEC §F3.2 — while Chrome is the active app and recording is live, poll the
/// active tab and persist one row per (bucket, contiguous span).
///
/// The recorder is intentionally passive about app/state changes — it observes
/// `ActiveAppTracker.onChange` (already wired by `SessionRecorder`) and the
/// `RecordingStateController.state` publisher in parallel, mirroring the app-level
/// recorder so the two stay in lockstep without explicit coordination.
@MainActor
final class WebSessionRecorder {
    static let pollInterval: TimeInterval = 1.0

    private let store: SessionStore
    private let tracker: ActiveAppTracker
    private let state: RecordingStateController
    private let reader: ChromeTabReading
    private let clock: () -> Date

    private var pollTimer: Timer?
    private var stateSubscription: AnyCancellable?

    private var openSessionID: Int64?
    private var openBucket: String?

    /// Currently-open Chrome bucket — `nil` whenever no web session is open
    /// (Chrome not active, paused, incognito-collapsed without permission, etc.).
    /// Published so the status bar can mirror the active page label live.
    @Published private(set) var currentBucket: String?

    /// Most recent tab-read outcome. `@Published` so the status bar can surface
    /// a permission-denied banner the moment AppleScript starts failing — without
    /// the user having to wait for the next menu open to find out.
    @Published private(set) var lastResult: ChromeTabResult?

    init(store: SessionStore, tracker: ActiveAppTracker, state: RecordingStateController,
         reader: ChromeTabReading, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.tracker = tracker
        self.state = state
        self.reader = reader
        self.clock = clock
    }

    func start() {
        tracker.addListener { [weak self] info in
            MainActor.assumeIsolated { self?.handleAppChange(info) }
        }
        stateSubscription = state.$state.sink { [weak self] newState in
            MainActor.assumeIsolated { self?.handleStateChange(newState) }
        }
        evaluatePolling()
    }

    func stop() {
        stopPolling()
        closeOpenSession(at: clock())
        stateSubscription?.cancel()
        stateSubscription = nil
    }

    /// Exposed for tests; also called by the active-app listener.
    func handleAppChange(_ info: ActiveAppInfo) {
        // App switched → close any open web session before re-evaluating polling.
        closeOpenSession(at: clock())
        evaluatePolling()
    }

    // MARK: - Polling lifecycle

    private func handleStateChange(_ newState: RecordingState) {
        if case .paused = newState {
            closeOpenSession(at: clock())
        }
        evaluatePolling()
    }

    private func evaluatePolling() {
        let chromeActive = tracker.current?.bundleID == ChromeTabReader.chromeBundleID
        let recording: Bool
        if case .recording = state.state { recording = true } else { recording = false }
        if chromeActive && recording {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()  // run once immediately so KPI ≤ 1s holds on app activation
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Polling tick

    /// Exposed for tests — calls a single tab read + session reconciliation.
    func tick() {
        let result = reader.readActiveTab()
        lastResult = result
        let now = clock()
        switch result {
        case .chromeNotRunning, .noActiveTab, .permissionDenied, .failure:
            // Lose visibility into the tab → close any open session. We don't open
            // anything until we can read a real bucket again. Permission-denied is
            // surfaced through `lastResult` for the status bar menu.
            closeOpenSession(at: now)
        case let .tab(url, title, isIncognito):
            guard let bucket = URLUtilities.bucketKey(
                url: url, title: title, isIncognito: isIncognito
            ) else {
                closeOpenSession(at: now)
                return
            }
            if bucket == openBucket { return }
            closeOpenSession(at: now)
            openSession(bucket: bucket, url: url, title: title, isIncognito: isIncognito, at: now)
        }
    }

    private func openSession(bucket: String, url: String, title: String,
                             isIncognito: Bool, at start: Date) {
        let unit = WebRecordUnit.current()
        let storedURL = (unit != .domain) || isIncognito ? nil : url
        let storedTitle = (unit == .title) ? title : nil
        do {
            openSessionID = try store.startWebSession(
                at: start, bucket: bucket,
                url: storedURL.flatMap { WebRecordOptions.stripQuery ? URLUtilities.stripQuery(from: $0) : $0 },
                title: storedTitle,
                isIncognito: isIncognito
            )
            openBucket = bucket
            currentBucket = bucket
        } catch {
            NSLog("[watchCat] startWebSession failed: \(error.localizedDescription)")
            openSessionID = nil
            openBucket = nil
            currentBucket = nil
        }
    }

    private func closeOpenSession(at end: Date) {
        guard let id = openSessionID else { return }
        do {
            try store.endWebSession(id: id, at: end)
        } catch {
            NSLog("[watchCat] endWebSession failed: \(error.localizedDescription)")
        }
        openSessionID = nil
        openBucket = nil
        currentBucket = nil
    }
}

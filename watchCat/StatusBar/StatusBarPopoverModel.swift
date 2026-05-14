import AppKit
import Combine
import Foundation

/// Drives the SwiftUI popover that replaces the old `NSMenu`. Owns:
///   - recording state (paused vs. recording) and the toggle action
///   - today's per-app totals, plus the "currently watching Chrome/Safari/Whale on
///     <bucket>" label sourced from `WebSessionRecorder`
///   - a `permissionDenied` flag that bubbles up the Apple Events warning
///
/// One model instance per popover lifetime; created by `StatusBarController` and
/// passed into the hosting view. Re-fetches today's totals whenever the popover
/// becomes visible (cheap; in-memory SQLite-backed aggregates).
@MainActor
final class StatusBarPopoverModel: ObservableObject {
    @Published private(set) var recordingState: RecordingState = .recording
    @Published private(set) var currentBrowser: BrowserKind?
    @Published private(set) var currentBucket: String?
    @Published private(set) var permissionDenied: Bool = false
    @Published private(set) var todayTotals: [AppTotal] = []
    @Published private(set) var todayTotalSeconds: TimeInterval = 0
    @Published private(set) var todayCategoryTotals: [CategoryTotal] = []
    @Published private(set) var todayWebTotals: [WebBucketTotal] = []
    @Published private(set) var categoryMapping: [String: AppCategory] = [:]
    @Published private(set) var loadError: String?

    let sessionStore: SessionStore?
    private let stateController = RecordingStateController.shared
    private var stateSubscription: AnyCancellable?
    private var bucketSubscription: AnyCancellable?
    private var browserSubscription: AnyCancellable?
    private var resultSubscription: AnyCancellable?

    init(sessionStore: SessionStore?) {
        self.sessionStore = sessionStore
        self.recordingState = stateController.state
        stateSubscription = stateController.$state.sink { [weak self] new in
            Task { @MainActor in self?.recordingState = new }
        }
    }

    /// Wires the live web-session signals in once they exist. Called by
    /// `StatusBarController` after `AppDelegate` creates the recorder.
    func attach(webRecorder: WebSessionRecorder) {
        bucketSubscription = webRecorder.$currentBucket.sink { [weak self] b in
            Task { @MainActor in self?.currentBucket = b }
        }
        browserSubscription = webRecorder.$currentBrowser.sink { [weak self] b in
            Task { @MainActor in self?.currentBrowser = b }
        }
        resultSubscription = webRecorder.$lastResult.sink { [weak self] result in
            Task { @MainActor in
                if case .permissionDenied = result { self?.permissionDenied = true }
                else { self?.permissionDenied = false }
            }
        }
    }

    /// Re-fetch today's aggregates. Called on popover open + after pause
    /// toggles so the user sees fresh numbers each time the panel comes up.
    func reload() {
        guard let store = sessionStore else {
            loadError = "DB 사용 불가"
            todayTotals = []; todayTotalSeconds = 0
            todayCategoryTotals = []
            todayWebTotals = []
            return
        }
        do {
            todayTotals = try store.dailyTotals(for: Date())
            todayTotalSeconds = todayTotals.reduce(0) { $0 + $1.seconds }
            todayCategoryTotals = try store.dailyTotalsByCategory(for: Date())
            todayWebTotals = try store.webBucketTotals(in: DashboardRange.day(Date()))
            categoryMapping = try store.categoryMapping()
            loadError = nil
        } catch {
            loadError = "오늘 데이터 로드 실패"
        }
    }

    func togglePause() {
        stateController.toggleManualPause()
    }

    /// Convenience — short label like "기록 중 · Chrome / github.com" or
    /// "일시중지 — 잠금". Drives the status pill at the top of the popover.
    var statusLabel: String {
        switch recordingState {
        case .recording:
            if permissionDenied { return "기록 중 — 브라우저 탭 권한 필요" }
            if let browser = currentBrowser, let bucket = currentBucket, !bucket.isEmpty {
                return "기록 중 · \(browser.displayName) / \(bucket)"
            }
            return "기록 중"
        case .paused(let reason):
            return "일시중지 — \(reason.displayLabel)"
        }
    }

    var isPaused: Bool { recordingState.isPaused }
}

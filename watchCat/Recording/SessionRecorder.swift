import Foundation
import Combine

/// SPEC §F2.2 — bridges (active app changes) × (recording state) into the session log.
///
/// Lifecycle:
/// - state == recording, active app known → exactly one open session row
/// - on app switch: end open session, start a new one for the new app
/// - on pause (any reason): end open session, don't open a new one
/// - on resume: open a new session for the currently-frontmost app
@MainActor
final class SessionRecorder {
    private let store: SessionStore
    private let tracker: ActiveAppTracker
    private let state: RecordingStateController
    private let clock: () -> Date

    private var openSessionID: Int64?
    private var openBundleID: String?
    private var stateSubscription: AnyCancellable?

    init(store: SessionStore, tracker: ActiveAppTracker,
         state: RecordingStateController, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.tracker = tracker
        self.state = state
        self.clock = clock
    }

    func start() {
        // Both publishers are driven from the main actor; `assumeIsolated` runs the
        // handlers synchronously so tests can observe effects without awaiting.
        tracker.addListener { [weak self] info in
            MainActor.assumeIsolated { self?.handleAppChange(info) }
        }
        // Tracker first: emits the frontmost app via listeners → opens initial session
        // if we're already in .recording. Then the state sink — Combine's @Published
        // immediately re-emits the current value, but openSessionID is non-nil so the
        // resume branch becomes a no-op (no duplicate row).
        tracker.start()
        stateSubscription = state.$state.sink { [weak self] newState in
            MainActor.assumeIsolated { self?.handleStateChange(newState) }
        }
    }

    func stop() {
        // Persist any in-flight session before tearing down.
        closeOpenSession(at: clock())
        stateSubscription?.cancel()
        stateSubscription = nil
        tracker.stop()
    }

    // MARK: - Event handlers

    private func handleAppChange(_ info: ActiveAppInfo) {
        guard case .recording = state.state else { return }
        if info.bundleID == openBundleID { return }
        let now = clock()
        closeOpenSession(at: now)
        openSession(info: info, at: now)
    }

    private func handleStateChange(_ newState: RecordingState) {
        let now = clock()
        switch newState {
        case .recording:
            // Resume: open a session for whoever is currently frontmost.
            if openSessionID == nil, let info = tracker.current {
                openSession(info: info, at: now)
            }
        case .paused:
            closeOpenSession(at: now)
        }
    }

    // MARK: - Helpers

    private func openSession(info: ActiveAppInfo, at start: Date) {
        do {
            openSessionID = try store.startSession(
                at: start, bundleID: info.bundleID, displayName: info.displayName
            )
            openBundleID = info.bundleID
        } catch {
            NSLog("[watchCat] startSession failed: \(error.localizedDescription)")
            openSessionID = nil
            openBundleID = nil
        }
    }

    private func closeOpenSession(at end: Date) {
        guard let id = openSessionID else { return }
        do {
            try store.endSession(id: id, at: end)
        } catch {
            NSLog("[watchCat] endSession failed: \(error.localizedDescription)")
        }
        openSessionID = nil
        openBundleID = nil
    }
}

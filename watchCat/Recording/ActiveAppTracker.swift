import AppKit

struct ActiveAppInfo: Equatable {
    let bundleID: String
    let displayName: String
}

/// SPEC §F2.1 — observe the macOS frontmost-application stream.
///
/// `didActivateApplicationNotification` fires once per focus change. We debounce by
/// 250 ms (§F2.1.2) so transient activations (e.g. notification pop-ups, Dock peeks)
/// don't shred the session timeline. The debounce stays well under the ≤ 1s KPI.
@MainActor
class ActiveAppTracker {
    static let debounceInterval: TimeInterval = 0.25

    /// SPEC §F4.3.2 — guard against missed activation notifications by polling
    /// `frontmostApplication` directly every few seconds and reconciling drift.
    /// Same pattern as `InactivityMonitor`'s sanity timer.
    static let reconcileInterval: TimeInterval = 5.0

    var current: ActiveAppInfo?
    private var listeners: [(ActiveAppInfo) -> Void] = []

    /// Adds a listener; multiple callers (e.g. SessionRecorder + WebSessionRecorder)
    /// each get notified on every active-app change.
    func addListener(_ block: @escaping (ActiveAppInfo) -> Void) {
        listeners.append(block)
    }

    private var observer: NSObjectProtocol?
    private var pendingTimer: Timer?
    private var pendingApp: ActiveAppInfo?
    private var reconcileTimer: Timer?

    func start() {
        if let app = NSWorkspace.shared.frontmostApplication, let info = Self.info(from: app) {
            current = info
            NSLog("[watchCat] active app (initial) → \(info.bundleID)")
            notify(info)
        }
        let nc = NSWorkspace.shared.notificationCenter
        observer = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let info = Self.info(from: app) else { return }
            Task { @MainActor in self?.scheduleChange(to: info) }
        }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    func stop() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    /// Polls macOS directly and forces a sync when our cached `current` has
    /// drifted from the actual frontmost app — e.g. when a `didActivate`
    /// notification was dropped (full-screen swaps, Stage Manager, etc.).
    private func reconcile() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let info = Self.info(from: app) else { return }
        if info == current { return }
        NSLog("[watchCat] active app DRIFT — was=\(current?.bundleID ?? "nil"), actual=\(info.bundleID)")
        // Cancel any pending debounce so we don't fight ourselves, then apply now.
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingApp = nil
        current = info
        notify(info)
    }

    deinit { /* Timers/observers are cleaned up via stop() before deinit */ }

    private func scheduleChange(to info: ActiveAppInfo) {
        // Coalesce rapid activations — only the last app inside the debounce window
        // becomes the new "current". Same-app reactivations are ignored.
        if info == current && pendingApp == nil { return }
        pendingApp = info
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        defer { pendingApp = nil; pendingTimer = nil }
        guard let info = pendingApp else { return }
        if info == current { return }
        current = info
        NSLog("[watchCat] active app → \(info.bundleID)")
        notify(info)
    }

    /// Internal so test stubs can fan out to listeners without re-implementing the queue.
    func notify(_ info: ActiveAppInfo) {
        for listener in listeners { listener(info) }
    }

    nonisolated private static func info(from app: NSRunningApplication) -> ActiveAppInfo? {
        // SPEC §F2.1.1 — bundle ID is the primary key; fall back to PID-derived id
        // so processes without a bundle still get a stable identity within a session.
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let displayName = app.localizedName ?? bundleID
        return ActiveAppInfo(bundleID: bundleID, displayName: displayName)
    }
}

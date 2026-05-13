import AppKit

/// SPEC §F4 — lock / sleep / idle detection. Drives `RecordingStateController`
/// pause/resume transitions; the controller decides how to merge with manual pause.
@MainActor
final class InactivityMonitor {
    static let idleThresholdKey = "watchCat.idleThresholdSeconds"
    static let defaultIdleThreshold: TimeInterval = 300   // 5 min — SPEC §F4.4.1
    static let minIdleThreshold: TimeInterval = 60        // 1 min
    static let maxIdleThreshold: TimeInterval = 1800      // 30 min

    private let state: RecordingStateController
    private var pollTimer: Timer?
    private var sanityTimer: Timer?
    private var lockObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var systemLocked = false
    private var systemAsleep = false

    init(state: RecordingStateController) {
        self.state = state
        registerObservers()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        sanityTimer?.invalidate()
        let dnc = DistributedNotificationCenter.default()
        for obs in lockObservers { dnc.removeObserver(obs) }
        let wsnc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { wsnc.removeObserver(obs) }
    }

    /// Idle threshold in seconds, clamped to [min, max]. Reads UserDefaults each call
    /// so settings UI changes take effect immediately (SPEC §F4.4.1).
    var idleThreshold: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.idleThresholdKey)
        let value = stored > 0 ? stored : Self.defaultIdleThreshold
        return min(max(value, Self.minIdleThreshold), Self.maxIdleThreshold)
    }

    // MARK: - Observers

    private func registerObservers() {
        let dnc = DistributedNotificationCenter.default()
        lockObservers.append(
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleLocked() }
            }
        )
        lockObservers.append(
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleUnlocked() }
            }
        )

        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWillSleep() }
            }
        )
        workspaceObservers.append(
            wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleDidWake() }
            }
        )
    }

    private func startPolling() {
        // 1 Hz tick is enough to satisfy the SPEC ≤ 1s state-transition KPI for idle.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // SPEC §F4.3.2 — guard against missed lock/sleep notifications.
        sanityTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    // MARK: - Event handlers

    private func handleLocked() {
        systemLocked = true
        state.systemPause(reason: .locked)
    }

    private func handleUnlocked() {
        systemLocked = false
        if !systemAsleep { state.systemResume() }
    }

    private func handleWillSleep() {
        systemAsleep = true
        state.systemPause(reason: .sleeping)
    }

    private func handleDidWake() {
        systemAsleep = false
        if !systemLocked { state.systemResume() }
    }

    // MARK: - Idle polling

    private func tick() {
        // Lock/sleep take precedence — don't fight them with idle transitions.
        guard !systemLocked, !systemAsleep else { return }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!  // kCGAnyInputEventType
        )

        if idleSeconds >= idleThreshold {
            state.systemPause(reason: .idle)
        } else if case .paused(.idle) = state.state {
            // First input after idle pause — resume immediately.
            state.systemResume()
        }
    }
}

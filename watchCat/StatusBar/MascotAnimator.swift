import AppKit

@MainActor
final class MascotAnimator {
    enum Mode: Equatable { case recording, paused }

    private weak var statusButton: NSStatusBarButton?
    private var timer: Timer?
    private var frameIndex = 0
    private(set) var mode: Mode = .recording
    private var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var reduceMotionObserver: NSObjectProtocol?

    /// Unprefixed frame names — combined with `MascotKind.current.rawValue` at
    /// asset-lookup time so a single source of truth picks the right species.
    private static let recordFrames = [
        "record-1-left", "record-2-front", "record-3-right", "record-4-front", "record-5-blink"
    ]
    private static let pauseFrames = ["pause-1", "pause-2", "pause-3"]
    private static let staticRecording = "record-2-front"
    private static let staticPaused = "pause-2"

    private var mascotKindObserver: NSObjectProtocol?

    init(button: NSStatusBarButton) {
        self.statusButton = button
        observeReduceMotion()
        observeMascotKindChange()
        applyCurrentFrame()
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
        if let obs = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = mascotKindObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Switch to the user's selected mascot the instant Settings posts a change.
    /// Frame index resets so the new species starts from its first pose instead
    /// of mid-blink, which would otherwise read as a glitch.
    private func observeMascotKindChange() {
        mascotKindObserver = NotificationCenter.default.addObserver(
            forName: .mascotKindDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.frameIndex = 0
                self?.applyCurrentFrame()
            }
        }
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        frameIndex = 0
        applyCurrentFrame()
        scheduleTimer()
    }

    private func observeReduceMotion() {
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.frameIndex = 0
                self.applyCurrentFrame()
                self.scheduleTimer()
            }
        }
    }

    private var frames: [String] {
        switch mode {
        case .recording: return Self.recordFrames
        case .paused:    return Self.pauseFrames
        }
    }

    private var staticFrame: String {
        switch mode {
        case .recording: return Self.staticRecording
        case .paused:    return Self.staticPaused
        }
    }

    private var tickInterval: TimeInterval {
        switch mode {
        case .recording: return 0.45
        case .paused:    return 1.2
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard !reduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    private func advance() {
        frameIndex = (frameIndex + 1) % frames.count
        applyCurrentFrame()
    }

    private func applyCurrentFrame() {
        guard let button = statusButton else { return }
        let unprefixed = reduceMotion ? staticFrame : frames[frameIndex]
        let kind = MascotKind.current
        let assetName = "\(kind.rawValue)-\(unprefixed)"
        guard let image = NSImage(named: assetName) else {
            // Asset missing — fall back to text placeholder so we notice during dev.
            button.image = nil
            button.title = "🐱"
            return
        }
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = false  // colored asset, not template
        button.title = ""
        button.image = image
    }
}

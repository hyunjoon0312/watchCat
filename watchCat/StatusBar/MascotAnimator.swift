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

    private static let recordFrames = [
        "record-1-left", "record-2-front", "record-3-right", "record-4-front", "record-5-blink"
    ]
    private static let pauseFrames = ["pause-1", "pause-2", "pause-3"]
    private static let staticRecording = "record-2-front"
    private static let staticPaused = "pause-2"

    init(button: NSStatusBarButton) {
        self.statusButton = button
        observeReduceMotion()
        applyCurrentFrame()
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
        if let obs = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
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
        let name = reduceMotion ? staticFrame : frames[frameIndex]
        guard let image = NSImage(named: name) else {
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

import Foundation

enum PauseReason: String, Equatable {
    case manual
    case locked
    case sleeping
    case idle

    var displayLabel: String {
        switch self {
        case .manual:   return "수동"
        case .locked:   return "잠금"
        case .sleeping: return "슬립"
        case .idle:     return "자리비움"
        }
    }
}

enum RecordingState: Equatable {
    case recording
    case paused(reason: PauseReason)

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

@MainActor
final class RecordingStateController: ObservableObject {
    static let shared = RecordingStateController()

    @Published private(set) var state: RecordingState = .recording

    private init() {}

    func toggleManualPause() {
        switch state {
        case .recording:
            state = .paused(reason: .manual)
        case .paused:
            state = .recording
        }
    }

    // Hooks for F4 (lock/sleep/idle integration).
    func systemPause(reason: PauseReason) {
        // Don't override manual pause with a system trigger.
        if case .paused(.manual) = state { return }
        state = .paused(reason: reason)
    }

    func systemResume() {
        // Don't auto-resume if user manually paused.
        if case .paused(.manual) = state { return }
        state = .recording
    }
}

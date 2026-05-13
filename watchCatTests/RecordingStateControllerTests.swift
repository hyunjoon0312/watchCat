import XCTest
@testable import watchCat

@MainActor
final class RecordingStateControllerTests: XCTestCase {
    // The controller is a singleton; reset to a known state at the start of each test
    // so test ordering doesn't matter.
    override func setUp() async throws {
        let c = RecordingStateController.shared
        if c.state.isPaused { c.systemResume() }
        if case .paused(.manual) = c.state { c.toggleManualPause() }
        XCTAssertEqual(c.state, .recording)
    }

    func test_initialState_isRecording() {
        XCTAssertEqual(RecordingStateController.shared.state, .recording)
    }

    func test_toggleManualPause_pausesAndResumes() {
        let c = RecordingStateController.shared
        c.toggleManualPause()
        XCTAssertEqual(c.state, .paused(reason: .manual))
        c.toggleManualPause()
        XCTAssertEqual(c.state, .recording)
    }

    func test_systemPauseLocked_thenResume() {
        let c = RecordingStateController.shared
        c.systemPause(reason: .locked)
        XCTAssertEqual(c.state, .paused(reason: .locked))
        c.systemResume()
        XCTAssertEqual(c.state, .recording)
    }

    func test_systemPauseSleeping() {
        let c = RecordingStateController.shared
        c.systemPause(reason: .sleeping)
        XCTAssertEqual(c.state, .paused(reason: .sleeping))
    }

    func test_systemPauseIdle() {
        let c = RecordingStateController.shared
        c.systemPause(reason: .idle)
        XCTAssertEqual(c.state, .paused(reason: .idle))
    }

    // SPEC §F1.4.2 — manual pause is not overridden by system triggers and must be
    // released by the user, not by lock-unlock / sleep-wake / idle-input cycles.
    func test_manualPause_isNotOverriddenBySystemPause() {
        let c = RecordingStateController.shared
        c.toggleManualPause()
        XCTAssertEqual(c.state, .paused(reason: .manual))
        c.systemPause(reason: .locked)
        XCTAssertEqual(c.state, .paused(reason: .manual), "system pause must not clobber manual")
        c.systemPause(reason: .idle)
        XCTAssertEqual(c.state, .paused(reason: .manual))
    }

    func test_manualPause_isNotReleasedBySystemResume() {
        let c = RecordingStateController.shared
        c.toggleManualPause()
        c.systemResume()
        XCTAssertEqual(c.state, .paused(reason: .manual), "system resume must not release manual")
    }

    func test_systemPause_transitionsBetweenReasons() {
        // SPEC §F1.2.1: any system trigger → paused (same state, different reason label).
        let c = RecordingStateController.shared
        c.systemPause(reason: .locked)
        c.systemPause(reason: .sleeping)
        XCTAssertEqual(c.state, .paused(reason: .sleeping))
    }
}

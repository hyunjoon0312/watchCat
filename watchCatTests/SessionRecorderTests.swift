import XCTest
@testable import watchCat

/// Drives `SessionRecorder` with a controllable clock and a fake tracker, then asserts
/// the rows persisted in `SessionStore`. Covers SPEC §F2.2 session boundaries:
/// app switch, pause/resume, and ensures pause gaps don't produce phantom rows.
@MainActor
final class SessionRecorderTests: XCTestCase {

    // Tracker stub — same shape as ActiveAppTracker but driven from tests.
    @MainActor
    final class TrackerStub: ActiveAppTracker {
        // Suppress real NSWorkspace observation in tests.
        override func start() {
            if let c = current { notify(c) }
        }
        override func stop() {}
        func fire(_ info: ActiveAppInfo) {
            current = info
            notify(info)
        }
        func setCurrent(_ info: ActiveAppInfo?) { current = info }
    }

    private var clockNow = Date(timeIntervalSince1970: 1_700_000_000)
    private func now() -> Date { clockNow }
    private func advance(_ seconds: TimeInterval) { clockNow.addTimeInterval(seconds) }

    private let xcode = ActiveAppInfo(bundleID: "com.apple.dt.Xcode", displayName: "Xcode")
    private let chrome = ActiveAppInfo(bundleID: "com.google.Chrome", displayName: "Chrome")

    // Each test gets a fresh recording-state controller... except the controller is a
    // singleton. Reset it explicitly so test order doesn't matter.
    override func setUp() async throws {
        let c = RecordingStateController.shared
        if c.state.isPaused { c.systemResume() }
        if case .paused(.manual) = c.state { c.toggleManualPause() }
        XCTAssertEqual(c.state, .recording)
    }

    private func makeFixture() throws -> (SessionStore, TrackerStub, SessionRecorder) {
        let store = try SessionStore()
        let tracker = TrackerStub()
        let recorder = SessionRecorder(
            store: store, tracker: tracker,
            state: RecordingStateController.shared, clock: { [unowned self] in self.now() }
        )
        return (store, tracker, recorder)
    }

    func test_appSwitch_closesPreviousAndOpensNew() throws {
        let (store, tracker, recorder) = try makeFixture()
        tracker.setCurrent(xcode)
        recorder.start()
        advance(60)
        tracker.fire(chrome)
        advance(30)
        recorder.stop()  // forces close of the open Chrome row

        let rows = try store.allSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[0].duration, 60, accuracy: 0.01)
        XCTAssertEqual(rows[1].bundleID, "com.google.Chrome")
        XCTAssertEqual(rows[1].duration, 30, accuracy: 0.01)
    }

    // SPEC §F4.3 — pause closes the open session; the paused gap is NOT recorded.
    func test_pause_closesOpenSession_andResumeStartsNew() throws {
        let (store, tracker, recorder) = try makeFixture()
        tracker.setCurrent(xcode)
        recorder.start()
        advance(60)
        RecordingStateController.shared.systemPause(reason: .idle)
        advance(600)  // 10 min paused — must not be attributed to any app
        RecordingStateController.shared.systemResume()
        advance(45)
        recorder.stop()

        let rows = try store.allSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        // First row: 60s active Xcode pre-pause
        XCTAssertEqual(rows[0].bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[0].duration, 60, accuracy: 0.01)
        // Second row: 45s active Xcode post-resume — note the 600s gap is invisible
        XCTAssertEqual(rows[1].bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[1].duration, 45, accuracy: 0.01)

        let totals = try store.dailyTotals(for: rows[0].startAt)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].seconds, 105, accuracy: 0.01,
                       "only the 60+45=105 seconds of active time should count")
    }

    func test_appSwitchWhilePaused_isIgnoredUntilResume() throws {
        let (store, tracker, recorder) = try makeFixture()
        tracker.setCurrent(xcode)
        recorder.start()
        advance(20)
        RecordingStateController.shared.systemPause(reason: .locked)
        advance(60)
        tracker.fire(chrome)  // user switched apps while paused — no row should open
        advance(60)
        RecordingStateController.shared.systemResume()  // resume — open with current(=Chrome)
        advance(30)
        recorder.stop()

        let rows = try store.allSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(rows[0].duration, 20, accuracy: 0.01)
        XCTAssertEqual(rows[1].bundleID, "com.google.Chrome")
        XCTAssertEqual(rows[1].duration, 30, accuracy: 0.01)
    }

    func test_sameAppReactivation_doesNotOpenNewSession() throws {
        let (store, tracker, recorder) = try makeFixture()
        tracker.setCurrent(xcode)
        recorder.start()
        advance(10)
        tracker.fire(xcode)  // same app — should be a no-op
        advance(20)
        recorder.stop()

        let rows = try store.allSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].duration, 30, accuracy: 0.01)
    }
}

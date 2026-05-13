import XCTest
@testable import watchCat

@MainActor
final class WebSessionRecorderTests: XCTestCase {
    @MainActor
    final class TrackerStub: ActiveAppTracker {
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

    final class ReaderStub: BrowserTabReading {
        var nextResult: BrowserTabResult = .browserNotRunning
        var callCount = 0
        var lastBrowser: BrowserKind?
        /// Per-browser overrides — when set, takes precedence over `nextResult`.
        /// Lets tests model "Chrome returns tab A, Safari returns tab B" in one fixture.
        var resultByBrowser: [BrowserKind: BrowserTabResult] = [:]
        func readActiveTab(for browser: BrowserKind) -> BrowserTabResult {
            callCount += 1
            lastBrowser = browser
            return resultByBrowser[browser] ?? nextResult
        }
    }

    private var clockNow = Date(timeIntervalSince1970: 1_700_000_000)
    private func now() -> Date { clockNow }
    private func advance(_ seconds: TimeInterval) { clockNow.addTimeInterval(seconds) }

    private let chrome = ActiveAppInfo(bundleID: BrowserKind.chrome.bundleID, displayName: "Chrome")
    private let safari = ActiveAppInfo(bundleID: BrowserKind.safari.bundleID, displayName: "Safari")
    private let whale  = ActiveAppInfo(bundleID: BrowserKind.whale.bundleID, displayName: "Whale")
    private let xcode = ActiveAppInfo(bundleID: "com.apple.dt.Xcode", displayName: "Xcode")

    override func setUp() async throws {
        let c = RecordingStateController.shared
        if c.state.isPaused { c.systemResume() }
        if case .paused(.manual) = c.state { c.toggleManualPause() }
        XCTAssertEqual(c.state, .recording)
        // Settings defaults — clear any leftovers from sibling tests.
        let d = UserDefaults.standard
        d.removeObject(forKey: WebRecordUnit.userDefaultsKey)
        d.removeObject(forKey: WebRecordOptions.stripQueryKey)
        d.removeObject(forKey: WebRecordOptions.recordIncognitoDomainKey)
    }

    private func makeFixture() throws -> (SessionStore, TrackerStub, ReaderStub, WebSessionRecorder) {
        let store = try SessionStore()
        let tracker = TrackerStub()
        let reader = ReaderStub()
        let recorder = WebSessionRecorder(
            store: store, tracker: tracker, state: RecordingStateController.shared,
            reader: reader, clock: { [unowned self] in self.now() }
        )
        return (store, tracker, reader, recorder)
    }

    func test_pollsOnlyWhenChromeIsActive() throws {
        let (_, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(xcode)  // not Chrome
        reader.nextResult = .tab(url: "https://github.com", title: "GH", isIncognito: false)
        recorder.start()
        recorder.tick()  // tick is gated only by reader call — we expect zero open rows
        // Switching to Chrome should arm polling and the *next* tick should be productive.
        tracker.fire(chrome)
        recorder.tick()
        XCTAssertNotNil(recorder.lastResult)
    }

    func test_tick_opensAndClosesOnDomainChange() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        recorder.start()  // begins polling
        reader.nextResult = .tab(url: "https://github.com/a", title: "A", isIncognito: false)
        recorder.tick()
        advance(60)
        reader.nextResult = .tab(url: "https://github.com/b", title: "B", isIncognito: false)
        recorder.tick()  // same domain — should be a no-op
        advance(60)
        reader.nextResult = .tab(url: "https://news.ycombinator.com/", title: "HN", isIncognito: false)
        recorder.tick()  // domain changed → close GH, open HN
        advance(30)
        recorder.stop()

        let rows = try store.allWebSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bucket, "github.com")
        XCTAssertEqual(rows[0].duration, 120, accuracy: 0.01)
        XCTAssertEqual(rows[1].bucket, "news.ycombinator.com")
        XCTAssertEqual(rows[1].duration, 30, accuracy: 0.01)
    }

    func test_pause_closesWebSession() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        recorder.start()
        reader.nextResult = .tab(url: "https://github.com/a", title: "A", isIncognito: false)
        recorder.tick()
        advance(45)
        RecordingStateController.shared.systemPause(reason: .idle)  // closes via state sink
        advance(60)  // paused time should not accrue
        RecordingStateController.shared.systemResume()
        reader.nextResult = .tab(url: "https://github.com/a", title: "A", isIncognito: false)
        recorder.tick()
        advance(30)
        recorder.stop()

        let rows = try store.allWebSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].duration, 45, accuracy: 0.01, "pre-pause portion")
        XCTAssertEqual(rows[1].duration, 30, accuracy: 0.01, "post-resume portion; 60s paused gap excluded")
    }

    func test_chromeDeactivation_closesSession() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        recorder.start()
        reader.nextResult = .tab(url: "https://example.com/", title: "X", isIncognito: false)
        recorder.tick()
        advance(40)
        tracker.fire(xcode)  // user switches to Xcode
        advance(60)
        recorder.stop()

        let rows = try store.allWebSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].duration, 40, accuracy: 0.01)
    }

    func test_incognito_defaultsToBucketLabel() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        recorder.start()
        reader.nextResult = .tab(url: "https://secret.example.com/", title: "S", isIncognito: true)
        recorder.tick()
        advance(20)
        recorder.stop()

        let rows = try store.allWebSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bucket, URLUtilities.incognitoBucket)
        XCTAssertTrue(rows[0].isIncognito)
    }

    func test_permissionDenied_doesNotOpenRow() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        recorder.start()
        reader.nextResult = .permissionDenied
        recorder.tick()
        advance(30)
        recorder.stop()
        XCTAssertEqual(try store.allWebSessions().count, 0)
        XCTAssertEqual(recorder.lastResult, .permissionDenied)
    }

    // MARK: - Multi-browser (SPEC §F3 multi-browser)

    func test_safari_isPolledLikeChrome() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(safari)
        recorder.start()
        reader.nextResult = .tab(url: "https://apple.com/", title: "Apple", isIncognito: false)
        recorder.tick()
        advance(30)
        recorder.stop()

        let rows = try store.allWebSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bucket, "apple.com")
        XCTAssertEqual(rows[0].browserBundleID, BrowserKind.safari.bundleID,
                       "session must be tagged with the Safari bundle ID")
        XCTAssertEqual(reader.lastBrowser, .safari, "reader receives the active browser kind")
    }

    func test_whale_isPolledLikeChrome() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(whale)
        recorder.start()
        reader.nextResult = .tab(url: "https://naver.com/", title: "NAVER", isIncognito: false)
        recorder.tick()
        advance(20)
        recorder.stop()

        let rows = try store.allWebSessions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].browserBundleID, BrowserKind.whale.bundleID)
        XCTAssertEqual(reader.lastBrowser, .whale)
    }

    func test_browserSwitch_closesAndReopensRow() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        // Start in Chrome on github.com…
        tracker.setCurrent(chrome)
        reader.resultByBrowser[.chrome] = .tab(url: "https://github.com/", title: "GH", isIncognito: false)
        reader.resultByBrowser[.safari] = .tab(url: "https://apple.com/", title: "A", isIncognito: false)
        recorder.start()
        recorder.tick()
        advance(30)
        // …switch to Safari. Even if the user had been on github.com in Chrome,
        // Safari's separate browser should produce its own row.
        tracker.fire(safari)
        recorder.tick()
        advance(45)
        recorder.stop()

        let rows = try store.allWebSessions().sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].bucket, "github.com")
        XCTAssertEqual(rows[0].browserBundleID, BrowserKind.chrome.bundleID)
        XCTAssertEqual(rows[1].bucket, "apple.com")
        XCTAssertEqual(rows[1].browserBundleID, BrowserKind.safari.bundleID)
    }

    func test_webDailyTotals_filterByBrowser() throws {
        let (store, tracker, reader, recorder) = try makeFixture()
        tracker.setCurrent(chrome)
        reader.nextResult = .tab(url: "https://github.com/", title: "GH", isIncognito: false)
        recorder.start()
        recorder.tick()
        advance(30)
        tracker.fire(safari)
        reader.nextResult = .tab(url: "https://apple.com/", title: "A", isIncognito: false)
        recorder.tick()
        advance(20)
        recorder.stop()

        let allBrowsers = try store.webDailyTotals(for: now())
        XCTAssertEqual(allBrowsers.count, 2, "unfiltered query returns every browser's rows")

        let chromeOnly = try store.webDailyTotals(for: now(),
                                                  browserBundleID: BrowserKind.chrome.bundleID)
        XCTAssertEqual(chromeOnly.count, 1)
        XCTAssertEqual(chromeOnly[0].bucket, "github.com")

        let safariOnly = try store.webDailyTotals(for: now(),
                                                  browserBundleID: BrowserKind.safari.bundleID)
        XCTAssertEqual(safariOnly.count, 1)
        XCTAssertEqual(safariOnly[0].bucket, "apple.com")
    }
}

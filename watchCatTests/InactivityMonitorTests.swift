import XCTest
@testable import watchCat

@MainActor
final class InactivityMonitorTests: XCTestCase {
    private let key = InactivityMonitor.idleThresholdKey

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func makeMonitor() -> InactivityMonitor {
        // Construct with a fresh controller instance to avoid singleton coupling, but
        // we only inspect `idleThreshold` here, so the controller is unused.
        InactivityMonitor(state: RecordingStateController.shared)
    }

    func test_idleThreshold_defaultsToFiveMinutes() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(makeMonitor().idleThreshold, InactivityMonitor.defaultIdleThreshold)
        XCTAssertEqual(InactivityMonitor.defaultIdleThreshold, 300)
    }

    func test_idleThreshold_readsUserDefaults() {
        UserDefaults.standard.set(120.0, forKey: key)
        XCTAssertEqual(makeMonitor().idleThreshold, 120)
    }

    func test_idleThreshold_clampsBelowMinimum() {
        UserDefaults.standard.set(10.0, forKey: key)
        XCTAssertEqual(makeMonitor().idleThreshold, InactivityMonitor.minIdleThreshold)
    }

    func test_idleThreshold_clampsAboveMaximum() {
        UserDefaults.standard.set(5000.0, forKey: key)
        XCTAssertEqual(makeMonitor().idleThreshold, InactivityMonitor.maxIdleThreshold)
    }

    func test_idleThreshold_zeroFallsBackToDefault() {
        UserDefaults.standard.set(0.0, forKey: key)
        XCTAssertEqual(makeMonitor().idleThreshold, InactivityMonitor.defaultIdleThreshold)
    }
}

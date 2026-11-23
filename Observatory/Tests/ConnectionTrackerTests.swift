import XCTest
@testable import Observatory

final class ConnectionTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testIdleIsDisconnected() {
        var tracker = ConnectionTracker()
        XCTAssertEqual(tracker.phase, .disconnected)
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: t0)
        XCTAssertEqual(tracker.phase, .disconnected)
    }

    func testConnectThenStream() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        XCTAssertEqual(tracker.phase, .connecting)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(0.5))
        XCTAssertEqual(tracker.phase, .socketOpen)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        XCTAssertEqual(tracker.phase, .streaming)
    }

    func testConnectTimeout() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(7.9))
        XCTAssertEqual(tracker.phase, .connecting)
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(8.0))
        XCTAssertEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(12))
        XCTAssertEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        tracker.requestConnect(ip: "169.254.19.221", at: at(13))
        XCTAssertEqual(tracker.phase, .connecting)
    }

    func testSilentOpenNeverStreams() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(1.9))
        XCTAssertEqual(tracker.phase, .socketOpen)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(2.0))
        XCTAssertEqual(tracker.phase, .stalled)
    }

    func testStallAfterSilence() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: t0)
        XCTAssertEqual(tracker.phase, .streaming)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(1.9))
        XCTAssertEqual(tracker.phase, .streaming)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(2.0))
        XCTAssertEqual(tracker.phase, .stalled)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(3))
        XCTAssertEqual(tracker.phase, .streaming)
    }

    func testP2RunningStreams() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: true, datagramsPerSec: 0, now: at(1))
        XCTAssertEqual(tracker.phase, .streaming)
    }

    func testUserDisconnect() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        tracker.requestDisconnect()
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(2))
        XCTAssertEqual(tracker.phase, .disconnected)
    }

    func testUnrequestedDropIsError() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(2))
        XCTAssertEqual(tracker.phase, .error("Connection closed"))
    }

    func testExternalConnectIsTracked() {
        var tracker = ConnectionTracker()
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: t0)
        XCTAssertEqual(tracker.phase, .socketOpen)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        XCTAssertEqual(tracker.phase, .streaming)
    }

    func testRadioOffWhileSocketRunsTimesOut() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        for s in stride(from: 0.0, through: 7.9, by: 0.1) {
            tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(s))
        }
        XCTAssertEqual(tracker.phase, .stalled)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(8.0))
        XCTAssertEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(12))
        XCTAssertEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(13))
        XCTAssertEqual(tracker.phase, .streaming)
    }

    func testDataThenSilenceStaysStalled() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        for s in stride(from: 2.0, through: 20.0, by: 0.5) {
            tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(s))
        }
        XCTAssertEqual(tracker.phase, .stalled)
    }

    func testDisconnectFromTimeoutError() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(8))
        XCTAssertEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        tracker.requestDisconnect()
        tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(8.5))
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(9))
        XCTAssertEqual(tracker.phase, .disconnected)
    }

    func testDisconnectFromErrorWithEngineDownIsImmediate() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(8))
        tracker.requestDisconnect()
        XCTAssertEqual(tracker.phase, .disconnected)
    }

    func testLaterExternalConnectDoesNotReuseOldRequest() {
        var tracker = ConnectionTracker()
        tracker.requestConnect(ip: "169.254.19.221", at: t0)
        tracker.update(running: true, p2Running: false, datagramsPerSec: 380, now: at(1))
        tracker.requestDisconnect()
        tracker.update(running: false, p2Running: false, datagramsPerSec: 0, now: at(2))
        XCTAssertEqual(tracker.phase, .disconnected)
        for s in stride(from: 20.0, through: 30.0, by: 0.5) {
            tracker.update(running: true, p2Running: false, datagramsPerSec: 0, now: at(s))
            XCTAssertNotEqual(tracker.phase, .error("No radio answered at 169.254.19.221"))
        }
        XCTAssertEqual(tracker.phase, .stalled)
    }
}

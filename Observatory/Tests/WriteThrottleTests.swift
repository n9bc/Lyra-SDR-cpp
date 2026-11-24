import XCTest
@testable import Observatory

final class WriteThrottleTests: XCTestCase {
    func testThrottleCapsRate() {
        var t = WriteThrottle<Int>()
        var sends = 0
        for ms in 0..<1000 where t.offer(ms, now: Double(ms) / 1000) != nil { sends += 1 }
        XCTAssertLessThanOrEqual(sends, 31)
        XCTAssertGreaterThanOrEqual(sends, 25)
    }

    func testFirstOfferSendsImmediately() {
        var t = WriteThrottle<Double>()
        XCTAssertEqual(t.offer(0.5, now: 10), 0.5)
        XCTAssertNil(t.offer(0.6, now: 10.001))
    }

    func testThrottleFlushesFinalValue() {
        var t = WriteThrottle<Int>()
        XCTAssertEqual(t.offer(1, now: 0), 1)
        XCTAssertNil(t.offer(2, now: 0.001))
        XCTAssertEqual(t.flush(), 2)
        XCTAssertNil(t.flush(), "the held value was already flushed")
    }

    /// A flush given the time counts as a send, so the next offer waits out the interval from it.
    func testTimedFlushRestartsTheInterval() {
        var t = WriteThrottle<Int>()
        XCTAssertEqual(t.offer(1, now: 0), 1)
        XCTAssertNil(t.offer(2, now: 0.01))
        XCTAssertEqual(t.flush(now: 0.04), 2)
        XCTAssertNil(t.offer(3, now: 0.05), "within 33 ms of the flush")
        XCTAssertEqual(t.offer(4, now: 0.08), 4)
    }

    func testFlushAfterLastOfferWasSentIsNil() {
        var t = WriteThrottle<Int>()
        XCTAssertEqual(t.offer(1, now: 0), 1)
        XCTAssertEqual(t.offer(2, now: 1), 2)
        XCTAssertNil(t.flush())
    }

    func testFlushSkipsAHeldValueEqualToTheLastSent() {
        var t = WriteThrottle<Int>()
        XCTAssertEqual(t.offer(5, now: 0), 5)
        XCTAssertNil(t.offer(6, now: 0.001))
        XCTAssertNil(t.offer(5, now: 0.002))
        XCTAssertNil(t.flush())
    }

    func testHeldValueSendsOnceTheIntervalHasPassed() {
        var t = WriteThrottle<Int>(interval: 0.1)
        XCTAssertEqual(t.offer(1, now: 0), 1)
        XCTAssertNil(t.offer(2, now: 0.05))
        XCTAssertEqual(t.offer(3, now: 0.11), 3)
        XCTAssertNil(t.flush())
    }
}

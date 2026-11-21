import XCTest
@testable import Observatory

final class FrequencyAndMeterTests: XCTestCase {
    func testDigits() {
        XCTAssertEqual(LyraFrequencyDisplay.digits(14_074_000), [0,1,4,0,7,4,0,0,0])
        XCTAssertEqual(LyraFrequencyDisplay.digits(0), Array(repeating: 0, count: 9))
        XCTAssertEqual(LyraFrequencyDisplay.digits(UInt32.max), Array(repeating: 9, count: 9))
    }
    func testDigitAdjustClamps() {
        XCTAssertEqual(LyraFrequencyDisplay.adjusted(14_074_000, place: 3, delta: 1), 14_075_000)
        XCTAssertEqual(LyraFrequencyDisplay.adjusted(500, place: 3, delta: -1), 0)
        XCTAssertEqual(LyraFrequencyDisplay.adjusted(499_000_000, place: 7, delta: 5), 500_000_000)
    }
    func testSMeterFraction() {
        XCTAssertEqual(LyraSMeter.fraction(dbm: -127), 0, accuracy: 1e-9)
        XCTAssertEqual(LyraSMeter.fraction(dbm: -73), 0.6, accuracy: 1e-9)
        XCTAssertEqual(LyraSMeter.fraction(dbm: -13), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LyraSMeter.fraction(dbm: -43), 0.8, accuracy: 1e-9)
        XCTAssertEqual(LyraSMeter.fraction(dbm: .nan), 0)
        XCTAssertEqual(LyraSMeter.fraction(dbm: 20), 1)
    }
    func testPeakHoldHoldsThenFalls() {
        var p = LyraSMeter.PeakHold(peakDbm: -127, heldAt: 0)
        XCTAssertEqual(p.update(dbm: -60, now: 0), -60)
        XCTAssertEqual(p.update(dbm: -100, now: 0.9), -60)
        XCTAssertEqual(p.update(dbm: -100, now: 1.5), -70, accuracy: 1e-9)
        XCTAssertEqual(p.update(dbm: -100, now: 10), -100)
    }
}

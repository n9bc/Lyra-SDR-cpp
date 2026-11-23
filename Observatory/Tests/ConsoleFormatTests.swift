import XCTest
@testable import Observatory

final class ConsoleFormatTests: XCTestCase {
    func testFrequencyGroups() {
        XCTAssertEqual(ConsoleFormat.frequency(7_128_500), "7.128.500")
        XCTAssertEqual(ConsoleFormat.frequency(14_195_000), "14.195.000")
        XCTAssertEqual(ConsoleFormat.frequency(1_840_000), "1.840.000")
        XCTAssertEqual(ConsoleFormat.frequency(144_200_000), "144.200.000")
        XCTAssertEqual(ConsoleFormat.frequency(0), "0.000.000")
    }
    func testSUnits() {
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: -73), "S9")
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: -63.2), "S9+10")
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: -97), "S5")
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: -150), "S0")
        XCTAssertEqual(ConsoleFormat.sUnits(dbm: -5), "S9+60")
    }
    func testMeterFractionClamps() {
        XCTAssertEqual(ConsoleFormat.meterFraction(dbm: -150), 0)
        XCTAssertEqual(ConsoleFormat.meterFraction(dbm: -5), 1)
        XCTAssertEqual(ConsoleFormat.meterFraction(dbm: -73), 0.6, accuracy: 1e-9)
    }
    func testOffsetsAndDb() {
        XCTAssertEqual(ConsoleFormat.offsetKHz(120), "+0.12 kHz")
        XCTAssertEqual(ConsoleFormat.offsetKHz(0), "+0.00 kHz")
        XCTAssertEqual(ConsoleFormat.offsetKHz(-50), "\u{2212}0.05 kHz")
        XCTAssertEqual(ConsoleFormat.signedDb(12), "+12 dB")
        XCTAssertEqual(ConsoleFormat.signedDb(-5), "\u{2212}5 dB")
        XCTAssertEqual(ConsoleFormat.signedDb(0), "0 dB")
    }
    func testTelemetryAndClock() {
        XCTAssertEqual(ConsoleFormat.telemetry(volts: nil), "not reported")
        XCTAssertEqual(ConsoleFormat.telemetry(volts: 13.8), "13.8 V")
        let d = Date(timeIntervalSince1970: 1_795_425_449) // 2026-11-23 09:17:29 UTC
        XCTAssertEqual(ConsoleFormat.clock(d, in: .gmt, utc: true), "09:17:29Z")
        XCTAssertEqual(ConsoleFormat.clock(d, in: TimeZone(identifier: "Europe/Oslo")!, utc: false), "10:17:29")
    }
    func testSegmentMeter() {
        let m = SegmentMeterModel(count: 44)
        XCTAssertEqual(m.litCount(fraction: 0), 0)
        XCTAssertEqual(m.litCount(fraction: 1), 44)
        XCTAssertEqual(m.zone(at: 0), .normal)
        XCTAssertEqual(m.zone(at: 43), .over)
    }
    func testSignedDbNonFiniteDoesNotTrap() {
        XCTAssertEqual(ConsoleFormat.signedDb(.nan), "\u{2014} dB")
        XCTAssertEqual(ConsoleFormat.signedDb(.infinity), "\u{2014} dB")
        XCTAssertEqual(ConsoleFormat.signedDb(-.infinity), "\u{2014} dB")
    }
    func testLitCountNonFiniteDoesNotTrap() {
        let m = SegmentMeterModel(count: 44)
        XCTAssertEqual(m.litCount(fraction: .infinity), 44)
        XCTAssertEqual(m.litCount(fraction: -.infinity), 0)
        XCTAssertEqual(m.litCount(fraction: .nan), 0)
    }
    func testFocusDetail() {
        XCTAssertEqual(ConsoleFormat.focusDetail("LSB", focused: .main), "LSB")
        XCTAssertEqual(ConsoleFormat.focusDetail("USB", focused: .sub), "SUB \u{00B7} USB")
    }
}

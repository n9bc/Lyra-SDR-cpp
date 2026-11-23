import XCTest
@testable import Observatory

/// The VFO panel's signal readouts when the radio has not reported a reading (final review,
/// Important 1 and deferred minor T1-3): never "-140.0 dBm", "nan dBm" or a fake S-unit.
final class VFOSignalReadoutTests: XCTestCase {
    func testReportedSignal() {
        XCTAssertEqual(VFOPanelView.readoutText(signalDbm: -63.2, snrDb: 24, enabled: true),
                       "\u{2212}63.2 dBm \u{00B7} SNR 24 dB")
        XCTAssertEqual(VFOPanelView.sUnitText(signalDbm: -63.2, enabled: true), "S9+10")
    }

    func testUnreportedSignal() {
        for dbm: Double? in [nil, .nan, .infinity] {
            XCTAssertEqual(VFOPanelView.readoutText(signalDbm: dbm, snrDb: nil, enabled: true),
                           "S-meter not reported")
            XCTAssertEqual(VFOPanelView.sUnitText(signalDbm: dbm, enabled: true), "S\u{2014}")
        }
    }

    func testReceiverOff() {
        XCTAssertEqual(VFOPanelView.readoutText(signalDbm: -63.2, snrDb: nil, enabled: false),
                       "Sub receiver off")
        XCTAssertEqual(VFOPanelView.sUnitText(signalDbm: -63.2, enabled: false), "S0")
    }
}

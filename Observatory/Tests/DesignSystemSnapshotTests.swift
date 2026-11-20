import XCTest
@testable import Observatory

final class DesignSystemSnapshotTests: XCTestCase {
    func testModeChangeUpdatesDefaultBandwidth() {
        let dsp = DspBridge.mock()
        dsp.setMode("CW")
        XCTAssertEqual(dsp.bandwidth, 500)
        dsp.setMode("USB")
        XCTAssertEqual(dsp.bandwidth, 2700)
        dsp.setMode("AM")
        XCTAssertEqual(dsp.bandwidth, 6000)
        dsp.setMode("FM")
        XCTAssertEqual(dsp.bandwidth, 12000)
        dsp.setMode("LSB")
        XCTAssertEqual(dsp.bandwidth, 2700)
    }

    func testBandLookupFromFrequency() {
        XCTAssertEqual(BandLookup.bandName(for: 14_074_000), "20")
        XCTAssertEqual(BandLookup.bandName(for: 7_074_000), "40")
        XCTAssertEqual(BandLookup.bandName(for: 3_573_000), "80")
        XCTAssertEqual(BandLookup.bandName(for: 1_000_000), "GEN")
    }

    func testFrequencyBoundarySafety() {
        let radio = RadioBridge.mock()
        radio.setFrequency(0)
        XCTAssertEqual(radio.rx1FreqHz, 0)
        XCTAssertEqual(BandLookup.bandName(for: radio.rx1FreqHz), "GEN")

        radio.setFrequency(UInt32.max)
        XCTAssertEqual(radio.rx1FreqHz, RadioBridge.maxFrequencyHz) // clamped, not the sentinel
        XCTAssertEqual(BandLookup.bandName(for: radio.rx1FreqHz), "GEN")

        radio.setFrequency(14_000_000)
        XCTAssertEqual(BandLookup.bandName(for: radio.rx1FreqHz), "20")
        radio.setFrequency(13_999_999) // one Hz below the 20m edge
        XCTAssertEqual(radio.rx1FreqHz, 13_999_999)
        XCTAssertEqual(BandLookup.bandName(for: radio.rx1FreqHz), "GEN")
    }
}

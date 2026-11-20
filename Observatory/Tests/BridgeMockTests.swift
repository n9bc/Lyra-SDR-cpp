import XCTest
@testable import Observatory

final class BridgeMockTests: XCTestCase {
    // MARK: RadioBridge
    func testRadioBridgeMockDefaults() {
        let bridge = RadioBridge.mock()
        XCTAssertFalse(bridge.isRunning)
        XCTAssertEqual(bridge.rx1FreqHz, 14_074_000)
        XCTAssertFalse(bridge.moxActive)
    }

    func testRadioBridgeSetFrequency() {
        let bridge = RadioBridge.mock()
        bridge.setFrequency(7_074_000)
        XCTAssertEqual(bridge.rx1FreqHz, 7_074_000)
    }

    func testRadioBridgeToggleMoxAndStartStop() {
        let bridge = RadioBridge.mock()
        bridge.toggleMox()
        XCTAssertTrue(bridge.moxActive)
        bridge.toggleMox()
        XCTAssertFalse(bridge.moxActive)
        bridge.start()
        XCTAssertTrue(bridge.isRunning)
        bridge.stop()
        XCTAssertFalse(bridge.isRunning)
    }

    // MARK: DspBridge
    func testDspBridgeMockDefaultsAndToggles() {
        let dsp = DspBridge.mock()
        XCTAssertEqual(dsp.mode, "USB")
        XCTAssertEqual(dsp.bandwidth, 3000)
        XCTAssertTrue(dsp.nrEnabled)
        XCTAssertTrue(dsp.nbEnabled)
        XCTAssertFalse(dsp.anfEnabled)
        XCTAssertEqual(dsp.agcMode, "MED")
        dsp.toggleNR(); dsp.toggleNB(); dsp.toggleANF()
        XCTAssertFalse(dsp.nrEnabled)
        XCTAssertFalse(dsp.nbEnabled)
        XCTAssertTrue(dsp.anfEnabled)
        dsp.setMode("LSB"); dsp.setBandwidth(2400); dsp.setAgcMode("FAST")
        XCTAssertEqual(dsp.mode, "LSB")
        XCTAssertEqual(dsp.bandwidth, 2400)
        XCTAssertEqual(dsp.agcMode, "FAST")
    }

    // MARK: MeterBridge
    func testMeterMockDefaults() {
        let m = MeterBridge.mock()
        XCTAssertEqual(m.sMeterDb, -79.0)
        XCTAssertEqual(m.sMeterText, "S8")
        XCTAssertEqual(m.txPowerW, 0.8)
        XCTAssertEqual(m.swr, 1.0)
    }

    func testSMeterTextAtS7And8() {
        let bridge = MeterBridge.mock()
        bridge.sMeterDb = -85.0
        XCTAssertEqual(bridge.sMeterText, "S7")
        bridge.sMeterDb = -79.0
        XCTAssertEqual(bridge.sMeterText, "S8")
    }

    func testSMeterTextAboveS9() {
        let bridge = MeterBridge.mock()
        bridge.sMeterDb = -53.0
        XCTAssertEqual(bridge.sMeterText, "S9+20")
    }

    func testSMeterNaNShowsS0() {
        let bridge = MeterBridge.mock()
        bridge.sMeterDb = .nan
        XCTAssertEqual(bridge.sMeterText, "S0")
    }

    func testSMeterBoundaries() {
        let bridge = MeterBridge.mock()
        bridge.sMeterDb = -73.0
        XCTAssertEqual(bridge.sMeterText, "S9")
        bridge.sMeterDb = -63.0
        XCTAssertEqual(bridge.sMeterText, "S9+10")
        bridge.sMeterDb = -127.0
        XCTAssertEqual(bridge.sMeterText, "S0")
        bridge.sMeterDb = -200.0
        XCTAssertEqual(bridge.sMeterText, "S0")
        bridge.sMeterDb = -121.0
        XCTAssertEqual(bridge.sMeterText, "S1")
    }

    // MARK: AudioBridge
    func testAudioBridgeMock() {
        let a = AudioBridge.mock()
        XCTAssertEqual(a.afGain, 42.0)
        XCTAssertEqual(a.rfGain, -12.0)
        XCTAssertFalse(a.muted)
        XCTAssertEqual(a.volume, 0.7)
        a.setAfGain(50); a.setRfGain(-6); a.toggleMute()
        XCTAssertEqual(a.afGain, 50)
        XCTAssertEqual(a.rfGain, -6)
        XCTAssertTrue(a.muted)
    }
}

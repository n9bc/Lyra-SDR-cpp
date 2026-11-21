import XCTest
@testable import Observatory

@MainActor
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

@MainActor
private final class FakeFacade: RadioFacade {
    var isRunning = false, moxActive = false, splitEnabled = false, txDisplayActive = false
    var rx1FreqHz: UInt32 = 7_074_000
    var vfoBHz: UInt32 = 7_100_000
    var callback: (@MainActor () -> Void)?
    var startedIp: String?

    func setRx1FreqHz(_ hz: UInt32) { rx1FreqHz = hz; callback?() }
    func setVfoBHz(_ hz: UInt32) { vfoBHz = hz; callback?() }
    func setMox(_ on: Bool) { moxActive = on; callback?() }
    func setSplitEnabled(_ on: Bool) { splitEnabled = on; callback?() }
    func start(withIp ip: String) { startedIp = ip; isRunning = true; callback?() }
    func stop() { isRunning = false; callback?() }
    func observeRadio(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

@MainActor
final class RadioBridgeTests: XCTestCase {
    func testMockBridgeHasDefaults() {
        let bridge = RadioBridge.mock()
        XCTAssertFalse(bridge.isRunning)
        XCTAssertEqual(bridge.rx1FreqHz, 14_074_000)
        XCTAssertFalse(bridge.moxActive)
    }

    func testFrequencyClampAtMax() {
        let bridge = RadioBridge.mock()
        bridge.setFrequency(600_000_000)
        XCTAssertEqual(bridge.rx1FreqHz, RadioBridge.maxFrequencyHz)
    }

    func testFrequencyClampAtUInt32Max() {
        let bridge = RadioBridge.mock()
        bridge.setFrequency(UInt32.max)
        XCTAssertEqual(bridge.rx1FreqHz, RadioBridge.maxFrequencyHz)
    }

    func testFacadeInitReadsInitialState() {
        let bridge = RadioBridge(facade: FakeFacade())
        XCTAssertEqual(bridge.rx1FreqHz, 7_074_000)
        XCTAssertEqual(bridge.vfoBHz, 7_100_000)
    }

    func testFacadeActionsForwardAndCallbackUpdatesState() {
        let fake = FakeFacade()
        let bridge = RadioBridge(facade: fake)
        bridge.setFrequency(UInt32.max)
        XCTAssertEqual(fake.rx1FreqHz, RadioBridge.maxFrequencyHz)
        XCTAssertEqual(bridge.rx1FreqHz, RadioBridge.maxFrequencyHz)
        bridge.toggleMox()
        XCTAssertTrue(fake.moxActive)
        XCTAssertTrue(bridge.moxActive)
        bridge.start()
        XCTAssertEqual(fake.startedIp, RadioBridge.defaultRadioIp)
        XCTAssertTrue(bridge.isRunning)
        bridge.stop()
        XCTAssertFalse(bridge.isRunning)
    }
}

@MainActor
private final class FakeDspFacade: DspFacade {
    var mode = "USB"
    var bandwidthHz = 2400
    var nrEnabled = false, nbEnabled = false, anfEnabled = false, squelchEnabled = false
    var agcMode = "SLOW"
    var passbandLowHz = 300.0
    var passbandHighHz = 2700.0
    var callback: (@MainActor () -> Void)?

    // Mimics a backend that picks its own bandwidth on mode change.
    func setMode(_ mode: String) { self.mode = mode; bandwidthHz = 1800; callback?() }
    func setBandwidthHz(_ hz: Int) { bandwidthHz = hz; callback?() }
    func setNrEnabled(_ on: Bool) { nrEnabled = on; callback?() }
    func setNbEnabled(_ on: Bool) { nbEnabled = on; callback?() }
    func setAnfEnabled(_ on: Bool) { anfEnabled = on; callback?() }
    func setAgcMode(_ mode: String) { agcMode = mode; callback?() }
    func observeDsp(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

@MainActor
final class DspBridgeTests: XCTestCase {
    func testMockDefaults() {
        let bridge = DspBridge.mock()
        XCTAssertEqual(bridge.mode, "USB")
        XCTAssertEqual(bridge.bandwidth, 3000)
        XCTAssertTrue(bridge.nrEnabled)
    }

    func testModeChangeResetsBandwidth() {
        let bridge = DspBridge.mock()
        bridge.setMode("CW")
        XCTAssertEqual(bridge.bandwidth, 500)
    }

    func testModeStringsMatchWdspEngine() {
        for mode in ["USB", "LSB", "CW", "AM", "FM", "SAM", "CWL", "CWU", "DIGU", "DIGL"] {
            let bridge = DspBridge.mock()
            bridge.setMode(mode)
            XCTAssertEqual(bridge.mode, mode)
        }
    }

    func testFacadeInitReadsInitialStateWithoutBandwidthReset() {
        let bridge = DspBridge(facade: FakeDspFacade())
        XCTAssertEqual(bridge.mode, "USB")
        XCTAssertEqual(bridge.bandwidth, 2400) // backend value, not mode default 2700
        XCTAssertEqual(bridge.agcMode, "SLOW")
        XCTAssertEqual(bridge.passbandLowHz, 300.0)
        XCTAssertEqual(bridge.passbandHighHz, 2700.0)
    }

    func testFacadeActionsForwardAndCallbackKeepsBackendBandwidth() {
        let fake = FakeDspFacade()
        let bridge = DspBridge(facade: fake)
        bridge.setMode("CW")
        XCTAssertEqual(fake.mode, "CW")
        XCTAssertEqual(bridge.mode, "CW")
        XCTAssertEqual(bridge.bandwidth, 1800) // not CW default 500
        bridge.toggleNR()
        XCTAssertTrue(fake.nrEnabled)
        XCTAssertTrue(bridge.nrEnabled)
        bridge.setAgcMode("FAST")
        XCTAssertEqual(bridge.agcMode, "FAST")
        bridge.setBandwidth(400)
        XCTAssertEqual(bridge.bandwidth, 400)
    }
}

@MainActor
private final class FakeMeterFacade: MeterFacade {
    var meterLevel = 0.6, meterPeak = 0.7, meterNormAtS9 = 0.5
    var meterText = "S9+20", meterDbmText = "-53 dBm"
    var liveSwr = 1.4, noiseFloorDbm = -118.0, rxSnrDb = 30.0
    var callback: (@MainActor () -> Void)?
    func observeMeter(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

@MainActor
private final class FakeAudioFacade: AudioFacade {
    var volume = 0.3, muted = false, afGainDb = 10.0, balance = -0.2
    var callback: (@MainActor () -> Void)?
    func setVolume(_ v: Double) { volume = v; callback?() }
    func setMuted(_ on: Bool) { muted = on; callback?() }
    func setAfGainDb(_ db: Double) { afGainDb = db; callback?() }
    func observeAudio(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

@MainActor
final class MeterAudioFacadeTests: XCTestCase {
    func testMockDerivesFromDb() {
        let m = MeterBridge.mock()
        m.sMeterDb = -53.0
        XCTAssertEqual(m.sMeterText, "S9+20")
        XCTAssertEqual(m.dbmText, "-53 dBm")
        m.sMeterDb = 100
        XCTAssertEqual(m.sMeterLevel, 1.0)
        m.sMeterDb = -200
        XCTAssertEqual(m.sMeterLevel, 0.0)
    }

    func testMeterMirrorsFacadeAndUpdates() {
        let f = FakeMeterFacade()
        let m = MeterBridge(facade: f)
        XCTAssertEqual(m.sMeterLevel, 0.6)
        XCTAssertEqual(m.sMeterText, "S9+20")
        XCTAssertEqual(m.dbmText, "-53 dBm")
        XCTAssertEqual(m.normAtS9, 0.5)
        XCTAssertEqual(m.swr, 1.4)
        f.meterLevel = 0.2; f.meterText = "S3"; f.rxSnrDb = 5
        f.callback?()
        XCTAssertEqual(m.sMeterLevel, 0.2)
        XCTAssertEqual(m.sMeterText, "S3")
        XCTAssertEqual(m.rxSnrDb, 5)
    }

    func testAudioMirrorsFacadeAndForwardsActions() {
        let f = FakeAudioFacade()
        let a = AudioBridge(facade: f)
        XCTAssertEqual(a.volume, 0.3)
        XCTAssertEqual(a.afGain, 10.0)
        a.toggleMute()
        XCTAssertTrue(f.muted)
        XCTAssertTrue(a.muted)
        a.setVolume(0.9)
        XCTAssertEqual(f.volume, 0.9)
        XCTAssertEqual(a.volume, 0.9)
        a.setAfGain(25)
        XCTAssertEqual(f.afGainDb, 25)
        a.afGain = 30  // knob binding path
        XCTAssertEqual(f.afGainDb, 30)
    }
}

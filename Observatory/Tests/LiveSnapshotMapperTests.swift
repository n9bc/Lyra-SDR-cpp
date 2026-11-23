import XCTest
@testable import Observatory

final class LiveSnapshotMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_425_449)
    private let utc = TimeZone(identifier: "UTC")!

    private func map(_ e: EngineState, phase: ConnectionPhase = .streaming,
                     locked: Bool = false) -> RadioSnapshot {
        LiveSnapshotMapper.snapshot(from: e, phase: phase, vfoLocked: locked, now: now, timeZone: utc)
    }

    func testMainFrequencyIncludesMarkerOffset() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_030_000
        e.radio.markerOffsetHz = 600
        XCTAssertEqual(map(e).main.frequencyHz, 7_030_600)
    }

    func testSubShowsVfoBWhenSplitOrSubOff() {
        var e = EngineState.idle
        e.radio.vfoBHz = 7_032_000
        e.radio.rx2Hz = 14_200_000
        e.radio.splitEnabled = true
        XCTAssertEqual(map(e).sub.frequencyHz, 7_032_000)
        e.radio.splitEnabled = false
        e.radio.subEnabled = true
        XCTAssertEqual(map(e).sub.frequencyHz, 14_200_000)
        e.radio.subEnabled = false
        XCTAssertEqual(map(e).sub.frequencyHz, 7_032_000)
    }

    func testFocusTwoWithoutSubMapsToMain() {
        var e = EngineState.idle
        e.radio.focusedRx = 2
        XCTAssertEqual(map(e).session.focused, .main)
        e.radio.subEnabled = true
        XCTAssertEqual(map(e).session.focused, .sub)
    }

    func testModesAndAgc() {
        var e = EngineState.idle
        e.filter.mode = "CWU"
        e.filter.modeRx2 = "USB"
        e.dsp.agcMode = "med"
        var s = map(e)
        XCTAssertEqual(s.main.mode, .cwu)
        XCTAssertEqual(s.sub.mode, .usb)
        XCTAssertEqual(s.main.agc, .med)
        XCTAssertEqual(s.sub.agc, .med)
        e.filter.mode = "XYZ"
        s = map(e)
        XCTAssertEqual(s.main.mode, .usb)
    }

    func testSplitRoles() {
        var e = EngineState.idle
        e.radio.splitEnabled = true
        let s = map(e)
        XCTAssertFalse(s.main.isTxVFO)
        XCTAssertTrue(s.sub.isTxVFO)
        XCTAssertTrue(s.main.splitTx)
        XCTAssertTrue(s.sub.splitTx)
    }

    func testRitOnlyOnMain() {
        var e = EngineState.idle
        e.radio.ritEnabled = true
        e.radio.ritHz = 120
        let s = map(e)
        XCTAssertTrue(s.main.ritEnabled)
        XCTAssertEqual(s.main.ritOffsetHz, 120)
        XCTAssertFalse(s.sub.ritEnabled)
        XCTAssertEqual(s.sub.ritOffsetHz, 0)
    }

    func testDisplaySpans() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_100_000
        e.radio.ritEnabled = true
        e.radio.ritHz = 120
        e.meters.spanHz = 96_000
        var s = map(e)
        XCTAssertEqual(s.display.spanLowHz, 7_052_120)
        XCTAssertEqual(s.display.spanHighHz, 7_148_120)
        e.radio.ctuneEnabled = true
        e.radio.ctuneCenterHz = 7_120_000
        s = map(e)
        XCTAssertEqual(s.display.spanLowHz, 7_072_000)
        XCTAssertTrue(s.session.ctunEnabled)
        e.radio.rx2Hz = 14_200_000
        e.meters.iqRateHz = 192_000
        s = map(e)
        XCTAssertEqual(s.display.subSpanLowHz, 14_104_000)
        XCTAssertEqual(s.display.subSpanHighHz, 14_296_000)
    }

    func testBandsAndSelection() {
        var e = EngineState.idle
        e.bands = [
            EngineBand(name: "160m", lowHz: 1_800_000, highHz: 2_000_000, defaultHz: 1_840_000),
            EngineBand(name: "80m", lowHz: 3_500_000, highHz: 4_000_000, defaultHz: 3_573_000),
            EngineBand(name: "40m", lowHz: 7_000_000, highHz: 7_300_000, defaultHz: 7_074_000),
            EngineBand(name: "6m", lowHz: 50_000_000, highHz: 54_000_000, defaultHz: 50_313_000),
        ]
        e.radio.rx1Hz = 7_100_000
        var s = map(e)
        XCTAssertEqual(s.band.bands, ["160", "80", "40"])
        XCTAssertEqual(s.band.selectedBand, "40")
        XCTAssertEqual(s.main.bandName, "40")
        e.link.isP2Rig = true
        s = map(e)
        XCTAssertEqual(s.band.bands, ["160", "80", "40", "6"])
    }

    func testBandLabel() {
        XCTAssertEqual(LiveSnapshotMapper.bandLabel("40m"), "40")
        XCTAssertEqual(LiveSnapshotMapper.bandLabel("bc_49m"), "49m")
        XCTAssertEqual(LiveSnapshotMapper.bandLabel(""), "")
    }

    func testSentinelsBecomeNil() {
        var e = EngineState.idle
        e.meters.snrDb = .nan
        e.telemetry.tempC = -49
        e.telemetry.supplyV = .nan
        e.telemetry.paCurrentA = .nan
        e.transmit.fwdPowerW = .nan
        e.transmit.swr = -1
        e.transmit.alcDb = .nan
        e.transmit.micLevelDb = .nan
        var s = map(e)
        XCTAssertNil(s.main.snrDb)
        XCTAssertNil(s.telemetry.temperatureC)
        XCTAssertNil(s.telemetry.supplyV)
        XCTAssertNil(s.telemetry.paCurrentA)
        XCTAssertNil(s.transmit.fwdPowerW)
        XCTAssertNil(s.transmit.swr)
        XCTAssertNil(s.transmit.alcDb)
        XCTAssertNil(s.transmit.micLevelDb)
        XCTAssertNil(s.telemetry.cpuPct)
        XCTAssertNil(s.telemetry.tciClients)
        XCTAssertNil(s.telemetry.graphics)
        e.telemetry.tempC = 31.4
        e.meters.snrDb = 24
        e.transmit.alcDb = -8
        e.transmit.micLevelDb = -14
        s = map(e)
        XCTAssertEqual(s.telemetry.temperatureC, 31.4)
        XCTAssertEqual(s.main.snrDb, 24)
        XCTAssertEqual(s.transmit.alcDb, -8)
        XCTAssertEqual(s.transmit.micLevelDb, -14)
    }

    func testTransmitFromEngineOnly() {
        var e = EngineState.idle
        XCTAssertEqual(map(e).transmit.state, .idle)
        e.transmit.moxActive = true
        XCTAssertEqual(map(e).transmit.state, .onAir)
        e.transmit.moxActive = false
        e.transmit.txDisplayActive = true
        XCTAssertEqual(map(e).transmit.state, .onAir)
        e.transmit.txDisplayActive = false
        e.transmit.txInhibit = true
        XCTAssertEqual(map(e).transmit.state, .blocked("TX inhibited"))
        e.transmit.driveRaw = 255
        XCTAssertEqual(map(e).transmit.drivePct, 100)
        e.transmit.driveRaw = 128
        XCTAssertEqual(map(e).transmit.drivePct, 50)
    }

    func testLiveOmitsSampleOverlays() {
        let s = map(.idle)
        XCTAssertTrue(s.display.bandPlan.isEmpty)
        XCTAssertTrue(s.display.spots.isEmpty)
        XCTAssertNil(s.session.recordingElapsed)
        XCTAssertNil(s.session.lastSpot)
    }

    func testQuickTogglesFromDsp() {
        var e = EngineState.idle
        e.dsp.nrEnabled = true
        e.dsp.nrMode = 2
        e.dsp.notchCount = 2
        e.frontEnd.lnaDb = 20
        let t = map(e).main.quickToggles
        let nr = t.first { $0.id == "NR" }
        XCTAssertEqual(nr?.label, "NR 2")
        XCTAssertEqual(nr?.isOn, true)
        XCTAssertEqual(t.first { $0.id == "NOTCH" }?.label, "NOTCH 2")
        XCTAssertEqual(t.first { $0.id == "LNA" }?.label, "LNA +20")
        XCTAssertEqual(t.map(\.id), ["ATT", "LNA", "AUTO", "NB", "NR", "ANF", "NOTCH", "SQ", "APF", "BIN"])
        XCTAssertEqual(map(e).dsp.toggles.map(\.id), DSPFunction.allCases.map(\.rawValue))
    }

    func testConnectionFields() {
        var e = EngineState.idle
        e.link.rigLabel = "Hermes Lite 2"
        e.link.firmware = "v74.2"
        e.link.targetIp = "10.0.0.5"
        e.link.savedIp = "10.0.0.9"
        var c = map(e).connection
        XCTAssertEqual(c.radioName, "Hermes Lite 2 v74.2")
        XCTAssertEqual(c.address, "10.0.0.9")
        XCTAssertEqual(c.protocolVersion, 1)
        e.link.running = true
        c = map(e).connection
        XCTAssertEqual(c.address, "10.0.0.5")
        e.link.p2Running = true
        XCTAssertEqual(map(e).connection.protocolVersion, 2)
        e.link.p2Running = false
        e.link.isP2Rig = true
        XCTAssertEqual(map(e).connection.protocolVersion, 2)
        e.link.firmware = nil
        XCTAssertEqual(map(e).connection.radioName, "Hermes Lite 2")
    }
}

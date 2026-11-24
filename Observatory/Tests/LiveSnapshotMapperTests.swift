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
        e.display.spanHz = 96_000
        var s = map(e)
        XCTAssertEqual(s.display.spanLowHz, 7_052_120)
        XCTAssertEqual(s.display.spanHighHz, 7_148_120)
        e.radio.ctuneEnabled = true
        e.radio.ctuneCenterHz = 7_120_000
        s = map(e)
        XCTAssertEqual(s.display.spanLowHz, 7_072_000)
        XCTAssertTrue(s.session.ctunEnabled)
        e.radio.rx2Hz = 14_200_000
        e.display.iqRateHz = 192_000
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

    // MARK: - Readings need a streaming radio (final review, Important 1 and 2)

    /// Every live reading set to a plausible value, so a nil proves the mapper dropped it.
    private func reportingState() -> EngineState {
        var e = EngineState.idle
        e.meters.sMeterDbm = -90
        e.meters.sMeterDbmRx2 = -100
        e.meters.snrDb = 20
        e.telemetry.tempC = 31.4
        e.telemetry.supplyV = 13.8
        e.telemetry.paCurrentA = 0.5
        e.transmit.fwdPowerW = 5
        e.transmit.swr = 1.2
        e.transmit.alcDb = -10
        e.transmit.micLevelDb = -20
        e.transmit.psArmed = true
        e.transmit.psFeedback = 150
        e.frontEnd.adcOverload = true
        return e
    }

    func testReadingsPresentWhileStreaming() {
        let s = map(reportingState(), phase: .streaming)
        XCTAssertEqual(s.main.signalDbm, -90)
        XCTAssertEqual(s.sub.signalDbm, -100)
        XCTAssertEqual(s.main.snrDb, 20)
        XCTAssertEqual(s.telemetry.temperatureC, 31.4)
        XCTAssertEqual(s.telemetry.supplyV, 13.8)
        XCTAssertEqual(s.telemetry.paCurrentA, 0.5)
        XCTAssertEqual(s.transmit.fwdPowerW, 5)
        XCTAssertEqual(s.transmit.swr, 1.2)
        XCTAssertEqual(s.transmit.alcDb, -10)
        XCTAssertEqual(s.transmit.micLevelDb, -20)
        XCTAssertEqual(s.transmit.psFeedback, 150)
        XCTAssertEqual(s.frontEnd.overload, true)
    }

    /// Before the first frame, after a disconnect and during a stall the engine still holds
    /// values (the -140 floor, PA current 0, the last telemetry). None of them may show.
    func testReadingsAbsentUnlessStreaming() {
        let phases: [ConnectionPhase] = [.disconnected, .discovering, .connecting, .socketOpen,
                                         .stalled, .error("Connection closed")]
        for phase in phases {
            let s = map(reportingState(), phase: phase)
            XCTAssertNil(s.main.signalDbm, "\(phase)")
            XCTAssertNil(s.sub.signalDbm, "\(phase)")
            XCTAssertNil(s.main.snrDb, "\(phase)")
            XCTAssertNil(s.telemetry.temperatureC, "\(phase)")
            XCTAssertNil(s.telemetry.supplyV, "\(phase)")
            XCTAssertNil(s.telemetry.paCurrentA, "\(phase)")
            XCTAssertNil(s.transmit.fwdPowerW, "\(phase)")
            XCTAssertNil(s.transmit.swr, "\(phase)")
            XCTAssertNil(s.transmit.alcDb, "\(phase)")
            XCTAssertNil(s.transmit.micLevelDb, "\(phase)")
            XCTAssertNil(s.transmit.psFeedback, "\(phase)")
            XCTAssertNil(s.frontEnd.overload, "\(phase)")
        }
    }

    func testPaCurrentZeroBeforeFirstFrameIsNotShown() {
        var e = EngineState.idle
        e.telemetry.paCurrentA = 0
        e.telemetry.tempC = -50
        let s = map(e, phase: .disconnected)
        XCTAssertNil(s.telemetry.paCurrentA)
        XCTAssertNil(s.telemetry.temperatureC)
    }

    func testSMeterFloorsBecomeNil() {
        var e = EngineState.idle
        for floor in [-140.0, -200.0, -.infinity, .nan] {
            e.meters.sMeterDbm = floor
            e.meters.sMeterDbmRx2 = floor
            let s = map(e)
            XCTAssertNil(s.main.signalDbm, "\(floor)")
            XCTAssertNil(s.sub.signalDbm, "\(floor)")
        }
        e.meters.sMeterDbm = -139.5
        XCTAssertEqual(map(e).main.signalDbm, -139.5)
    }

    /// The engine reports NaN for the AGC gain whenever WDSP is not running. The mapper must
    /// neither trap on it nor turn it into a number, whatever the facade passes through.
    func testAgcLevelsNaNBecomeNilWithoutTrapping() {
        var e = EngineState.idle
        e.dsp.agcMaxGainDb = .nan
        e.dsp.agcThreshDb = .nan
        e.dsp.nbStrength = .nan
        for phase: ConnectionPhase in [.streaming, .disconnected] {
            let d = map(e, phase: phase).dsp
            XCTAssertNil(d.agcGainDb)
            XCTAssertNil(d.agcThresholdDbfs)
            XCTAssertNil(d.nbLevel)
        }
        e.dsp.agcMaxGainDb = .infinity
        e.dsp.agcThreshDb = -.infinity
        XCTAssertNil(map(e).dsp.agcGainDb)
        XCTAssertNil(map(e).dsp.agcThresholdDbfs)
    }

    func testAgcLevelsReported() {
        var e = EngineState.idle
        e.dsp.agcMaxGainDb = 88.4
        e.dsp.agcThreshDb = -92.2
        e.dsp.nbStrength = 0.3
        let d = map(e).dsp
        XCTAssertEqual(d.agcGainDb, 88)
        XCTAssertEqual(d.agcThresholdDbfs, -92)
        XCTAssertEqual(d.nbLevel, 30)
    }

    func testIdleEngineReportsNoAgcGain() {
        XCTAssertNil(map(.idle).dsp.agcGainDb)
    }

    // MARK: - Band highlight follows the focused receiver (final review, Minor 1)

    func testSelectedBandFollowsFocusedReceiver() {
        var e = EngineState.idle
        e.bands = [
            EngineBand(name: "40m", lowHz: 7_000_000, highHz: 7_300_000, defaultHz: 7_074_000),
            EngineBand(name: "20m", lowHz: 14_000_000, highHz: 14_350_000, defaultHz: 14_074_000),
        ]
        e.radio.rx1Hz = 7_100_000
        e.radio.rx2Hz = 14_200_000
        e.radio.subEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(map(e).band.selectedBand, "20")
        e.radio.focusedRx = 1
        XCTAssertEqual(map(e).band.selectedBand, "40")
        // Focus 2 without Sub shows Main focused, so the highlight is Main's band.
        e.radio.focusedRx = 2
        e.radio.subEnabled = false
        XCTAssertEqual(map(e).band.selectedBand, "40")
    }

    /// The chip uses the carrier the panel title uses: near a band edge in CW the marker
    /// offset decides the band.
    func testSelectedBandUsesTheCarrier() {
        var e = EngineState.idle
        e.bands = [EngineBand(name: "40m", lowHz: 7_000_000, highHz: 7_300_000, defaultHz: 7_074_000)]
        e.radio.rx1Hz = 6_999_500
        e.radio.markerOffsetHz = 600
        let s = map(e)
        XCTAssertEqual(s.main.bandName, "40")
        XCTAssertEqual(s.band.selectedBand, "40")
    }

    // MARK: - Display geometry

    func testSubOverlayOnMainWithoutRx2Spectrum() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_100_000; e.radio.rx2Hz = 7_110_000; e.radio.markerOffsetHzRx2 = 700
        e.radio.subEnabled = true
        e.display.spanHz = 96_000
        e.display.passbandLowHzRx2 = 450; e.display.passbandHighHzRx2 = 950
        let d = map(e).display
        let sub = try! XCTUnwrap(d.subOverlay)
        XCTAssertEqual(sub.carrierHz, 7_110_700)
        XCTAssertEqual(sub.passband, 7_110_450...7_110_950)
        XCTAssertNil(sub.offSpan)
        XCTAssertFalse(d.showsSubStack(subEnabled: true))
    }

    func testSubStackOnlyWithLiveSubSpectrum() {
        var e = EngineState.idle
        e.radio.subEnabled = true; e.display.spanHz = 96_000; e.display.rx2SpectrumAvailable = true
        let d = map(e).display
        XCTAssertNil(d.subOverlay)
        XCTAssertTrue(d.showsSubStack(subEnabled: true))
        XCTAssertFalse(d.showsSubStack(subEnabled: false))
    }

    func testSubOffSpanCue() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_100_000; e.radio.rx2Hz = 7_000_000
        e.radio.subEnabled = true; e.display.spanHz = 96_000
        XCTAssertEqual(map(e).display.subOverlay?.offSpan, .left)
        e.radio.rx2Hz = 7_200_000
        XCTAssertEqual(map(e).display.subOverlay?.offSpan, .right)
        e.radio.rx2Hz = 7_110_000
        XCTAssertNil(map(e).display.subOverlay?.offSpan)
        XCTAssertNotNil(map(e).display.subOverlay)
    }

    func testAxisFollowsEngineSpanInTx() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_100_000; e.display.spanHz = 96_000; e.display.txOwnsAnalyzer = true
        let d = map(e).display
        XCTAssertEqual(d.spanHighHz - d.spanLowHz, 96_000)
        XCTAssertTrue(d.txAxis)
    }

    /// During TX the span is the TX analyzer's 96 kHz, not iqRate / zoom: show the RX zoom pref
    /// (final review, M3).
    func testZoomIsThePreferenceWhileTxOwnsTheAnalyzer() {
        var e = EngineState.idle
        e.display.iqRateHz = 192_000; e.display.spanHz = 48_000; e.display.zoom = 4
        XCTAssertEqual(map(e).display.zoom, 4)
        e.display.spanHz = 96_000; e.display.txOwnsAnalyzer = true
        XCTAssertEqual(map(e).display.zoom, 4)
    }

    func testDbRangesComeFromPrefs() {
        var e = EngineState.idle
        e.display.dbMin = -110; e.display.dbMax = -10; e.display.dbAuto = true
        e.display.waterfallDbMin = -100; e.display.waterfallDbMax = -30; e.display.waterfallDbAuto = true
        let d = map(e).display
        XCTAssertEqual(d.dbRange, DbRange(floor: -110, ceiling: -10, auto: true))
        XCTAssertEqual(d.waterfallRange, DbRange(floor: -100, ceiling: -30, auto: true))
    }

    func testPeakHoldSettingFromPrefs() {
        var e = EngineState.idle
        func peak(_ on: Bool, _ secs: Double) -> PeakHoldSetting {
            e.display.peakEnabled = on; e.display.peakHoldSecs = secs
            return map(e).display.peakHold
        }
        XCTAssertEqual(peak(false, 5), .off)
        XCTAssertEqual(peak(true, -1), .hold)
        XCTAssertEqual(peak(true, -2), .live)
        XCTAssertEqual(peak(true, 2), .seconds(2))
    }

    func testNoAnalyzerHidesOverlays() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_030_000; e.radio.markerOffsetHz = 700
        e.radio.rx2Hz = 14_200_000; e.radio.subEnabled = true
        let d = map(e).display   // spanHz is 0
        XCTAssertNil(d.subOverlay)
        XCTAssertEqual(d.mainCarrierHz, 7_030_700)
        XCTAssertEqual(d.mainPassband, 7_030_700...7_030_700)
    }

    func testCtunPassbandAndCarrier() {
        var e = EngineState.idle
        e.radio.rx1Hz = 7_030_000; e.radio.ctuneEnabled = true; e.radio.ctuneCenterHz = 7_028_000
        e.radio.markerOffsetHz = 700
        e.display.spanHz = 96_000; e.display.passbandLowHz = 450; e.display.passbandHighHz = 950
        let d = map(e).display
        XCTAssertEqual(d.mainCarrierHz, 7_030_700)
        XCTAssertEqual(d.mainPassband, 7_030_450...7_030_950)
    }

    func testPassbandWithNonFiniteEdgesDoesNotTrap() {
        var e = EngineState.idle
        e.display.spanHz = 96_000; e.display.passbandLowHz = .nan; e.display.passbandHighHz = .infinity
        _ = map(e)
    }

    func testWaterfallColorsAndAveraging() {
        var e = EngineState.idle
        XCTAssertEqual(map(e).display.waterfallColors, .custom(baseRGB: 0x30B0FF))
        XCTAssertFalse(map(e).display.averaging)
        e.display.waterfallLut = [UInt8](repeating: 7, count: 768); e.display.smoothing = 4
        XCTAssertEqual(map(e).display.waterfallColors, .lut([UInt8](repeating: 7, count: 768)))
        XCTAssertTrue(map(e).display.averaging)
    }
}

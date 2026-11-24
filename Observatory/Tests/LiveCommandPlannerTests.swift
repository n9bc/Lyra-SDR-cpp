import XCTest
@testable import Observatory

final class LiveCommandPlannerTests: XCTestCase {
    private func plan(_ c: RadioCommand, _ e: EngineState, locked: Bool = false) -> [EngineCall] {
        LiveCommandPlanner.calls(for: c, state: e, vfoLocked: locked)
    }

    private func state(rx1: UInt32 = 7_100_000, rx2: UInt32 = 14_200_000, vfoB: UInt32 = 7_105_000,
                       sub: Bool = false, split: Bool = false) -> EngineState {
        var e = EngineState.idle
        e.radio.rx1Hz = rx1
        e.radio.rx2Hz = rx2
        e.radio.vfoBHz = vfoB
        e.radio.subEnabled = sub
        e.radio.splitEnabled = split
        e.filter.mode = "USB"
        e.filter.modeRx2 = "CWU"
        e.filter.rxBandwidth = 2700
        e.filter.rx2Bandwidth = 500
        return e
    }

    func testTuneMain() {
        let e = state()
        XCTAssertEqual(plan(.tune(.main, deltaHz: 1000), e), [.setRx1Hz(7_101_000)])
        XCTAssertEqual(plan(.tune(.main, deltaHz: -8_000_000), e), [.setRx1Hz(0)])
    }

    func testTuneSubWithSplitMovesVfoB() {
        let e = state(sub: true, split: true)
        XCTAssertEqual(plan(.tune(.sub, deltaHz: 500), e), [.setVfoBHz(7_105_500)])
    }

    func testTuneSubOnNoSplit() {
        XCTAssertEqual(plan(.tune(.sub, deltaHz: -1000), state(sub: true)), [.setRx2Hz(14_199_000)])
    }

    func testTuneSubOffNoSplit() {
        XCTAssertEqual(plan(.tune(.sub, deltaHz: 1000), state()), [])
    }

    func testTuneSubWithSplitAndSubOffStillMovesVfoB() {
        XCTAssertEqual(plan(.tune(.sub, deltaHz: 1000), state(split: true)), [.setVfoBHz(7_106_000)])
    }

    func testLockedRefusesMoves() {
        var e = state(sub: true)
        e.bands = [EngineBand(name: "40m", lowHz: 7_000_000, highHz: 7_300_000, defaultHz: 7_074_000)]
        for c: RadioCommand in [.tune(.main, deltaHz: 1), .selectBand("40"), .copyAToB, .copyBToA, .swapAB] {
            XCTAssertEqual(plan(c, e, locked: true), [], "\(c)")
        }
        XCTAssertEqual(plan(.setVFOLock(true), e), [])
    }

    func testFocus() {
        XCTAssertEqual(plan(.focus(.sub), state()), [])
        XCTAssertEqual(plan(.focus(.sub), state(sub: true)), [.setFocusedRx(2)])
        XCTAssertEqual(plan(.focus(.main), state()), [.setFocusedRx(1)])
    }

    func testSplitOnSeedsVfoB() {
        var e = state(vfoB: 0)
        e.radio.splitShiftHz = 1000
        XCTAssertEqual(plan(.setSplit(true), e), [.setVfoBHz(7_101_000), .setSplitEnabled(true)])
        e.radio.markerOffsetHz = 600
        XCTAssertEqual(plan(.setSplit(true), e), [.setVfoBHz(7_101_600), .setSplitEnabled(true)])
        e.radio.vfoBHz = 7_105_000
        XCTAssertEqual(plan(.setSplit(true), e), [.setSplitEnabled(true)])
    }

    func testSplitOffResetsStrandedFocus() {
        var e = state(split: true)
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.setSplit(false), e), [.setSplitEnabled(false), .setFocusedRx(1)])
        e.radio.subEnabled = true
        XCTAssertEqual(plan(.setSplit(false), e), [.setSplitEnabled(false)])
        e.radio.subEnabled = false
        e.radio.focusedRx = 1
        XCTAssertEqual(plan(.setSplit(false), e), [.setSplitEnabled(false)])
    }

    func testCopyAToB() {
        XCTAssertEqual(plan(.copyAToB, state(split: true)), [
            .requireJumpAllowed(fromHz: 7_105_000, toHz: 7_100_000), .setRptActive(false),
            .setVfoBHz(7_100_000)])
        XCTAssertEqual(plan(.copyAToB, state(sub: true)), [
            .requireJumpAllowed(fromHz: 14_200_000, toHz: 7_100_000), .setRx2Hz(7_100_000),
            .setModeRx2("USB"), .setRx2Bandwidth(2700)])
        XCTAssertEqual(plan(.copyAToB, state()), [.setVfoBHz(7_100_000)])
    }

    func testCopyBToA() {
        XCTAssertEqual(plan(.copyBToA, state(split: true)), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000), .setRptActive(false),
            .setRx1Hz(7_105_000)])
        XCTAssertEqual(plan(.copyBToA, state(sub: true)), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 14_200_000), .setRx1Hz(14_200_000),
            .setMode("CWU"), .setRxBandwidth(500)])
        XCTAssertEqual(plan(.copyBToA, state()), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000), .setRx1Hz(7_105_000)])
    }

    func testSwapAB() {
        XCTAssertEqual(plan(.swapAB, state(split: true)), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000),
            .requireJumpAllowed(fromHz: 7_105_000, toHz: 7_100_000),
            .setRptActive(false), .setVfoBHz(7_100_000), .setRx1Hz(7_105_000)])
        XCTAssertEqual(plan(.swapAB, state(sub: true)), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 14_200_000),
            .requireJumpAllowed(fromHz: 14_200_000, toHz: 7_100_000),
            .setRx2Hz(7_100_000), .setRx1Hz(14_200_000),
            .setMode("CWU"), .setModeRx2("USB"), .setRxBandwidth(500), .setRx2Bandwidth(2700)])
        XCTAssertEqual(plan(.swapAB, state()), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000),
            .setVfoBHz(7_100_000), .setRx1Hz(7_105_000)])
    }

    func testJumpGuardsUseDialFrequenciesNotMarkerCarrier() {
        var e = state(sub: true)
        e.radio.markerOffsetHzRx2 = 600
        XCTAssertEqual(plan(.copyAToB, e).first,
                       .requireJumpAllowed(fromHz: 14_200_000, toHz: 7_100_000))
        XCTAssertEqual(plan(.swapAB, e)[1],
                       .requireJumpAllowed(fromHz: 14_200_000, toHz: 7_100_000))
    }

    func testSplitWinsOverSubForTargetButModesStillCopy() {
        let e = state(sub: true, split: true)
        XCTAssertEqual(plan(.copyAToB, e), [
            .requireJumpAllowed(fromHz: 7_105_000, toHz: 7_100_000), .setRptActive(false),
            .setVfoBHz(7_100_000), .setModeRx2("USB"), .setRx2Bandwidth(2700)])
        XCTAssertEqual(plan(.copyBToA, e), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000), .setRptActive(false),
            .setRx1Hz(7_105_000), .setMode("CWU"), .setRxBandwidth(500)])
        XCTAssertEqual(plan(.swapAB, e), [
            .requireJumpAllowed(fromHz: 7_100_000, toHz: 7_105_000),
            .requireJumpAllowed(fromHz: 7_105_000, toHz: 7_100_000),
            .setRptActive(false), .setVfoBHz(7_100_000), .setRx1Hz(7_105_000),
            .setMode("CWU"), .setModeRx2("USB"), .setRxBandwidth(500), .setRx2Bandwidth(2700)])
    }

    func testCopyAbortsWhenJumpBlocked() {
        for c: RadioCommand in [.copyAToB, .copyBToA, .swapAB] {
            guard case .requireJumpAllowed = plan(c, state(sub: true)).first else {
                return XCTFail("\(c) must begin with a jump guard")
            }
        }
    }

    func testRitXitCtun() {
        XCTAssertEqual(plan(.setRIT(true), state()), [.setRitEnabled(true)])
        XCTAssertEqual(plan(.setXIT(false), state()), [.setXitEnabled(false)])
        XCTAssertEqual(plan(.setCTUN(true), state()), [.setCtuneEnabled(true)])
    }

    func testModeAndFilter() {
        XCTAssertEqual(plan(.setMode(.main, .cwu), state()), [.setMode("CWU")])
        XCTAssertEqual(plan(.setMode(.sub, .lsb), state()), [.setModeRx2("LSB")])
        XCTAssertEqual(plan(.setFilter(.main, hz: 1800), state()), [.setRxBandwidth(1800)])
        XCTAssertEqual(plan(.setFilter(.sub, hz: 2400), state()), [.setRx2Bandwidth(2400)])
        XCTAssertEqual(plan(.setBandwidthLock(true), state()), [.setBwLocked(true)])
    }

    private func bandState() -> EngineState {
        var e = state()
        e.bands = [EngineBand(name: "40m", lowHz: 7_000_000, highHz: 7_300_000, defaultHz: 7_074_000)]
        return e
    }

    func testBandClickUnderTXOnlyUnkeys() {
        var e = bandState()
        e.transmit.txDisplayActive = true
        XCTAssertEqual(plan(.selectBand("40"), e), [.stopTxForBlockedJump])
    }

    func testBandRecall() {
        var e = bandState()
        XCTAssertEqual(plan(.selectBand("40"), e),
                       [.recallBand(name: "40m", defaultHz: 7_074_000, rx2: false)])
        e.radio.subEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.selectBand("40"), e),
                       [.recallBand(name: "40m", defaultHz: 7_074_000, rx2: true)])
        XCTAssertEqual(plan(.selectBand("99"), e), [])
    }

    /// Focus on VFO B under split without Sub: the console shows Main focused, so a band click
    /// acts on Main and brings the engine's focus back to RX1 to match.
    func testBandWithFocusOnVfoBUnderSplitActsOnMain() {
        var e = bandState()
        e.radio.splitEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.selectBand("40"), e),
                       [.setFocusedRx(1), .recallBand(name: "40m", defaultHz: 7_074_000, rx2: false)])
    }

    /// Applies the calls these console steps produce, as the engine does. `setSubEnabled(false)`
    /// keeps VFO-B focus under split (`HL2Stream::setSubEnabled`).
    private func apply(_ calls: [EngineCall], to e: inout EngineState) {
        for call in calls {
            switch call {
            case .setSubEnabled(let on):
                e.radio.subEnabled = on
                if !on && !e.radio.splitEnabled { e.radio.focusedRx = 1 }
            case .setFocusedRx(let rx): e.radio.focusedRx = rx
            case .setSplitEnabled(let on): e.radio.splitEnabled = on
            case .setVfoBHz(let hz): e.radio.vfoBHz = hz
            default: break
            }
        }
    }

    /// Final review, Important 3: SUB RX on, focus Sub, SPLIT on, SUB RX off. The console then
    /// shows Main focused; band clicks and arrows must act on Main, not be refused.
    func testBandClickAfterSubOffUnderSplitActsOnMain() {
        var e = bandState()
        for command: RadioCommand in [.setSubEnabled(true), .focus(.sub), .setSplit(true),
                                      .setSubEnabled(false)] {
            apply(plan(command, e), to: &e)
        }
        XCTAssertEqual(e.radio.focusedRx, 2)
        XCTAssertTrue(e.radio.splitEnabled)
        XCTAssertFalse(e.radio.subEnabled)
        let shown = LiveSnapshotMapper.snapshot(from: e, phase: .streaming, vfoLocked: false,
                                                now: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        XCTAssertEqual(shown.session.focused, .main)

        XCTAssertEqual(plan(.selectBand("40"), e),
                       [.setFocusedRx(1), .recallBand(name: "40m", defaultHz: 7_074_000, rx2: false)])
        XCTAssertEqual(plan(.tune(shown.session.focused, deltaHz: 1000), e), [.setRx1Hz(7_101_000)])
    }

    func testAgcAndDsp() {
        var e = state()
        XCTAssertEqual(plan(.setAGC(.med), e), [.setAgcMode("med")])
        XCTAssertEqual(plan(.setDSP(.snb, true), e), [])
        XCTAssertEqual(plan(.setDSP(.nnr, true), e), [])
        e.dsp.nnrAvailable = true
        XCTAssertEqual(plan(.setDSP(.nnr, true), e), [.setDsp(.nnr, true)])
        XCTAssertEqual(plan(.setDSP(.nb, true), e), [.setDsp(.nb, true)])
    }

    func testConnect() {
        XCTAssertEqual(plan(.connect, state()), [.connect])
        XCTAssertEqual(plan(.disconnect, state()), [.disconnect])
    }

    // MARK: - Spectrum gestures

    private func cw() -> EngineState {
        var e = state(rx1: 7_030_000)
        e.filter.mode = "CWU"
        e.radio.markerOffsetHz = 700
        e.radio.markerOffsetHzRx2 = -600
        return e
    }

    func testClickSubtractsMarkerAndRit() {
        var e = cw()
        e.radio.ritEnabled = true
        e.radio.ritHz = 200
        XCTAssertEqual(plan(.tuneCarrier(.main, hz: 7_030_700), e), [.setRx1Hz(7_029_800)])
        e.radio.ritEnabled = false
        XCTAssertEqual(plan(.tuneCarrier(.main, hz: 7_030_700), e), [.setRx1Hz(7_030_000)])
        XCTAssertEqual(plan(.tuneCarrier(.main, hz: -5), e), [.setRx1Hz(0)])
        XCTAssertEqual(plan(.tuneCarrier(.main, hz: 9_000_000_000), e), [.setRx1Hz(UInt32.max)])
    }

    func testSplitTuneOnSubMovesVfoB() {
        var e = cw()
        e.radio.splitEnabled = true
        XCTAssertEqual(plan(.tuneCarrier(.sub, hz: 7_040_000), e), [.setVfoBHz(7_040_000)])
        e.radio.splitEnabled = false
        e.radio.subEnabled = true
        XCTAssertEqual(plan(.tuneCarrier(.sub, hz: 7_040_000), e), [.setRx2Hz(7_040_600)])
        e.radio.subEnabled = false
        XCTAssertEqual(plan(.tuneCarrier(.sub, hz: 7_040_000), e), [])
    }

    func testGesturesObeyVfoLock() {
        XCTAssertEqual(plan(.tuneCarrier(.main, hz: 7_030_700), cw(), locked: true), [])
        XCTAssertEqual(plan(.wheelTune(.main, ticks: 1), cw(), locked: true), [])
        XCTAssertEqual(plan(.grabVfo(deltaHz: 100), cw(), locked: true), [])
    }

    func testWheelTuneSticky() {
        var e = cw()                       // carrier 7_030_700, step 1000 sticky
        XCTAssertEqual(plan(.wheelTune(.main, ticks: 1), e), [.setRx1Hz(7_030_300)])   // carrier 7_031_000
        XCTAssertEqual(plan(.wheelTune(.main, ticks: -1), e), [.setRx1Hz(7_029_300)])
        e.display.stickyWheel = false
        XCTAssertEqual(plan(.wheelTune(.main, ticks: 2), e), [.setRx1Hz(7_032_000)])
        e.display.stickyWheel = true
        e.display.round100 = true
        e.display.scrollStepHz = 10                     // round100 raises the step to 100
        XCTAssertEqual(plan(.wheelTune(.main, ticks: 1), e), [.setRx1Hz(7_030_100)])
    }

    func testWheelTuneSub() {
        var e = cw()
        e.radio.subEnabled = true
        e.radio.rx2Hz = 14_200_000                      // carrier 14_199_400
        XCTAssertEqual(plan(.wheelTune(.sub, ticks: 1), e), [.setRx2Hz(14_200_600)])
        e.radio.splitEnabled = true
        e.radio.vfoBHz = 7_105_200
        XCTAssertEqual(plan(.wheelTune(.sub, ticks: 1), e), [.setVfoBHz(7_106_000)])
    }

    func testCtunPanAndGrab() {
        var e = cw()
        e.radio.ctuneEnabled = true
        e.radio.ctuneCenterHz = 7_030_000
        XCTAssertEqual(plan(.ctunPan(deltaHz: 9_600), e), [.setCtuneCenterHz(7_020_400)])
        XCTAssertEqual(plan(.ctunPan(deltaHz: 9_000_000), e), [.setCtuneCenterHz(0)])
        XCTAssertEqual(plan(.grabVfo(deltaHz: -500), e), [.setRx1Hz(7_029_500)])
        XCTAssertEqual(plan(.grabVfo(deltaHz: -9_000_000), e), [.setRx1Hz(0)])
        XCTAssertEqual(plan(.ctunPan(deltaHz: 9_600), e, locked: true), [.setCtuneCenterHz(7_020_400)])
    }

    func testSpectrumFocusToggle() {
        var e = cw()
        e.radio.subEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.spectrumFocusToggle(hz: 7_040_000), e), [.setFocusedRx(1)])
        e.radio.focusedRx = 1
        XCTAssertEqual(plan(.spectrumFocusToggle(hz: 7_040_000), e),
                       [.setVfoBHz(7_040_000), .setRx2Hz(7_040_600), .setFocusedRx(2)])
        e.radio.subEnabled = false
        XCTAssertEqual(plan(.spectrumFocusToggle(hz: 7_040_000), e),
                       [.setVfoBHz(7_040_000), .setFocusedRx(2)])
        // Sub off, split on, focus 2: the wheel/click receiver is Sub, so the toggle returns to Main.
        e.radio.splitEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.spectrumFocusToggle(hz: 7_040_000), e), [.setFocusedRx(1)])
    }

    func testZoomClamped() {
        XCTAssertEqual(plan(.setZoom(40), cw()), [.setZoomPref(16)])
        XCTAssertEqual(plan(.setZoom(0.5), cw()), [.setZoomPref(1)])
        XCTAssertEqual(plan(.setZoom(2.5), cw()), [.setZoomPref(2.5)])
    }

    // MARK: - Display toolbar settings

    func testPeakOptionsMapToPrefs() {
        let e = EngineState.idle
        XCTAssertEqual(plan(.setPeakHold(.off), e), [.setPeakPref(enabled: false, secs: 0)])
        XCTAssertEqual(plan(.setPeakHold(.hold), e), [.setPeakPref(enabled: true, secs: -1)])
        XCTAssertEqual(plan(.setPeakHold(.live), e), [.setPeakPref(enabled: true, secs: -2)])
        for secs in [0.5, 2, 5] {
            XCTAssertEqual(plan(.setPeakHold(.seconds(secs)), e), [.setPeakPref(enabled: true, secs: secs)])
        }
    }

    func testAveragingRestoresLastSmoothing() {
        let e = EngineState.idle
        XCTAssertEqual(LiveCommandPlanner.calls(for: .setAveraging(false), state: e, vfoLocked: false,
                                                lastSmoothing: 7), [.setSmoothingPref(0)])
        XCTAssertEqual(LiveCommandPlanner.calls(for: .setAveraging(true), state: e, vfoLocked: false,
                                                lastSmoothing: 7), [.setSmoothingPref(7)])
    }

    func testAveragingDefaultsToFive() {
        XCTAssertEqual(plan(.setAveraging(true), .idle), [.setSmoothingPref(5)])
    }

    func testWheelStepAndExact() {
        XCTAssertEqual(plan(.setWheelStep(500), .idle), [.setScrollStepPref(500)])
        XCTAssertEqual(plan(.setExactTuning(true), .idle), [.setRound100Pref(true)])
        XCTAssertEqual(plan(.setExactTuning(false), .idle), [.setRound100Pref(false)])
    }

    func testBandPlanAndSpotsToggles() {
        XCTAssertEqual(plan(.setBandPlanVisible(false), .idle), [.setBandPlanSegmentsPref(false)])
        XCTAssertEqual(plan(.setSpotsVisible(true), .idle), [.setShowSpotsPref(true)])
    }

    func testStepChipTargetsItsReceiver() {
        XCTAssertEqual(plan(.setTuningStep(.main, 50), .idle), [.setStepPref(.main, 50)])
        XCTAssertEqual(plan(.setTuningStep(.sub, 5000), .idle), [.setStepPref(.sub, 5000)])
    }
}

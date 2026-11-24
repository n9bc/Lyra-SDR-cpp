import XCTest
import Observation
@testable import Observatory

/// `onChange` is `@Sendable`, so the test records the notification in a locked box.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class MockRadioBackendTests: XCTestCase {
    func testSampleMatchesMockup() {
        let s = MockRadioBackend().snapshot
        XCTAssertEqual(s.main.frequencyHz, 7_128_500)
        XCTAssertEqual(s.main.mode, .lsb)
        XCTAssertFalse(s.sub.enabled)
        XCTAssertEqual(s.transmit.state, .idle)
        XCTAssertNil(s.telemetry.supplyV)
        XCTAssertEqual(s.display.spots.count, 7)
        XCTAssertEqual(s.band.selectedBand, "40")
    }

    func testMockIsMarkedSampleData() {
        let caps = MockRadioBackend().capabilities
        XCTAssertTrue(caps.isSampleData)
        for f in BackendFeature.allCases { XCTAssertEqual(caps.status(f), .mocked) }
    }

    func testBandPlanCoversSpanContiguously() {
        let d = RadioSnapshot.sample.display
        XCTAssertEqual(d.bandPlan.first?.lowHz, d.spanLowHz)
        XCTAssertEqual(d.bandPlan.last?.highHz, d.spanHighHz)
        for (a, b) in zip(d.bandPlan, d.bandPlan.dropFirst()) { XCTAssertEqual(a.highHz, b.lowHz) }
    }

    func testFocusSubRefusedWhileSubOff() {
        XCTAssertEqual(MockRadioBackend.applying(.focus(.sub), to: .sample).session.focused, .main)
    }
    func testSubOnThenFocusSub() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.focus(.sub), to: s)
        XCTAssertTrue(s.sub.enabled); XCTAssertEqual(s.session.focused, .sub); XCTAssertEqual(s.focusedReceiver.id, .sub)
    }
    func testSubOffReturnsFocusToMain() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.focus(.sub), to: s)
        s = MockRadioBackend.applying(.setSubEnabled(false), to: s)
        XCTAssertFalse(s.sub.enabled); XCTAssertEqual(s.session.focused, .main)
    }
    func testTuneMovesOnlyThatReceiver() {
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: 1_000), to: .sample)
        XCTAssertEqual(s.main.frequencyHz, 7_129_500); XCTAssertEqual(s.sub.frequencyHz, 14_195_000)
        XCTAssertEqual(s.display.spanLowHz, 7_060_000); XCTAssertEqual(s.display.spanHighHz, 7_200_000)
    }
    func testTuneDisabledReceiverIgnored() {
        XCTAssertEqual(MockRadioBackend.applying(.tune(.sub, deltaHz: 1_000), to: .sample), .sample)
    }
    func testTuneOutsideSpanRecentres() {
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: 100_000), to: .sample)
        XCTAssertEqual(s.main.frequencyHz, 7_228_500)
        XCTAssertEqual(s.display.spanLowHz, 7_158_500); XCTAssertEqual(s.display.spanHighHz, 7_298_500)
    }
    func testTuneNeverNegative() {
        var start = RadioSnapshot.sample; start.main.frequencyHz = 500
        let s = MockRadioBackend.applying(.tune(.main, deltaHz: -1_000), to: start)
        XCTAssertEqual(s.main.frequencyHz, 0); XCTAssertEqual(s.display.spanLowHz, 0); XCTAssertEqual(s.display.spanHighHz, 140_000)
    }
    func testSubTuneMovesSubSpan() {
        var s = MockRadioBackend.applying(.setSubEnabled(true), to: .sample)
        s = MockRadioBackend.applying(.tune(.sub, deltaHz: 200_000), to: s)
        XCTAssertEqual(s.sub.frequencyHz, 14_395_000)
        XCTAssertEqual(s.display.subSpanLowHz, 14_325_000); XCTAssertEqual(s.display.spanLowHz, 7_060_000)
    }
    func testSubViewHasSubSpanAndNoFortyMetreOverlays() {
        let v = RadioSnapshot.sample.display.view(for: .sub)
        XCTAssertEqual(v.spanLowHz, 14_125_000); XCTAssertEqual(v.spanHighHz, 14_265_000)
        XCTAssertTrue(v.bandPlan.isEmpty); XCTAssertTrue(v.spots.isEmpty)
        XCTAssertEqual(RadioSnapshot.sample.display.view(for: .main), RadioSnapshot.sample.display)
    }
    func testSendNotifiesObservers() {
        let backend = MockRadioBackend()
        let fired = Flag()
        withObservationTracking { _ = backend.snapshot } onChange: { fired.set() }
        backend.send(.setSubEnabled(true))
        XCTAssertTrue(fired.isSet); XCTAssertTrue(backend.snapshot.sub.enabled)
    }
}

@MainActor final class MockReceiverCommandTests: XCTestCase {
    private func apply(_ c: RadioCommand, _ s: RadioSnapshot = .sample) -> RadioSnapshot {
        MockRadioBackend.applying(c, to: s)
    }
    private func subOn() -> RadioSnapshot { apply(.setSubEnabled(true)) }

    func testConnectAndDisconnect() {
        XCTAssertEqual(apply(.disconnect).connection.phase, .disconnected)
        XCTAssertEqual(apply(.connect, apply(.disconnect)).connection.phase, .streaming)
    }
    func testSplitOnPutsTransmitOnSub() {
        let s = apply(.setSplit(true))
        XCTAssertTrue(s.main.splitTx); XCTAssertTrue(s.sub.splitTx)
        XCTAssertFalse(s.main.isTxVFO); XCTAssertTrue(s.sub.isTxVFO)
    }
    func testSplitOffReturnsTransmitToMain() {
        let s = apply(.setSplit(false), apply(.setSplit(true)))
        XCTAssertFalse(s.main.splitTx); XCTAssertFalse(s.sub.splitTx)
        XCTAssertTrue(s.main.isTxVFO); XCTAssertFalse(s.sub.isTxVFO)
    }
    func testCopyAToB() {
        let s = apply(.copyAToB)
        XCTAssertEqual(s.sub.frequencyHz, s.main.frequencyHz)
        XCTAssertEqual(s.main.frequencyHz, 7_128_500)
    }
    func testCopyBToA() {
        let s = apply(.copyBToA)
        XCTAssertEqual(s.main.frequencyHz, 14_195_000); XCTAssertEqual(s.sub.frequencyHz, 14_195_000)
    }
    func testSwapAB() {
        let s = apply(.swapAB)
        XCTAssertEqual(s.main.frequencyHz, 14_195_000); XCTAssertEqual(s.sub.frequencyHz, 7_128_500)
    }
    func testFlagToggles() {
        XCTAssertFalse(apply(.setRIT(false)).main.ritEnabled)
        XCTAssertTrue(apply(.setXIT(true)).main.xitEnabled)
        XCTAssertFalse(apply(.setCTUN(false)).session.ctunEnabled)
        XCTAssertTrue(apply(.setVFOLock(true)).session.vfoLocked)
    }
    func testSetModeChangesOnlyThatReceiver() {
        let s = apply(.setMode(.sub, .cwu))
        XCTAssertEqual(s.sub.mode, .cwu); XCTAssertEqual(s.main.mode, .lsb)
    }
    func testSetFilterAndBandwidthLock() {
        XCTAssertEqual(apply(.setFilter(.main, hz: 2400)).main.filterHz, 2400)
        XCTAssertEqual(apply(.setFilter(.main, hz: 2400)).sub.filterHz, 2700)
        XCTAssertFalse(apply(.setBandwidthLock(false)).filter.bwLocked)
    }
    func testSelectBandTunesFocusedReceiverAndRecentres() {
        let s = apply(.selectBand("20"))
        XCTAssertEqual(s.band.selectedBand, "20")
        XCTAssertEqual(s.main.frequencyHz, 14_200_000)
        XCTAssertEqual(s.display.spanLowHz, 14_130_000); XCTAssertEqual(s.display.spanHighHz, 14_270_000)
        XCTAssertEqual(s.sub.frequencyHz, 14_195_000)
    }
    func testSelectBandTunesFocusedSub() {
        var s = apply(.focus(.sub), subOn())
        s = apply(.selectBand("10"), s)
        XCTAssertEqual(s.sub.frequencyHz, 28_500_000); XCTAssertEqual(s.main.frequencyHz, 7_128_500)
        XCTAssertEqual(s.session.statusMessage, "Tuned to 28.500.000 USB")
    }
    func testSelectUnknownBandChangesNothing() {
        XCTAssertEqual(apply(.selectBand("99")), .sample)
    }
    func testAGCIsSharedByBothReceivers() {
        let s = apply(.setAGC(.fast))
        XCTAssertEqual(s.main.agc, .fast); XCTAssertEqual(s.sub.agc, .fast)
    }
    func testSetDSPTurnsOnDSPAndQuickToggle() {
        let s = apply(.setDSP(.nb, true))
        XCTAssertEqual(s.dsp.toggles.first { $0.id == "NB" }?.isOn, true)
        XCTAssertEqual(s.main.quickToggles.first { $0.id == "NB" }?.isOn, true)
        let off = apply(.setDSP(.nb, false), s)
        XCTAssertEqual(off.dsp.toggles.first { $0.id == "NB" }?.isOn, false)
        XCTAssertEqual(off.main.quickToggles.first { $0.id == "NB" }?.isOn, false)
    }
    func testSetDSPNotchUsesNFId() {
        let s = apply(.setDSP(.nf, false))
        XCTAssertEqual(s.dsp.toggles.first { $0.id == "NF" }?.isOn, false)
        XCTAssertEqual(s.main.quickToggles.first { $0.id == "NOTCH" }?.isOn, false)
    }
    func testSetDSPSquelchUpdatesSquelchFlag() {
        XCTAssertTrue(apply(.setDSP(.sq, true)).dsp.squelchOn)
    }
    func testTuneAndSelectBandSetStatusMessage() {
        XCTAssertEqual(apply(.tune(.main, deltaHz: 1_000)).session.statusMessage, "Tuned to 7.129.500 LSB")
        XCTAssertEqual(apply(.selectBand("20")).session.statusMessage, "Tuned to 14.200.000 LSB")
    }
    func testLockedRefusesTuning() {
        var locked = RadioSnapshot.sample; locked.session.vfoLocked = true
        for c: RadioCommand in [.tune(.main, deltaHz: 1_000), .selectBand("20"), .copyAToB, .copyBToA, .swapAB] {
            XCTAssertEqual(apply(c, locked), locked, "\(c)")
        }
    }

    // MARK: - Spectrum gestures

    func testSpectrumTuningIsMockedInSampleMode() {
        XCTAssertEqual(MockRadioBackend().capabilities.control(.spectrumTuning), .mocked)
    }

    func testTuneCarrierMovesDialAndKeepsItInView() {
        let m = MockRadioBackend()
        m.send(.tuneCarrier(.main, hz: 7_130_000))
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_130_000)
        XCTAssertEqual(m.snapshot.display.mainCarrierHz, 7_130_000)
        m.send(.tuneCarrier(.main, hz: 7_400_000))
        XCTAssertTrue((m.snapshot.display.spanLowHz...m.snapshot.display.spanHighHz).contains(7_400_000))
    }

    func testGestureTuningObeysVfoLock() {
        let m = MockRadioBackend()
        m.send(.setVFOLock(true))
        m.send(.tuneCarrier(.main, hz: 7_130_000))
        m.send(.wheelTune(.main, ticks: 1))
        m.send(.grabVfo(deltaHz: 500))
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_128_500)
    }

    func testWheelTuneUsesStepAndStickyRule() {
        var snap = RadioSnapshot.sample
        snap.display.wheelStepHz = 1000
        snap.display.stickyWheel = true
        let m = MockRadioBackend(snapshot: snap)     // 7_128_500
        m.send(.wheelTune(.main, ticks: 1))
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_129_000)
        m.send(.wheelTune(.main, ticks: -2))
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_127_000)
    }

    func testGrabAndCtunPan() {
        let m = MockRadioBackend()
        m.send(.grabVfo(deltaHz: 1_500))
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_130_000)
        let low = m.snapshot.display.spanLowHz, high = m.snapshot.display.spanHighHz
        m.send(.ctunPan(deltaHz: 2_000))
        XCTAssertEqual(m.snapshot.display.spanLowHz, low - 2_000)
        XCTAssertEqual(m.snapshot.display.spanHighHz, high - 2_000)
        XCTAssertEqual(m.snapshot.main.frequencyHz, 7_130_000)
    }

    func testFocusToggleMovesVfoBAndFocus() {
        let m = MockRadioBackend()
        m.send(.setSubEnabled(true))
        m.send(.spectrumFocusToggle(hz: 7_140_000))
        XCTAssertEqual(m.snapshot.sub.frequencyHz, 7_140_000)
        XCTAssertEqual(m.snapshot.session.focused, .sub)
        m.send(.spectrumFocusToggle(hz: 7_150_000))
        XCTAssertEqual(m.snapshot.session.focused, .main)
        XCTAssertEqual(m.snapshot.sub.frequencyHz, 7_140_000)
    }

    func testSetZoomScalesSpanAroundItsCentre() {
        let m = MockRadioBackend()
        let d = m.snapshot.display
        let centre = (d.spanLowHz + d.spanHighHz) / 2, width = d.spanHighHz - d.spanLowHz
        m.send(.setZoom(d.zoom * 2))
        XCTAssertEqual(m.snapshot.display.zoom, d.zoom * 2)
        XCTAssertEqual(m.snapshot.display.spanHighHz - m.snapshot.display.spanLowHz, width / 2)
        XCTAssertEqual((m.snapshot.display.spanLowHz + m.snapshot.display.spanHighHz) / 2, centre)
        m.send(.setZoom(99))
        XCTAssertEqual(m.snapshot.display.zoom, 16)
        m.send(.setZoom(0.1))
        XCTAssertEqual(m.snapshot.display.zoom, 1)
    }

    func testDisplaySettingsApplyToTheSnapshot() {
        let m = MockRadioBackend()
        m.send(.setWheelStep(50))
        XCTAssertEqual(m.snapshot.display.wheelStepHz, 50)
        m.send(.setExactTuning(true))
        XCTAssertTrue(m.snapshot.display.exactTuning)
        for p: PeakHoldSetting in [.off, .hold, .live, .seconds(5)] {
            m.send(.setPeakHold(p))
            XCTAssertEqual(m.snapshot.display.peakHold, p)
        }
        m.send(.setBandPlanVisible(false))
        XCTAssertFalse(m.snapshot.display.bandPlanVisible)
        m.send(.setSpotsVisible(false))
        XCTAssertFalse(m.snapshot.display.spotsVisible)
        m.send(.setTuningStep(.sub, 5000))
        XCTAssertEqual(m.snapshot.sub.stepHz, 5000)
        XCTAssertEqual(m.snapshot.main.stepHz, 100)
    }

    func testAveragingRestoresTheLastSmoothing() {
        var snap = RadioSnapshot.sample
        snap.display.smoothing = 7
        let m = MockRadioBackend(snapshot: snap)
        m.send(.setAveraging(false))
        XCTAssertEqual(m.snapshot.display.smoothing, 0)
        XCTAssertFalse(m.snapshot.display.averaging)
        m.send(.setAveraging(true))
        XCTAssertEqual(m.snapshot.display.smoothing, 7)
        var fresh = RadioSnapshot.sample
        fresh.display.smoothing = 0
        let n = MockRadioBackend(snapshot: fresh)
        n.send(.setAveraging(true))
        XCTAssertEqual(n.snapshot.display.smoothing, 5)
    }

    func testClickSnapAndWheelShareOneStep() {
        for (step, exact, grid) in [(500, false, 500), (50, true, 100), (1000, true, 1000), (50, false, 50)] {
            var snap = RadioSnapshot.sample
            snap.display.wheelStepHz = step
            snap.display.exactTuning = exact
            snap.display.stickyWheel = true
            let ctx = SpectrumGestureModel.context(
                stack: .main, display: snap.display,
                inputs: SpectrumGestureInputs(ctuneEnabled: false, subEnabled: false, splitEnabled: false,
                                              focused: .main, status: .mocked, send: { _ in }),
                width: 1000)
            let snapped = SpectrumGestureModel.snapCarrier(14_201_333, stepHz: ctx.stepHz, round100: ctx.round100)
            XCTAssertEqual(snapped % Int64(grid), 0, "\(step) \(exact)")
            // The first sticky wheel notch from an off-grid carrier lands on the same grid.
            let m = MockRadioBackend(snapshot: snap)
            m.send(.wheelTune(.main, ticks: 1))
            XCTAssertEqual(m.snapshot.main.frequencyHz % Int64(grid), 0, "\(step) \(exact)")
            XCTAssertEqual(SpectrumGestureModel.effectiveStep(stepHz: ctx.stepHz, round100: ctx.round100), grid)
        }
    }
}

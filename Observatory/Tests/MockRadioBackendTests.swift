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
}

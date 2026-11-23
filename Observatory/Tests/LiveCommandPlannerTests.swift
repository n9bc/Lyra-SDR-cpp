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

    func testSubCarrierIncludesRx2Marker() {
        var e = state(sub: true)
        e.radio.markerOffsetHzRx2 = 600
        XCTAssertEqual(plan(.copyAToB, e).first,
                       .requireJumpAllowed(fromHz: 14_200_600, toHz: 7_100_000))
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

    func testBandWithFocusOnVfoBUnderSplitIsRefused() {
        var e = bandState()
        e.radio.splitEnabled = true
        e.radio.focusedRx = 2
        XCTAssertEqual(plan(.selectBand("40"), e), [])
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
}

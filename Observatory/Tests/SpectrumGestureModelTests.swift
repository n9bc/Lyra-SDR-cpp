import XCTest
@testable import Observatory

final class SpectrumGestureModelTests: XCTestCase {
    private typealias M = SpectrumGestureModel

    private func context(ctune: Bool = false, receiver: ReceiverID = .main, carrier: Int64 = 14_200_700,
                         passband: ClosedRange<Int64> = 14_200_700...14_203_400,
                         step: Int = 1000, round100: Bool = false) -> SpectrumGestureContext {
        SpectrumGestureContext(receiver: receiver, centreHz: 14_200_000, spanHz: 96_000, width: 1000,
                               carrierHz: carrier, passband: passband, ctuneEnabled: ctune,
                               stepHz: step, round100: round100)
    }

    func testFreqAtXMatchesQt() {
        XCTAssertEqual(M.hz(atX: 0, width: 1000, centreHz: 14_200_000, spanHz: 96_000), 14_152_000)
        XCTAssertEqual(M.hz(atX: 750, width: 1000, centreHz: 14_200_000, spanHz: 96_000), 14_224_000)
        XCTAssertEqual(M.hz(atX: 10, width: 0, centreHz: 14_200_000, spanHz: 96_000), 14_200_000)
    }

    func testClickSnapsToStep() {
        XCTAssertEqual(M.snapCarrier(14_201_420, stepHz: 1000, round100: false), 14_201_000)
        XCTAssertEqual(M.snapCarrier(14_201_420, stepHz: 1000, round100: true), 14_201_400)
        XCTAssertEqual(M.snapCarrier(14_201_420, stepHz: 50, round100: true), 14_201_400)
        XCTAssertEqual(M.snapCarrier(14_201_420, stepHz: 1, round100: false), 14_201_420)
        XCTAssertEqual(M.snapCarrier(14_201_500, stepHz: 1000, round100: false), 14_202_000)
    }

    func testWheelStickyFirstNotchSnaps() {
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 500, ticks: 1, sticky: true), 14_228_500)
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 500, ticks: -1, sticky: true), 14_228_000)
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 500, ticks: 1, sticky: false), 14_228_700)
        // On the grid the first notch moves a full step; further notches add.
        XCTAssertEqual(M.nextWheelHz(14_228_000, stepHz: 500, ticks: 3, sticky: true), 14_229_500)
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 500, ticks: -3, sticky: true), 14_227_000)
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 500, ticks: 0, sticky: true), 14_228_200)
        XCTAssertEqual(M.nextWheelHz(300, stepHz: 500, ticks: -5, sticky: false), 0)
        XCTAssertEqual(M.nextWheelHz(14_228_200, stepHz: 1, ticks: 3, sticky: true), 14_228_203)
    }

    func testTuneReceiverRule() {
        XCTAssertEqual(M.tuneReceiver(subEnabled: false, splitEnabled: true, focusedRx: 2), .sub)
        XCTAssertEqual(M.tuneReceiver(subEnabled: false, splitEnabled: false, focusedRx: 2), .main)
        XCTAssertEqual(M.tuneReceiver(subEnabled: true, splitEnabled: false, focusedRx: 2), .sub)
        XCTAssertEqual(M.tuneReceiver(subEnabled: true, splitEnabled: true, focusedRx: 1), .main)
    }

    func testPassbandIsStrictlyInside() {
        XCTAssertTrue(M.isInsidePassband(hz: 14_201_000, passband: 14_200_700...14_203_400))
        XCTAssertFalse(M.isInsidePassband(hz: 14_200_700, passband: 14_200_700...14_203_400))
        XCTAssertFalse(M.isInsidePassband(hz: 14_210_000, passband: 14_200_700...14_203_400))
    }

    func testCtunClickInsidePassbandIgnored() {
        // x=510 -> 14_200_960, inside the passband
        var s = SpectrumGestureSession(startX: 510, startY: 100, context: context(ctune: true))
        XCTAssertNil(s.ended(atX: 510))
        // Without CTUN the same click tunes.
        s = SpectrumGestureSession(startX: 510, startY: 100, context: context())
        XCTAssertEqual(s.ended(atX: 510), .tuneCarrier(.main, hz: 14_201_000))
        // CTUN, outside the passband: tunes.
        s = SpectrumGestureSession(startX: 750, startY: 100, context: context(ctune: true))
        XCTAssertEqual(s.ended(atX: 750), .tuneCarrier(.main, hz: 14_224_000))
    }

    func testCtunTopStripPansBodyGrabs() {
        var pan = SpectrumGestureSession(startX: 500, startY: 5, context: context(ctune: true))
        XCTAssertEqual(pan.moved(toX: 600, at: 1), .ctunPan(deltaHz: 9_600))
        var grab = SpectrumGestureSession(startX: 500, startY: 40, context: context(ctune: true))
        XCTAssertEqual(grab.moved(toX: 600, at: 1), .grabVfo(deltaHz: 9_600))
        // The strip is 15 px; just below it grabs.
        var edge = SpectrumGestureSession(startX: 500, startY: 15, context: context(ctune: true))
        XCTAssertEqual(edge.moved(toX: 600, at: 1), .grabVfo(deltaHz: 9_600))
    }

    func testDragBelowThresholdIsClick() {
        var s = SpectrumGestureSession(startX: 750, startY: 100, context: context())
        XCTAssertNil(s.moved(toX: 755, at: 1))
        XCTAssertEqual(s.ended(atX: 755), .tuneCarrier(.main, hz: 14_224_000))
        // Crossing the threshold makes it a drag, so release is not a click.
        s = SpectrumGestureSession(startX: 750, startY: 100, context: context())
        XCTAssertNotNil(s.moved(toX: 757, at: 1))
    }

    func testDragRightLowersDial() {
        var s = SpectrumGestureSession(startX: 500, startY: 100, context: context())
        // Carrier 14_200_700 (centre + CW marker), cursor +100 px = 9_600 Hz right: centre -9_600.
        XCTAssertEqual(s.moved(toX: 600, at: 1), .tuneCarrier(.main, hz: 14_191_100))
    }

    func testDragIsThrottledAndFlushesOnRelease() {
        var s = SpectrumGestureSession(startX: 500, startY: 100, context: context(ctune: true))
        XCTAssertEqual(s.moved(toX: 520, at: 1.0), .grabVfo(deltaHz: 1_920))
        XCTAssertNil(s.moved(toX: 530, at: 1.01))                       // inside 1/30 s
        XCTAssertEqual(s.moved(toX: 540, at: 1.05), .grabVfo(deltaHz: 1_920))
        XCTAssertNil(s.moved(toX: 550, at: 1.06))
        XCTAssertEqual(s.ended(atX: 550), .grabVfo(deltaHz: 960))        // residual, not a click
        XCTAssertNil(s.ended(atX: 550))
    }

    func testMiddleClickTogglesFocus() {
        XCTAssertEqual(M.middleClick(atX: 750, context: context()), .spectrumFocusToggle(hz: 14_224_000))
        XCTAssertEqual(M.middleClick(atX: 760, context: context(step: 1000)),
                       .spectrumFocusToggle(hz: 14_225_000))
    }

    func testPreciseScrollAccumulatesToTicks() {
        var acc = 0.0
        var total = 0
        for _ in 0..<60 { total += M.wheelTicks(deltaY: 0.4, deltaX: 0, precise: true, accumulator: &acc) }
        XCTAssertEqual(total, 2)
        acc = 0
        XCTAssertEqual(M.wheelTicks(deltaY: -30, deltaX: 0, precise: true, accumulator: &acc), -2)
    }

    func testLineWheelIsOneTickBySignVerticalWins() {
        var acc = 0.0
        XCTAssertEqual(M.wheelTicks(deltaY: 3, deltaX: 0, precise: false, accumulator: &acc), 1)
        XCTAssertEqual(M.wheelTicks(deltaY: -0.1, deltaX: 5, precise: false, accumulator: &acc), -1)
        XCTAssertEqual(M.wheelTicks(deltaY: 0, deltaX: 2, precise: false, accumulator: &acc), -1)
        XCTAssertEqual(M.wheelTicks(deltaY: 0, deltaX: -2, precise: false, accumulator: &acc), 1)
        XCTAssertEqual(M.wheelTicks(deltaY: 0, deltaX: 0, precise: false, accumulator: &acc), 0)
    }

    func testZoomFactor() {
        XCTAssertEqual(M.zoomFactor(ticks: 1), 1.25, accuracy: 1e-12)
        XCTAssertEqual(M.zoomFactor(ticks: -1), 0.8, accuracy: 1e-12)
        XCTAssertEqual(M.zoomFactor(ticks: 2), 1.5625, accuracy: 1e-12)
        XCTAssertEqual(M.zoomFactor(ticks: 0), 1, accuracy: 1e-12)
    }

    func testConstants() {
        XCTAssertEqual(M.dragThresholdPx, 6)
        XCTAssertEqual(M.dragThrottle, 1.0 / 30)
        XCTAssertEqual(M.ctunPanStripPx, 15)
    }
}

final class SpectrumGestureContextTests: XCTestCase {
    private func inputs(sub: Bool = false, split: Bool = false, focused: ReceiverID = .main,
                        status: CapabilityStatus = .mocked) -> SpectrumGestureInputs {
        SpectrumGestureInputs(ctuneEnabled: false, subEnabled: sub, splitEnabled: split,
                              focused: focused, status: status, send: { _ in })
    }

    func testMainStackTunesPanTuneReceiver() throws {
        let d = RadioSnapshot.sample.display
        let main = try XCTUnwrap(SpectrumGestureModel.context(stack: .main, display: d, inputs: inputs(), width: 800))
        XCTAssertEqual(main.receiver, .main)
        XCTAssertEqual(main.carrierHz, d.mainCarrierHz)
        // Sub focused and on, drawn on the Main axis: the click tunes Sub against the Sub line.
        let sub = try XCTUnwrap(SpectrumGestureModel.context(stack: .main, display: d,
                                                             inputs: inputs(sub: true, focused: .sub), width: 800))
        XCTAssertEqual(sub.receiver, .sub)
        XCTAssertEqual(sub.carrierHz, d.subCarrierHz)
        XCTAssertEqual(sub.centreHz, (d.spanLowHz + d.spanHighHz) / 2)
    }

    func testSubStackAlwaysTunesSubOnItsOwnSpan() throws {
        let d = RadioSnapshot.sample.display.view(for: .sub)
        let c = try XCTUnwrap(SpectrumGestureModel.context(stack: .sub, display: d, inputs: inputs(), width: 800))
        XCTAssertEqual(c.receiver, .sub)
        XCTAssertEqual(c.spanHz, d.spanHighHz - d.spanLowHz)
    }

    /// No analyzer (span 0) means no axis to map a click to (final review, M2).
    func testNoContextWithoutAnAnalyzer() {
        var d = RadioSnapshot.sample.display
        d.spanHighHz = d.spanLowHz
        XCTAssertNil(SpectrumGestureModel.context(stack: .main, display: d, inputs: inputs(), width: 800))
        d.spanHighHz = d.spanLowHz - 10
        XCTAssertNil(SpectrumGestureModel.context(stack: .main, display: d, inputs: inputs(), width: 800))
        XCTAssertNil(SpectrumGestureModel.context(stack: .main, display: RadioSnapshot.sample.display,
                                                  inputs: inputs(), width: 0))
    }

    // MARK: - Zoom accumulation (final review, M4)

    func testFastZoomStepsAccumulateUntilTheSnapshotCatchesUp() {
        var z = SpectrumZoomAccumulator()
        XCTAssertEqual(z.next(snapshotZoom: 2, factor: 1.25, now: 0), 2.5, accuracy: 1e-9)
        // The snapshot still says 2: build on the 2.5 just asked for, not on 2.
        XCTAssertEqual(z.next(snapshotZoom: 2, factor: 1.25, now: 0.01), 3.125, accuracy: 1e-9)
        XCTAssertEqual(z.next(snapshotZoom: 2.5, factor: 0.8, now: 0.02), 2.5, accuracy: 1e-9)
        // Caught up: the snapshot is the base again.
        XCTAssertEqual(z.next(snapshotZoom: 2.5, factor: 1.25, now: 0.03), 3.125, accuracy: 1e-9)
    }

    func testStaleRequestYieldsToTheSnapshot() {
        var z = SpectrumZoomAccumulator()
        _ = z.next(snapshotZoom: 2, factor: 1.25, now: 0)
        // The engine settled elsewhere (another control changed it) and time has passed.
        XCTAssertEqual(z.next(snapshotZoom: 4, factor: 1.25, now: 1), 5, accuracy: 1e-9)
    }

    func testAccumulatedZoomIsClamped() {
        var z = SpectrumZoomAccumulator()
        XCTAssertEqual(z.next(snapshotZoom: 15, factor: 1.25, now: 0), 16)
        XCTAssertEqual(z.next(snapshotZoom: 15, factor: 1.25, now: 0.01), 16)
        XCTAssertEqual(z.next(snapshotZoom: 15, factor: 0.8, now: 0.02), 12.8, accuracy: 1e-9)
        var low = SpectrumZoomAccumulator()
        XCTAssertEqual(low.next(snapshotZoom: 1, factor: 0.8, now: 0), 1)
        XCTAssertEqual(low.next(snapshotZoom: .nan, factor: 1.25, now: 5), 1.25, accuracy: 1e-9)
    }

    func testAvailability() {
        XCTAssertTrue(inputs(status: .available).isEnabled)
        XCTAssertTrue(inputs(status: .mocked).isEnabled)
        let off = inputs(status: .unavailable("why"))
        XCTAssertFalse(off.isEnabled)
        XCTAssertEqual(off.disabledReason, "why")
    }
}

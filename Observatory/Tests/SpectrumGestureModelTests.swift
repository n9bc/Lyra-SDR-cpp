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

    // MARK: - Passband edges and the dB scale (M5a Task 4)

    func testBandwidthForEdgeMatchesEngine() {
        // Expected values are `WdspEngine::bandwidthForModeEdge` worked by hand:
        // int(bw + 0.5) clamped to 50...20000, with the CW pitch at 600 Hz.
        let table: [(String, Double, Int)] = [
            ("USB", 1500, 1500), ("USB", -1500, 1500), ("USB", 1500.4, 1500), ("USB", 1500.5, 1501),
            ("USB", 10, 50), ("USB", 30_000, 20_000), ("LSB", -2400, 2400), ("DIGU", 2000, 2000),
            ("DIGL", -2000, 2000),
            ("CWU", 1000, 800), ("CWU", 0, 1200), ("CWU", -200, 1600), ("CWU", 600, 50),
            ("CWL", -1000, 800), ("CWL", 1000, 3200), ("CWL", -600, 50),
            ("AM", 3000, 6000), ("AM", -3000, 6000), ("AM", 10, 50), ("AM", 15_000, 20_000),
            ("FM", 2.4, 50), ("DSB", 4000.3, 8001), ("DSB", 4000.2, 8000), ("SAM", 5, 50),
        ]
        for (mode, off, want) in table {
            XCTAssertEqual(M.bandwidthForEdge(off, mode: mode), want, "\(mode) \(off)")
        }
        // The pitch is the engine's, not a constant.
        XCTAssertEqual(M.bandwidthForEdge(1000, mode: "CWU", cwPitchHz: 700), 600)
        XCTAssertEqual(M.bandwidthForEdge(.nan, mode: "USB"), 50)
    }

    func testEdgeHitIsNineWideAndNearestWins() {
        XCTAssertEqual(M.edgeHit(x: 300, loX: 300, hiX: 500), .low)
        XCTAssertEqual(M.edgeHit(x: 304.5, loX: 300, hiX: 500), .low)
        XCTAssertNil(M.edgeHit(x: 304.6, loX: 300, hiX: 500))
        XCTAssertEqual(M.edgeHit(x: 495.5, loX: 300, hiX: 500), .high)
        XCTAssertNil(M.edgeHit(x: 400, loX: 300, hiX: 500))
        // A passband narrower than a handle: the nearer edge wins.
        XCTAssertEqual(M.edgeHit(x: 302, loX: 300, hiX: 304), .low)
        XCTAssertEqual(M.edgeHit(x: 303, loX: 300, hiX: 304), .high)
    }

    func testDbZoneThirdsAndTopStrip() {
        // Right 50 px of a 1000 x 300 spectrum; the top 24 px are reserved.
        XCTAssertNil(M.dbZone(x: 949, y: 150, width: 1000, height: 300))
        XCTAssertNil(M.dbZone(x: 980, y: 23, width: 1000, height: 300))
        XCTAssertEqual(M.dbZone(x: 950, y: 24, width: 1000, height: 300), .ceiling)
        XCTAssertEqual(M.dbZone(x: 980, y: 99, width: 1000, height: 300), .ceiling)
        XCTAssertEqual(M.dbZone(x: 980, y: 150, width: 1000, height: 300), .both)
        XCTAssertEqual(M.dbZone(x: 980, y: 200, width: 1000, height: 300), .both)
        XCTAssertEqual(M.dbZone(x: 980, y: 201, width: 1000, height: 300), .floor)
        XCTAssertNil(M.dbZone(x: 980, y: 150, width: 0, height: 300))
    }

    func testDbDragClamps() {
        // dy down by a tenth of the height lowers by a tenth of the span (110 dB -> 11 dB).
        var r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: 30, height: 300, zone: .both)
        XCTAssertEqual(r.floor, -141, accuracy: 1e-9)
        XCTAssertEqual(r.ceiling, -31, accuracy: 1e-9)
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: 30, height: 300, zone: .ceiling)
        XCTAssertEqual(r.floor, -130)
        XCTAssertEqual(r.ceiling, -31, accuracy: 1e-9)
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: 30, height: 300, zone: .floor)
        XCTAssertEqual(r.floor, -141, accuracy: 1e-9)
        XCTAssertEqual(r.ceiling, -20)
        // The floor never rises above -3, nor falls below -150.
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: -3000, height: 300, zone: .floor)
        XCTAssertEqual(r.floor, -3)
        XCTAssertEqual(r.ceiling, 0)   // pushed up to floor + 3
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: 3000, height: 300, zone: .both)
        XCTAssertEqual(r.floor, -150)
        // The ceiling stays within floor + 3 ... 30.
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: -3000, height: 300, zone: .ceiling)
        XCTAssertEqual(r.ceiling, 30)
        r = M.dbDrag(startFloor: -130, startCeiling: -20, dy: 3000, height: 300, zone: .ceiling)
        XCTAssertEqual(r.ceiling, -127)
    }

    func testDbDragSeedsFromAutoAndTurnsAutoOff() {
        var d = SpectrumDbDrag(zone: .both, startY: 100, shownFloor: -121.6, shownCeiling: -33.4, auto: true)
        XCTAssertEqual(d.beginCommands, [.setDbRange(floor: -122, ceiling: -33), .setDbAuto(false)])
        // The drag builds on the rounded values the engine was given.
        XCTAssertEqual(d.moved(toY: 100 + 30, height: 300, at: 0),
                       .setDbRange(floor: -122 - 8.9, ceiling: -33 - 8.9))
        let manual = SpectrumDbDrag(zone: .floor, startY: 100, shownFloor: -130, shownCeiling: -20, auto: false)
        XCTAssertEqual(manual.beginCommands, [])
    }

    func testDbDragThrottlesAndFlushesOnRelease() {
        var d = SpectrumDbDrag(zone: .ceiling, startY: 100, shownFloor: -130, shownCeiling: -20, auto: false)
        XCTAssertNotNil(d.moved(toY: 110, height: 300, at: 0))
        XCTAssertNil(d.moved(toY: 120, height: 300, at: 0.01))
        XCTAssertNil(d.moved(toY: 130, height: 300, at: 0.02))
        XCTAssertEqual(d.ended(atY: 130, height: 300), .setDbRange(floor: -130, ceiling: -20 - 11))
        XCTAssertNil(d.ended(atY: 130, height: 300))
    }

    func testEdgeDragSendsOffsetsAndFlushes() {
        var d = SpectrumEdgeDrag(edge: .high, width: 1000, spanHz: 96_000)
        XCTAssertEqual(d.moved(toX: 625, at: 0), .dragPassbandEdge(.high, offsetHz: 12_000))
        XCTAssertNil(d.moved(toX: 700, at: 0.01))
        XCTAssertEqual(d.ended(atX: 750), .dragPassbandEdge(.high, offsetHz: 24_000))
        XCTAssertNil(d.ended(atX: 750))
    }

    func testEdgeHandleBeatsClickToTune() {
        // Controller ruling R1: dB zone, then edge handle, then notch, then tune.
        let notch = [NotchInfo(offsetHz: 0, widthHz: 200, active: true)]
        func hit(_ x: Double, _ y: Double, edges: (lo: Double, hi: Double)? = (500, 700)) -> SpectrumHitTarget {
            M.hitTarget(x: x, y: y, notches: notch, width: 1000, spanHz: 96_000, notchesEnabled: true,
                        height: 300, dbZoneEnabled: true, edges: edges)
        }
        XCTAssertEqual(hit(702, 100), .edge(.high))
        XCTAssertEqual(hit(498, 100), .edge(.low))
        XCTAssertEqual(hit(600, 100), .tune)
        // An edge handle on top of a notch wins; so does the dB zone over an edge.
        XCTAssertEqual(hit(500, 100), .edge(.low))
        XCTAssertEqual(hit(975, 50, edges: (972, 700)), .dbScale(.ceiling))
        XCTAssertEqual(hit(975, 10, edges: (972, 700)), .edge(.low))
        // No edges (Sub stack, waterfall): the notch and tune rungs are as before.
        XCTAssertEqual(hit(500, 100, edges: nil), .notch(0))
        XCTAssertEqual(M.hitTarget(x: 975, y: 100, notches: [], width: 1000, spanHz: 96_000,
                                   notchesEnabled: false), .tune)
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

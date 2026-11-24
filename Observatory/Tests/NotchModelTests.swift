import XCTest
@testable import Observatory

final class NotchModelTests: XCTestCase {
    private typealias N = NotchModel
    private let w = 1000.0, span = 96_000.0

    private func notch(_ offset: Double, _ width: Double = 200, active: Bool = true) -> NotchInfo {
        NotchInfo(offsetHz: offset, widthHz: width, active: active)
    }

    func testNotchXUsesDisplayCentreNotDial() {
        XCTAssertEqual(N.x(offsetHz: 4_800, width: w, spanHz: span), 550, accuracy: 1e-9)
        // The CTUN dial offset is not a parameter: the x depends on the offset and the span alone.
        XCTAssertEqual(N.x(offsetHz: 4_800, width: w, spanHz: span), 550, accuracy: 1e-9)
    }

    func testOffsetAtX() {
        XCTAssertEqual(N.offset(atX: 250, width: w, spanHz: span), -24_000, accuracy: 1e-9)
        XCTAssertEqual(N.offset(atX: 500, width: w, spanHz: span), 0, accuracy: 1e-9)
        XCTAssertEqual(N.offset(atX: 10, width: 0, spanHz: span), 0)
    }

    func testDrawWidthHasA3pxFloor() {
        XCTAssertEqual(N.drawWidth(widthHz: 200, width: w, spanHz: span), 3, accuracy: 1e-9)
        XCTAssertEqual(N.drawWidth(widthHz: 9_600, width: w, spanHz: span), 100, accuracy: 1e-9)
    }

    func testHitPrefersNearestAndMinimum14px() {
        let list = [notch(0), notch(960)]   // x 500 and 510, both 3 px wide: hit area 14 px
        XCTAssertEqual(N.hitIndex(x: 506, notches: list, width: w, spanHz: span), 1)
        XCTAssertEqual(N.hitIndex(x: 503, notches: list, width: w, spanHz: span), 0)
        XCTAssertEqual(N.hitIndex(x: 517, notches: list, width: w, spanHz: span), 1)    // 7 px from centre
        XCTAssertNil(N.hitIndex(x: 518, notches: list, width: w, spanHz: span))
        // A wide notch uses its drawn width as the hit area.
        let wide = [notch(0, 19_200)]                                                   // 200 px
        XCTAssertEqual(N.hitIndex(x: 599, notches: wide, width: w, spanHz: span), 0)
        XCTAssertNil(N.hitIndex(x: 601, notches: wide, width: w, spanHz: span))
        XCTAssertNil(N.hitIndex(x: 500, notches: [], width: w, spanHz: span))
    }

    /// The offset maths is floating point, so compare moves to a micro-hertz.
    private func assertMove(_ c: RadioCommand?, _ index: Int, _ offset: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .moveNotch(let i, let hz)? = c else {
            return XCTFail("expected a move, got \(String(describing: c))", file: file, line: line)
        }
        XCTAssertEqual(i, index, file: file, line: line)
        XCTAssertEqual(hz, offset, accuracy: 1e-6, file: file, line: line)
    }

    func testWidthFactor() {
        XCTAssertEqual(N.widthFactor(ticks: 1), 0.8, accuracy: 1e-12)
        XCTAssertEqual(N.widthFactor(ticks: -1), 1.25, accuracy: 1e-12)
        XCTAssertEqual(N.widthFactor(ticks: 2), 0.64, accuracy: 1e-12)
    }

    func testNotchWidthClamp() {
        XCTAssertEqual(N.clampedWidth(5), 10)
        XCTAssertEqual(N.clampedWidth(30_000), 20_000)
        XCTAssertEqual(N.clampedWidth(200), 200)
    }

    func testNoNotchesOnSubStack() {
        let list = [notch(100)]
        XCTAssertEqual(N.visible(list, on: .main), list)
        XCTAssertTrue(N.visible(list, on: .sub).isEmpty)
        XCTAssertEqual(N.availability(stack: .sub, status: .available),
                       .unavailable("Notches are on the main receiver"))
        XCTAssertEqual(N.availability(stack: .main, status: .mocked), .mocked)
        XCTAssertEqual(N.availability(stack: .main, status: .unavailable("x")), .unavailable("x"))
    }

    func testSurfaceHelpNamesWhyNotchesAreOffOnSub() {
        let inputs = SpectrumGestureInputs(ctuneEnabled: false, subEnabled: true, splitEnabled: false,
                                           focused: .main, status: .available, send: { _ in })
        XCTAssertTrue(inputs.help(for: .sub).hasSuffix("Notches are on the main receiver"))
        XCTAssertFalse(inputs.notchesEnabled(on: .sub))
        XCTAssertTrue(inputs.notchesEnabled(on: .main))
        XCTAssertTrue(inputs.help(for: .main).hasSuffix(SpectrumGestureInputs.notchHelp))
    }

    // MARK: - Click gestures

    func testRightClickEmptyAddsNotch() throws {
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 250, notches: [], width: w, spanHz: span))
        XCTAssertNil(g.moved(toX: 252, at: 0, notches: []))
        XCTAssertEqual(g.ended(atX: 252, at: 0.1, notches: []), .addNotch(offsetHz: -24_000))
    }

    func testRightClickOnNotchDeletes() throws {
        let list = [notch(-24_000), notch(0)]
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 500, notches: list, width: w, spanHz: span))
        XCTAssertEqual(g.ended(atX: 500, at: 0.1, notches: list), .removeNotch(index: 1))
    }

    func testRightDragOnEmptyDoesNotAdd() throws {
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 250, notches: [], width: w, spanHz: span))
        XCTAssertNil(g.moved(toX: 260, at: 0, notches: []))
        XCTAssertNil(g.ended(atX: 260, at: 0.1, notches: []))
    }

    func testLeftPressOffNotchIsNotANotchGesture() {
        XCTAssertNil(NotchGesture(button: .left, x: 250, notches: [notch(0)], width: w, spanHz: span))
    }

    func testLeftClickOnNotchDoesNothing() throws {
        let list = [notch(0)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 500, notches: list, width: w, spanHz: span))
        XCTAssertNil(g.ended(atX: 500, at: 0.1, notches: list))
    }

    // MARK: - Drag

    func testDragUnder4pxIsNotAMove() throws {
        let list = [notch(0)]
        for button in [NotchGesture.Button.left, .right] {
            var g = try XCTUnwrap(NotchGesture(button: button, x: 500, notches: list, width: w, spanHz: span))
            XCTAssertNil(g.moved(toX: 503, at: 0, notches: list))
            XCTAssertNil(g.moved(toX: 497, at: 0.05, notches: list))
            // Released within the threshold: a left click does nothing, a right click deletes.
            XCTAssertEqual(g.ended(atX: 497, at: 0.1, notches: list),
                           button == .right ? .removeNotch(index: 0) : nil)
        }
    }

    func testDragMovesTheNotchToTheCursorAndThrottles() throws {
        let list = [notch(0), notch(9_600)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 600, notches: list, width: w, spanHz: span))
        assertMove(g.moved(toX: 640, at: 0, notches: list), 1, 13_440)
        // Inside the 33 ms window: held back.
        XCTAssertNil(g.moved(toX: 660, at: 0.01, notches: list))
        // Release flushes the final position.
        assertMove(g.ended(atX: 700, at: 0.02, notches: list), 1, 19_200)
    }

    func testReleaseDoesNotRepeatTheLastSentValue() throws {
        let list = [notch(0)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 500, notches: list, width: w, spanHz: span))
        assertMove(g.moved(toX: 560, at: 0, notches: list), 0, 5_760)
        XCTAssertNil(g.ended(atX: 560, at: 0.5, notches: list))
    }

    func testDragIsClampedToTheDisplay() throws {
        let list = [notch(0)]
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 500, notches: list, width: w, spanHz: span))
        assertMove(g.moved(toX: 5_000, at: 0, notches: list), 0, 48_000)
    }

    func testMovingOnlyTheGesturedOffsetKeepsTheGestureAlive() throws {
        let start = [notch(0), notch(9_600)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 500, notches: start, width: w, spanHz: span))
        XCTAssertNotNil(g.moved(toX: 560, at: 0, notches: start))
        // The engine reports our own move back.
        let echoed = [notch(5_760), notch(9_600)]
        XCTAssertNotNil(g.moved(toX: 600, at: 0.1, notches: echoed))
    }

    func testGestureDropsWhenListChangesUnderIt() throws {
        let start = [notch(0), notch(9_600)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 500, notches: start, width: w, spanHz: span))
        XCTAssertNotNil(g.moved(toX: 560, at: 0, notches: start))
        // Another notch is removed: the index would now point at a different notch.
        XCTAssertNil(g.moved(toX: 600, at: 0.1, notches: [notch(9_600)]))
        XCTAssertNil(g.moved(toX: 640, at: 0.2, notches: start))        // stays dead
        XCTAssertNil(g.ended(atX: 640, at: 0.3, notches: start))
    }

    func testGestureDropsWhenAnotherNotchChanges() throws {
        let start = [notch(0), notch(9_600)]
        var g = try XCTUnwrap(NotchGesture(button: .left, x: 500, notches: start, width: w, spanHz: span))
        XCTAssertNil(g.moved(toX: 560, at: 0, notches: [notch(0), notch(9_000)]))
        XCTAssertNil(g.ended(atX: 560, at: 0.3, notches: start))
    }

    func testRightClickDeleteDropsWhenListChanged() throws {
        let start = [notch(0)]
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 500, notches: start, width: w, spanHz: span))
        XCTAssertNil(g.ended(atX: 500, at: 0.1, notches: []))
    }

    func testRightClickAddDropsWhenListChanged() throws {
        var g = try XCTUnwrap(NotchGesture(button: .right, x: 250, notches: [], width: w, spanHz: span))
        XCTAssertNil(g.ended(atX: 250, at: 0.1, notches: [notch(0)]))
    }

    // MARK: - Scroll

    func testScrollOverNotchChangesWidthNotTune() {
        let list = [notch(0, 200), notch(9_600, 400)]
        var acc = NotchWidthAccumulator()
        XCTAssertEqual(N.scrollCommand(ticks: 1, x: 600, notches: list, width: w, spanHz: span,
                                       accumulator: &acc, now: 0),
                       .setNotchWidth(index: 1, widthHz: 320))
        XCTAssertEqual(N.scrollCommand(ticks: -1, x: 500, notches: list, width: w, spanHz: span,
                                       accumulator: &acc, now: 1),
                       .setNotchWidth(index: 0, widthHz: 250))
        // Not over a notch: no notch command, so the caller tunes.
        XCTAssertNil(N.scrollCommand(ticks: 1, x: 100, notches: list, width: w, spanHz: span,
                                     accumulator: &acc, now: 2))
    }

    func testScrollClampsAndBuildsOnTheRequestedWidthUntilTheSnapshotCatchesUp() {
        let list = [notch(0, 200)]
        var acc = NotchWidthAccumulator()
        XCTAssertEqual(N.scrollCommand(ticks: 1, x: 500, notches: list, width: w, spanHz: span,
                                       accumulator: &acc, now: 0), .setNotchWidth(index: 0, widthHz: 160))
        // Snapshot still shows 200: the second tick builds on 160.
        XCTAssertEqual(N.scrollCommand(ticks: 1, x: 500, notches: list, width: w, spanHz: span,
                                       accumulator: &acc, now: 0.05), .setNotchWidth(index: 0, widthHz: 128))
        // Stale after half a second: the snapshot wins.
        XCTAssertEqual(N.scrollCommand(ticks: 1, x: 500, notches: list, width: w, spanHz: span,
                                       accumulator: &acc, now: 0.9), .setNotchWidth(index: 0, widthHz: 160))
        var tiny = NotchWidthAccumulator()
        XCTAssertEqual(N.scrollCommand(ticks: 1, x: 500, notches: [notch(0, 10)], width: w, spanHz: span,
                                       accumulator: &tiny, now: 0), .setNotchWidth(index: 0, widthHz: 10))
    }

    // MARK: - Hit priority (controller ruling R1)

    func testNotchWinsOverTuneButLosesToEarlierTargets() {
        let list = [notch(0)]
        XCTAssertEqual(SpectrumGestureModel.hitTarget(x: 500, y: 5, notches: list, width: w, spanHz: span,
                                                      notchesEnabled: true), .notch(0))
        XCTAssertEqual(SpectrumGestureModel.hitTarget(x: 100, y: 5, notches: list, width: w, spanHz: span,
                                                      notchesEnabled: true), .tune)
        XCTAssertEqual(SpectrumGestureModel.hitTarget(x: 500, y: 5, notches: list, width: w, spanHz: span,
                                                      notchesEnabled: false), .tune)
    }
}

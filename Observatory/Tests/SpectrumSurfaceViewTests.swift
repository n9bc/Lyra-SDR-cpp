import AppKit
import XCTest
@testable import Observatory

/// Drives the spectrum and waterfall gesture surface with synthetic events (final review findings
/// 8, 9, 10 and 11). The view is 1400 x 300 points over the sample's 140 kHz span: 100 Hz a point,
/// display centre 7.130 MHz at x = 700, where the one notch sits. The Main passband's edges are at
/// x = 900 and 927.
@MainActor
final class SpectrumSurfaceViewTests: XCTestCase {
    private final class Recorder { var commands: [RadioCommand] = [] }

    private let height = 300.0

    private func display(txAxis: Bool = false) -> DisplaySnapshot {
        var d = RadioSnapshot.sample.display
        d.spanLowHz = 7_060_000
        d.spanHighHz = 7_200_000
        d.mainCarrierHz = 7_150_000
        d.mainPassband = 7_150_000...7_152_700
        d.dbRange = DbRange(floor: -130, ceiling: -20, auto: false)
        d.txAxis = txAxis
        return d
    }

    private func makeView(surface: SpectrumSurface = .spectrum) -> (SpectrumInteractionView.SurfaceView, Recorder) {
        let recorder = Recorder()
        let view = SpectrumInteractionView.SurfaceView(frame: NSRect(x: 0, y: 0, width: 1400, height: height))
        view.stack = .main
        view.surface = surface
        view.display = display()
        view.shownDbRange = (-130, -20)
        view.inputs = SpectrumGestureInputs(
            ctuneEnabled: false, subEnabled: true, splitEnabled: false, focused: .main, status: .available,
            send: { recorder.commands.append($0) },
            notches: [NotchInfo(offsetHz: 0, widthHz: 200, active: true)], notchStatus: .available)
        return (view, recorder)
    }

    /// A mouse event at (x, y) in the view's flipped coordinates.
    private func mouse(_ type: NSEvent.EventType, x: Double, y: Double = 150, t: TimeInterval,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height - y), modifierFlags: flags,
                           timestamp: t, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    private func wheel(x: Double) -> NSEvent {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        e.location = CGPoint(x: x, y: 150)
        return NSEvent(cgEvent: e)!
    }

    private func isNotchCommand(_ c: RadioCommand) -> Bool {
        switch c {
        case .moveNotch, .removeNotch, .addNotch, .setNotchWidth: true
        default: false
        }
    }

    // MARK: Finding 8

    func testWaterfallDragOverANotchPansInsteadOfMovingIt() {
        let (view, rec) = makeView(surface: .waterfall)
        view.mouseDown(with: mouse(.leftMouseDown, x: 700, t: 1))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 760, t: 1.1))
        view.mouseUp(with: mouse(.leftMouseUp, x: 760, t: 1.2))
        XCTAssertFalse(rec.commands.isEmpty)
        XCTAssertFalse(rec.commands.contains(where: isNotchCommand), "\(rec.commands)")
    }

    func testWaterfallClickOverANotchTunes() {
        let (view, rec) = makeView(surface: .waterfall)
        view.mouseDown(with: mouse(.leftMouseDown, x: 701, t: 1))
        view.mouseUp(with: mouse(.leftMouseUp, x: 701, t: 1.05))
        XCTAssertEqual(rec.commands.count, 1)
        if case .tuneCarrier = rec.commands.first {} else { XCTFail("\(rec.commands)") }
    }

    func testWaterfallRightClickOverANotchDoesNotRemoveIt() {
        let (view, rec) = makeView(surface: .waterfall)
        view.rightMouseDown(with: mouse(.rightMouseDown, x: 700, t: 1))
        view.rightMouseUp(with: mouse(.rightMouseUp, x: 700, t: 1.05))
        XCTAssertFalse(rec.commands.contains(where: isNotchCommand), "\(rec.commands)")
    }

    func testWaterfallScrollOverANotchTunes() {
        let (view, rec) = makeView(surface: .waterfall)
        view.scrollWheel(with: wheel(x: 700))
        XCTAssertEqual(rec.commands, [.wheelTune(.main, ticks: 1)])
    }

    func testSpectrumStillHasNotchGestures() {
        let (view, rec) = makeView(surface: .spectrum)
        view.rightMouseDown(with: mouse(.rightMouseDown, x: 700, t: 1))
        view.rightMouseUp(with: mouse(.rightMouseUp, x: 700, t: 1.05))
        XCTAssertEqual(rec.commands, [.removeNotch(index: 0)])
    }

    // MARK: Finding 9

    func testPlainClickOnAnEdgeHandleWritesNothing() {
        let (view, rec) = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, x: 903, t: 1))
        view.mouseUp(with: mouse(.leftMouseUp, x: 903, t: 1.05))
        XCTAssertEqual(rec.commands, [])
    }

    // MARK: Finding 10

    func testDbDragEndsSilentlyWhenTxTakesTheAxis() {
        let (view, rec) = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, x: 1380, y: 150, t: 1))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 1380, y: 170, t: 1.1))
        XCTAssertEqual(rec.commands.count, 1)
        view.display = display(txAxis: true)
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 1380, y: 190, t: 1.2))
        view.mouseUp(with: mouse(.leftMouseUp, x: 1380, y: 200, t: 1.3))
        XCTAssertEqual(rec.commands.count, 1, "nothing written into the TX pair: \(rec.commands)")
    }

    func testEdgeDragEndsSilentlyWhenTxTakesTheAxis() {
        let (view, rec) = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, x: 903, t: 1))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 950, t: 1.1))
        XCTAssertEqual(rec.commands.count, 1)
        view.display = display(txAxis: true)
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 990, t: 1.2))
        view.mouseUp(with: mouse(.leftMouseUp, x: 1000, t: 1.3))
        XCTAssertEqual(rec.commands.count, 1, "\(rec.commands)")
    }

    // MARK: Finding 11

    func testOptionClickOnANotchTogglesFocus() {
        let (view, rec) = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, x: 700, t: 1, flags: .option))
        view.mouseUp(with: mouse(.leftMouseUp, x: 700, t: 1.05, flags: .option))
        XCTAssertEqual(rec.commands, [.spectrumFocusToggle(hz: 7_130_000)])
    }
}

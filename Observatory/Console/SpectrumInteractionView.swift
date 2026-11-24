import AppKit
import SwiftUI

/// What the gesture surface needs from the console beyond the display it sits on.
struct SpectrumGestureInputs {
    var ctuneEnabled: Bool
    var subEnabled: Bool
    var splitEnabled: Bool
    var focused: ReceiverID
    /// Availability of `ConsoleControl.spectrumTuning`.
    var status: CapabilityStatus
    var send: (RadioCommand) -> Void

    var isEnabled: Bool { status == .available || status == .mocked }

    /// Why the surface does nothing, shown as its tooltip.
    var disabledReason: String? {
        if case .unavailable(let reason) = status { return reason }
        return nil
    }

    static let help = "Click to tune, drag to pan, scroll to step, Command-scroll or pinch to zoom, middle or Option click to switch receiver"
}

extension SpectrumGestureModel {
    /// The gesture context for `stack`'s display. The Main stack tunes whichever receiver Qt's
    /// `panTuneRx` rule picks; the Sub stack always tunes Sub. `display` is that stack's own
    /// view (`DisplaySnapshot.view(for:)`), so its span and VFO line are already the right ones.
    nonisolated static func context(stack: ReceiverID, display: DisplaySnapshot,
                                    inputs: SpectrumGestureInputs, width: Double) -> SpectrumGestureContext {
        let receiver = stack == .sub ? ReceiverID.sub
            : tuneReceiver(subEnabled: inputs.subEnabled, splitEnabled: inputs.splitEnabled,
                           focusedRx: inputs.focused == .sub ? 2 : 1)
        // Sub drawn on the Main axis: its VFO line and passband are the Sub overlay's.
        let onMainAxis = stack == .main && receiver == .sub
        return SpectrumGestureContext(
            receiver: receiver,
            centreHz: (display.spanLowHz + display.spanHighHz) / 2,
            spanHz: display.spanHighHz - display.spanLowHz,
            width: width,
            carrierHz: onMainAxis ? display.subCarrierHz : display.mainCarrierHz,
            passband: onMainAxis ? display.subPassband : display.mainPassband,
            ctuneEnabled: inputs.ctuneEnabled,
            stepHz: display.wheelStepHz,
            round100: display.exactTuning)
    }
}

/// Transparent AppKit surface laid over a spectrum or waterfall. It turns mouse, scroll and
/// magnify events into `RadioCommand`s through `SpectrumGestureModel`; it never reads or
/// writes the engine itself.
struct SpectrumInteractionView: NSViewRepresentable {
    let stack: ReceiverID
    let display: DisplaySnapshot
    let inputs: SpectrumGestureInputs

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.stack = stack
        view.display = display
        view.inputs = inputs
        view.toolTip = inputs.disabledReason ?? SpectrumGestureInputs.help
    }

    final class SurfaceView: NSView {
        var stack: ReceiverID = .main
        var display: DisplaySnapshot?
        var inputs: SpectrumGestureInputs?

        private var session: SpectrumGestureSession?
        private var optionClick = false
        private var scrollAccumulator = 0.0

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var live: (DisplaySnapshot, SpectrumGestureInputs)? {
            guard let display, let inputs, inputs.isEnabled else { return nil }
            return (display, inputs)
        }

        private func context() -> (SpectrumGestureContext, SpectrumGestureInputs)? {
            guard let (display, inputs) = live, bounds.width > 0 else { return nil }
            return (SpectrumGestureModel.context(stack: stack, display: display, inputs: inputs,
                                                 width: bounds.width), inputs)
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            guard let (ctx, _) = context() else { return }
            let p = point(event)
            optionClick = event.modifierFlags.contains(.option)
            session = optionClick ? nil : SpectrumGestureSession(startX: p.x, startY: p.y, context: ctx)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let (_, inputs) = context(), session != nil else { return }
            if let command = session?.moved(toX: point(event).x, at: event.timestamp) {
                inputs.send(command)
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer { session = nil; optionClick = false }
            guard let (ctx, inputs) = context() else { return }
            let x = point(event).x
            if optionClick {
                inputs.send(SpectrumGestureModel.middleClick(atX: x, context: ctx))
            } else if let command = session?.ended(atX: x) {
                inputs.send(command)
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, let (ctx, inputs) = context() else { return }
            inputs.send(SpectrumGestureModel.middleClick(atX: point(event).x, context: ctx))
        }

        override func scrollWheel(with event: NSEvent) {
            // Trackpad momentum would keep tuning after the fingers lift.
            guard event.momentumPhase.isEmpty, let (ctx, inputs) = context(), let display else { return }
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            let ticks = SpectrumGestureModel.wheelTicks(
                deltaY: Double(event.scrollingDeltaY), deltaX: Double(event.scrollingDeltaX),
                precise: event.hasPreciseScrollingDeltas, accumulator: &scrollAccumulator)
            guard ticks != 0 else { return }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                inputs.send(.setZoom(display.zoom * SpectrumGestureModel.zoomFactor(ticks: ticks)))
            } else {
                inputs.send(.wheelTune(ctx.receiver, ticks: ticks))
            }
        }

        override func magnify(with event: NSEvent) {
            guard let (_, inputs) = context(), let display else { return }
            inputs.send(.setZoom(display.zoom * max(0.1, 1 + Double(event.magnification))))
        }
    }
}

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
    /// The engine's manual notches (Main stack only; the Sub stack never sees them) and the
    /// availability of `ConsoleControl.notches`.
    var notches: [NotchInfo] = []
    var notchStatus: CapabilityStatus = .available

    var isEnabled: Bool { status == .available || status == .mocked }

    /// Why the surface does nothing, shown as its tooltip.
    var disabledReason: String? {
        if case .unavailable(let reason) = status { return reason }
        return nil
    }

    static let help = "Click to tune, drag to pan, scroll to step, Command-scroll or pinch to zoom, middle or Option click to switch receiver"
    static let notchHelp = "Right-click to add or remove a notch, drag a notch to move it, scroll over it to change its width"

    /// The notch gestures' availability on `stack`.
    func notchAvailability(on stack: ReceiverID) -> CapabilityStatus {
        NotchModel.availability(stack: stack, status: notchStatus)
    }

    func notchesEnabled(on stack: ReceiverID) -> Bool {
        let s = notchAvailability(on: stack)
        return s == .available || s == .mocked
    }

    /// The surface's tooltip: the tuning help (or why tuning is off), then the notch help (or why
    /// notches are off here).
    func help(for stack: ReceiverID) -> String {
        let tuning = disabledReason ?? Self.help
        if case .unavailable(let reason) = notchAvailability(on: stack) { return tuning + "\n" + reason }
        return tuning + "\n" + Self.notchHelp
    }
}

extension SpectrumGestureModel {
    /// The gesture context for `stack`'s display. The Main stack tunes whichever receiver Qt's
    /// `panTuneRx` rule picks; the Sub stack always tunes Sub. `display` is that stack's own
    /// view (`DisplaySnapshot.view(for:)`), so its span and VFO line are already the right ones.
    /// Nil with no analyzer (an empty span) or no width: there is no axis to map a gesture to.
    nonisolated static func context(stack: ReceiverID, display: DisplaySnapshot,
                                    inputs: SpectrumGestureInputs, width: Double) -> SpectrumGestureContext? {
        guard display.spanHighHz > display.spanLowHz, width > 0 else { return nil }
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
        view.toolTip = inputs.help(for: stack)
    }

    final class SurfaceView: NSView {
        var stack: ReceiverID = .main
        var display: DisplaySnapshot?
        var inputs: SpectrumGestureInputs?

        private var session: SpectrumGestureSession?
        /// A press that began on a notch, or a right press that may add one.
        private var notchGesture: NotchGesture?
        private var notchWidth = NotchWidthAccumulator()
        private var zoom = SpectrumZoomAccumulator()
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
            guard let (display, inputs) = live,
                  let ctx = SpectrumGestureModel.context(stack: stack, display: display, inputs: inputs,
                                                         width: bounds.width) else { return nil }
            return (ctx, inputs)
        }

        /// What notch gestures need: the Main stack's notches, its width and span. Nil when notch
        /// gestures are off (Sub stack, `.notches` unavailable) or there is no axis.
        private func notchContext() -> (notches: [NotchInfo], width: Double, span: Double, inputs: SpectrumGestureInputs)? {
            guard let display, let inputs, inputs.notchesEnabled(on: stack) else { return nil }
            let span = Double(display.spanHighHz - display.spanLowHz)
            guard span > 0, bounds.width > 0 else { return nil }
            return (NotchModel.visible(inputs.notches, on: stack), Double(bounds.width), span, inputs)
        }

        /// Starts a notch gesture when the press lands on a notch (any button) or is a right press.
        private func beginNotchGesture(_ event: NSEvent, button: NotchGesture.Button) -> Bool {
            guard let n = notchContext() else { return false }
            let p = point(event)
            // Controller ruling R1: the dB-scale zone and the passband-edge handles (Task 4) are
            // checked before this, through `SpectrumGestureModel.hitTarget`.
            if button == .left,
               case .tune = SpectrumGestureModel.hitTarget(x: p.x, y: p.y, notches: n.notches, width: n.width,
                                                           spanHz: n.span, notchesEnabled: true) {
                return false
            }
            notchGesture = NotchGesture(button: button, x: p.x, notches: n.notches, width: n.width, spanHz: n.span)
            return notchGesture != nil
        }

        private func moveNotchGesture(_ event: NSEvent) {
            guard notchGesture != nil, let n = notchContext() else { return }
            if let command = notchGesture?.moved(toX: point(event).x, at: event.timestamp, notches: n.notches) {
                n.inputs.send(command)
            }
        }

        private func endNotchGesture(_ event: NSEvent) {
            defer { notchGesture = nil }
            guard notchGesture != nil, let n = notchContext() else { return }
            if let command = notchGesture?.ended(atX: point(event).x, at: event.timestamp, notches: n.notches) {
                n.inputs.send(command)
            }
        }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        /// Where an Option press began, so a release after a drag does not switch receivers.
        private var optionDownAt = CGPoint.zero

        override func mouseDown(with event: NSEvent) {
            // A drag that starts on a notch moves it (Control-click is a right click).
            let control = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option)
            if beginNotchGesture(event, button: control ? .right : .left) { return }
            guard let (ctx, _) = context() else { return super.mouseDown(with: event) }
            let p = point(event)
            optionClick = event.modifierFlags.contains(.option)
            optionDownAt = p
            session = optionClick ? nil : SpectrumGestureSession(startX: p.x, startY: p.y, context: ctx)
        }

        override func mouseDragged(with event: NSEvent) {
            if notchGesture != nil { return moveNotchGesture(event) }
            guard let (_, inputs) = context() else { return super.mouseDragged(with: event) }
            guard session != nil else { return }
            if let command = session?.moved(toX: point(event).x, at: event.timestamp) {
                inputs.send(command)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if notchGesture != nil { return endNotchGesture(event) }
            defer { session = nil; optionClick = false }
            guard let (ctx, inputs) = context() else { return super.mouseUp(with: event) }
            let p = point(event)
            if optionClick {
                let moved = hypot(p.x - optionDownAt.x, p.y - optionDownAt.y)
                if moved <= SpectrumGestureModel.dragThresholdPx {
                    inputs.send(SpectrumGestureModel.middleClick(atX: p.x, context: ctx))
                }
            } else if let command = session?.ended(atX: p.x) {
                inputs.send(command)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            if !beginNotchGesture(event, button: .right) { super.rightMouseDown(with: event) }
        }

        override func rightMouseDragged(with event: NSEvent) {
            if notchGesture != nil { moveNotchGesture(event) } else { super.rightMouseDragged(with: event) }
        }

        override func rightMouseUp(with event: NSEvent) {
            if notchGesture != nil { endNotchGesture(event) } else { super.rightMouseUp(with: event) }
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2, let (ctx, inputs) = context() else {
                return super.otherMouseUp(with: event)
            }
            inputs.send(SpectrumGestureModel.middleClick(atX: point(event).x, context: ctx))
        }

        override func scrollWheel(with event: NSEvent) {
            guard let (ctx, inputs) = context(), let display else { return super.scrollWheel(with: event) }
            // Trackpad momentum would keep tuning after the fingers lift.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            let ticks = SpectrumGestureModel.wheelTicks(
                deltaY: Double(event.scrollingDeltaY), deltaX: Double(event.scrollingDeltaX),
                precise: event.hasPreciseScrollingDeltas, accumulator: &scrollAccumulator)
            guard ticks != 0 else { return }
            // The wheel over a notch widens or narrows it and is not a tune.
            if !event.modifierFlags.contains(.command), let n = notchContext(),
               let command = NotchModel.scrollCommand(ticks: ticks, x: point(event).x, notches: n.notches,
                                                      width: n.width, spanHz: n.span,
                                                      accumulator: &notchWidth, now: event.timestamp) {
                inputs.send(command)
                return
            }
            if event.modifierFlags.contains(.command) {
                inputs.send(.setZoom(zoom.next(snapshotZoom: display.zoom,
                                               factor: SpectrumGestureModel.zoomFactor(ticks: ticks),
                                               now: event.timestamp)))
            } else {
                inputs.send(.wheelTune(ctx.receiver, ticks: ticks))
            }
        }

        override func magnify(with event: NSEvent) {
            guard let (_, inputs) = context(), let display else { return super.magnify(with: event) }
            inputs.send(.setZoom(zoom.next(snapshotZoom: display.zoom,
                                           factor: max(0.1, 1 + Double(event.magnification)),
                                           now: event.timestamp)))
        }
    }
}

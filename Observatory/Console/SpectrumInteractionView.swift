import AppKit
import SwiftUI

/// Which pane a gesture surface sits on. Only the spectrum has passband edge handles and a dB scale.
enum SpectrumSurface: Equatable, Sendable { case spectrum, waterfall }

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
    static let edgeHelp = "Drag a passband edge to change the filter, drag the right-edge dB scale to change the range"

    /// The notch gestures' availability on `stack`.
    func notchAvailability(on stack: ReceiverID) -> CapabilityStatus {
        NotchModel.availability(stack: stack, status: notchStatus)
    }

    /// Whether notch gestures work on `stack`'s `surface`. Notches are drawn on the spectrum only,
    /// so the waterfall never hit-tests them (Qt's notch areas live in the spectrum overlay).
    func notchesEnabled(on stack: ReceiverID, surface: SpectrumSurface = .spectrum) -> Bool {
        guard surface == .spectrum else { return false }
        let s = notchAvailability(on: stack)
        return s == .available || s == .mocked
    }

    /// The surface's tooltip: the tuning help (or why tuning is off), then, on the spectrum, the
    /// notch help (or why notches are off here). The waterfall has no notch gestures to describe.
    func help(for stack: ReceiverID, surface: SpectrumSurface = .spectrum) -> String {
        var tuning = disabledReason ?? Self.help
        if disabledReason == nil, surface == .spectrum, stack == .main { tuning += "\n" + Self.edgeHelp }
        guard surface == .spectrum else { return tuning }
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
    /// Passband edge handles and the dB scale exist on the spectrum only.
    var surface: SpectrumSurface = .spectrum
    /// The dB range being drawn: the engine's manual range, or the auto fit while auto is on.
    var shownDbFloor = -130.0
    var shownDbCeiling = -20.0

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.stack = stack
        view.display = display
        view.inputs = inputs
        view.surface = surface
        view.shownDbRange = (shownDbFloor, shownDbCeiling)
        view.toolTip = inputs.help(for: stack, surface: surface)
    }

    final class SurfaceView: NSView {
        var stack: ReceiverID = .main
        var display: DisplaySnapshot?
        var inputs: SpectrumGestureInputs?
        var surface: SpectrumSurface = .spectrum
        var shownDbRange = (floor: -130.0, ceiling: -20.0)

        private var dbDrag: SpectrumDbDrag?
        private var edgeDrag: SpectrumEdgeDrag?
        private var session: SpectrumGestureSession?
        /// A press that began on a notch, or a right press that may add one.
        private var notchGesture: NotchGesture?
        private var notchWidth = NotchWidthScroll()
        /// Bumped by every notch-width scroll, so only the latest trailing flush acts.
        private var notchWidthGeneration = 0
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
        /// gestures are off (Sub stack, the waterfall, `.notches` unavailable) or there is no axis.
        private func notchContext() -> (notches: [NotchInfo], width: Double, span: Double, inputs: SpectrumGestureInputs)? {
            guard let display, let inputs, inputs.notchesEnabled(on: stack, surface: surface) else { return nil }
            let span = Double(display.spanHighHz - display.spanLowHz)
            guard span > 0, bounds.width > 0 else { return nil }
            return (NotchModel.visible(inputs.notches, on: stack), Double(bounds.width), span, inputs)
        }

        /// The passband edge handles' x positions, Main spectrum only (Sub's edges have no write
        /// path, and the waterfall has no handles). Nil while TX owns the axis or there is no axis.
        private func edgeXs() -> (lo: Double, hi: Double)? {
            guard stack == .main, surface == .spectrum, let (display, _) = live, !display.txAxis else { return nil }
            let span = Double(display.spanHighHz - display.spanLowHz)
            guard span > 0, bounds.width > 0 else { return nil }
            let centre = Double(display.spanLowHz + display.spanHighHz) / 2
            func x(_ hz: Int64) -> Double { (Double(hz) - centre) / span * Double(bounds.width) + Double(bounds.width) / 2 }
            return (x(display.mainPassband.lowerBound), x(display.mainPassband.upperBound))
        }

        /// What a press at `p` grabs, in controller ruling R1's order: dB scale, passband edge,
        /// notch, then tune.
        private func hitTarget(at p: CGPoint) -> SpectrumHitTarget {
            let n = notchContext()
            let width = Double(bounds.width)
            let span = n?.span ?? display.map { Double($0.spanHighHz - $0.spanLowHz) } ?? 0
            return SpectrumGestureModel.hitTarget(
                x: p.x, y: p.y, notches: n?.notches ?? [], width: width, spanHz: span,
                notchesEnabled: n != nil, height: Double(bounds.height),
                dbZoneEnabled: SpectrumGestureModel.grabsEnabled(stack: stack, surface: surface, live: live != nil,
                                                                 txAxis: display?.txAxis ?? true),
                edges: edgeXs())
        }

        /// Starts a dB-scale or passband-edge drag when a plain left press lands on one.
        private func beginGrab(_ target: SpectrumHitTarget, at p: CGPoint) -> Bool {
            guard let (display, inputs) = live else { return false }
            switch target {
            case .dbScale(let zone):
                var drag = SpectrumDbDrag(zone: zone, startY: p.y, shownFloor: shownDbRange.floor,
                                          shownCeiling: shownDbRange.ceiling, auto: display.dbRange.auto)
                for command in drag.beginCommands { inputs.send(command) }
                dbDrag = drag
                return true
            case .edge(let edge):
                let span = Double(display.spanHighHz - display.spanLowHz)
                edgeDrag = SpectrumEdgeDrag(edge: edge, width: Double(bounds.width), spanHz: span)
                return true
            case .notch, .tune:
                return false
            }
        }

        /// Starts a notch gesture when a left press landed on a notch (`target`) or a right press
        /// may add one.
        private func beginNotchGesture(_ event: NSEvent, button: NotchGesture.Button,
                                       target: SpectrumHitTarget? = nil) -> Bool {
            guard let n = notchContext() else { return false }
            if button == .left {
                guard case .notch? = target else { return false }
            }
            notchGesture = NotchGesture(button: button, x: point(event).x, notches: n.notches,
                                        width: n.width, spanHz: n.span)
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

        /// The live inputs while a dB or edge grab may go on. Once TX owns the axis (or the surface
        /// is no longer live) the grab ends with no further command: the drag was seeded from the
        /// RX range, and `Prefs` would write it into the live TX pair (Review Focus 5).
        private func grabInputs() -> SpectrumGestureInputs? {
            guard let (display, inputs) = live,
                  SpectrumGestureModel.grabsEnabled(stack: stack, surface: surface, live: true,
                                                    txAxis: display.txAxis) else {
                dbDrag = nil
                edgeDrag = nil
                return nil
            }
            return inputs
        }

        private func moveGrab(_ event: NSEvent) {
            guard let inputs = grabInputs() else { return }
            let p = point(event)
            let command = dbDrag != nil
                ? dbDrag?.moved(toY: p.y, height: Double(bounds.height), at: event.timestamp)
                : edgeDrag?.moved(toX: p.x, at: event.timestamp)
            if let command { inputs.send(command) }
        }

        /// The release flushes what the throttle held back.
        private func endGrab(_ event: NSEvent) {
            defer { dbDrag = nil; edgeDrag = nil }
            guard let inputs = grabInputs() else { return }
            let p = point(event)
            let command = dbDrag != nil
                ? dbDrag?.ended(atY: p.y, height: Double(bounds.height))
                : edgeDrag?.ended(atX: p.x)
            if let command { inputs.send(command) }
        }

        // MARK: Hover cursor

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            switch hitTarget(at: point(event)) {
            case .edge: NSCursor.resizeLeftRight.set()
            case .dbScale: NSCursor.resizeUpDown.set()
            case .notch, .tune: NSCursor.arrow.set()
            }
        }

        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        /// Where an Option press began, so a release after a drag does not switch receivers.
        private var optionDownAt = CGPoint.zero

        override func mouseDown(with event: NSEvent) {
            // A drag that starts on a notch moves it (Control-click is a right click).
            let control = event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option)
            let option = event.modifierFlags.contains(.option)
            let target = hitTarget(at: point(event))
            // The dB scale and the passband edges come before notches and tuning (R1); an Option
            // press always reaches the focus toggle below.
            switch SpectrumGestureModel.pressRoute(target: target, control: control, option: option) {
            case .grab:
                if beginGrab(target, at: point(event)) { return }
            case .notch(let button):
                if beginNotchGesture(event, button: button, target: target) { return }
            case .tune:
                break
            }
            guard let (ctx, _) = context() else { return super.mouseDown(with: event) }
            let p = point(event)
            optionClick = event.modifierFlags.contains(.option)
            optionDownAt = p
            session = optionClick ? nil : SpectrumGestureSession(startX: p.x, startY: p.y, context: ctx)
        }

        override func mouseDragged(with event: NSEvent) {
            if dbDrag != nil || edgeDrag != nil { return moveGrab(event) }
            if notchGesture != nil { return moveNotchGesture(event) }
            guard let (_, inputs) = context() else { return super.mouseDragged(with: event) }
            guard session != nil else { return }
            if let command = session?.moved(toX: point(event).x, at: event.timestamp) {
                inputs.send(command)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if dbDrag != nil || edgeDrag != nil { return endGrab(event) }
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

        /// Sends the notch widths the scroll throttle held back (H14's final value).
        private func flushNotchWidths() {
            guard let n = notchContext() else { return }
            for command in notchWidth.flush(notches: n.notches, now: ProcessInfo.processInfo.systemUptime) {
                n.inputs.send(command)
            }
        }

        /// A discrete wheel has no end phase: flush shortly after the last notch-width tick.
        private func scheduleNotchWidthFlush() {
            notchWidthGeneration += 1
            let generation = notchWidthGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.notchWidthGeneration == generation else { return }
                self.flushNotchWidths()
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let (ctx, inputs) = context(), let display else { return super.scrollWheel(with: event) }
            // Trackpad momentum would keep tuning after the fingers lift; its end (like the
            // fingers' own end) sends any notch width still held.
            guard event.momentumPhase.isEmpty else {
                if event.momentumPhase.contains(.ended) { flushNotchWidths() }
                return
            }
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { flushNotchWidths() }
            let ticks = SpectrumGestureModel.wheelTicks(
                deltaY: Double(event.scrollingDeltaY), deltaX: Double(event.scrollingDeltaX),
                precise: event.hasPreciseScrollingDeltas, accumulator: &scrollAccumulator)
            guard ticks != 0 else { return }
            // The wheel over a notch widens or narrows it and is not a tune; writes are throttled
            // per notch (H14).
            if !event.modifierFlags.contains(.command), let n = notchContext() {
                let result = notchWidth.scrolled(ticks: ticks, x: point(event).x, notches: n.notches,
                                                 width: n.width, spanHz: n.span, now: event.timestamp)
                if result.consumed {
                    if let command = result.command { inputs.send(command) }
                    scheduleNotchWidthFlush()
                    return
                }
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

import AppKit
import SwiftUI

/// Behaviour shared by the dial and slider: arrow keys (Shift = coarse), scroll wheel with
/// sub-step accumulation (Option = fine), double-click reset, accessibility and tooltip.
struct LyraValueControl: ViewModifier {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let defaultValue: Double?
    let readout: String

    @State private var scrollRemainder = 0.0

    func body(content: Content) -> some View {
        content
            .focusable()
            .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                let up = press.key == .upArrow || press.key == .rightArrow
                value = ControlMath.nudged(value, in: range, step: step, up: up,
                                           coarse: press.modifiers.contains(.shift))
                return .handled
            }
            // Simultaneous so a zero-distance drag (slider) cannot swallow the double-click.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let defaultValue {
                    withAnimation(LyraDS.Motion.standard) {
                        value = ControlMath.clamp(defaultValue, to: range)
                    }
                }
            })
            .overlay(ScrollWheelCapture { dy in
                value = ControlMath.scrollAdjusted(
                    value, remainder: &scrollRemainder, deltaPoints: dy, in: range, step: step,
                    fine: NSEvent.modifierFlags.contains(.option))
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(readout)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    value = ControlMath.nudged(value, in: range, step: step, up: true, coarse: false)
                case .decrement:
                    value = ControlMath.nudged(value, in: range, step: step, up: false, coarse: false)
                @unknown default: break
                }
            }
            .help("\(label): \(readout)")
    }
}

// MARK: - Scroll wheel support (shared with LyraSlider)

/// Transparent overlay that reports scroll-wheel deltas for events over its bounds.
/// It never takes hit-testing, so clicks and drags pass through to the control below.
struct ScrollWheelCapture: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let v = ScrollWheelNSView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelNSView: NSView {
    var onScroll: ((Double) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let p = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(p) else { return event }
            // Mouse wheels report coarse "line" deltas; scale them up to trackpad-like points.
            let dy = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8)
            self.onScroll?(dy)
            return nil
        }
    }
}

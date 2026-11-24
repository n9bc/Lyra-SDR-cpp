import SwiftUI

/// Compact console slider row from the mockup: 54 pt label, flexible track, 58 pt monospaced value.
/// Wraps a SwiftUI `Slider` tinted from tokens; `dimmed` mutes the tint and value (stays interactive).
struct ConsoleSliderRow: View {
    let label: String
    let help: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    var tint: Color = LyraDS.Palette.cyan
    var dimmed: Bool = false
    /// Backend availability; an unavailable slider is disabled and its one tooltip is the reason.
    var status: CapabilityStatus = .available
    /// Called with true when a drag starts and false when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LyraDS.Palette.textMuted)
                .lineLimit(1)
                .frame(width: 54, alignment: .leading)
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .tint(dimmed ? LyraDS.Palette.textDim : tint)
                .accessibilityLabel(help)
                .accessibilityValue(readout)
                .disabled(ConsoleAvailability.isDisabled(status))
                .help(ConsoleAvailability.help(status, normal: help))
            Text(readout)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(dimmed ? LyraDS.Palette.chipDimText : LyraDS.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

/// A slider that shows the engine's value, sends at most one write per 33 ms (map H14) and always
/// gets the final value to the engine. While a drag is live the thumb follows the pointer, since
/// the engine's confirmation arrives a tick later; afterwards it is the snapshot's value again.
/// A change with no drag around it (VoiceOver increment, Full Keyboard Access) gets no
/// editing-ended callback, so a trailing flush sends what the throttle held and drops the local
/// value (`ThrottledSliderState`).
struct ConsoleThrottledSliderRow: View {
    let label: String
    let help: String
    /// The engine's value, from the snapshot.
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: (Double) -> String
    var tint: Color = LyraDS.Palette.cyan
    var dimmed: Bool = false
    var status: CapabilityStatus = .available
    let send: (Double) -> Void

    @State private var state = ThrottledSliderState()

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        let shown = state.shown(engine: value)
        ConsoleSliderRow(
            label: label, help: help,
            value: Binding(
                get: { state.shown(engine: value) },
                set: { new in
                    let r = state.set(new, now: Self.now)
                    if let out = r.send { send(out) }
                    if let generation = r.trailing { scheduleTrailingFlush(generation) }
                }),
            range: range, step: step, readout: readout(shown), tint: tint, dimmed: dimmed, status: status,
            onEditingChanged: { editing in
                if let out = state.editingChanged(editing, now: Self.now) { send(out) }
            })
    }

    private func scheduleTrailingFlush(_ generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: ThrottledSliderState.trailingDelay)
            if let out = state.trailingFlush(generation: generation, now: Self.now) { send(out) }
        }
    }
}

/// The write side of a throttled slider, pure and clock-injected. During a mouse drag (between
/// the editing callbacks) the local value follows the pointer and the release flushes. Outside a
/// drag every change schedules a trailing flush (`trailing` is its generation): only the newest
/// one acts, sending whatever the throttle held and dropping the local value, so the thumb shows
/// the engine's value again.
struct ThrottledSliderState: Sendable {
    /// Longer than the 33 ms throttle, so the flush never comes sooner than a send would.
    nonisolated static let trailingDelay: Duration = .milliseconds(40)

    private var throttle = WriteThrottle<Double>()
    private var local: Double?
    private var tracking = false
    private var generation = 0

    nonisolated init() {}

    /// What the thumb and readout show: the local value while one is pending, else the engine's.
    nonisolated func shown(engine: Double) -> Double { local ?? engine }

    /// A change from the slider: the value to send now, if any, and the generation of the
    /// trailing flush to schedule (nil during a drag).
    nonisolated mutating func set(_ v: Double, now: TimeInterval) -> (send: Double?, trailing: Int?) {
        local = v
        let out = throttle.offer(v, now: now)
        guard !tracking else { return (out, nil) }
        generation += 1
        return (out, generation)
    }

    /// The editing callback: a drag starting, or ending (the value the throttle held, to send).
    nonisolated mutating func editingChanged(_ editing: Bool, now: TimeInterval) -> Double? {
        tracking = editing
        guard !editing else { return nil }
        local = nil
        return throttle.flush(now: now)
    }

    /// The trailing flush for `generation`: the held value, if any, once no newer change and no
    /// drag has taken over; the local value is dropped either way.
    nonisolated mutating func trailingFlush(generation g: Int, now: TimeInterval) -> Double? {
        guard g == generation, !tracking else { return nil }
        local = nil
        return throttle.flush(now: now)
    }
}

/// Chip-styled pop-up menu (mockup `.sel`): current value plus a chevron.
struct ConsoleMenuChip: View {
    let label: String
    let help: String
    let options: [String]
    @Binding var selection: String
    /// Backend availability; an unavailable menu is disabled and its one tooltip is the reason.
    var status: CapabilityStatus = .available
    /// Called with the chosen row's position, for lists whose names can repeat.
    var onSelectIndex: ((Int) -> Void)?

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button(option) {
                    selection = option
                    onSelectIndex?(index)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ConsoleChipButtonStyle(.plain))
        .fixedSize()
        .accessibilityLabel(help)
        .accessibilityValue(selection)
        .disabled(ConsoleAvailability.isDisabled(status))
        .help(ConsoleAvailability.help(status, normal: help))
    }
}

/// Chip with an accessibility label and help; the action is empty in Milestone 1 unless supplied.
struct ConsoleChip: View {
    let title: String
    let help: String
    var kind: ConsoleChipStyle = .plain
    var height: CGFloat = 26
    var fullWidth = false
    /// Backend availability; an unavailable chip is disabled and its one tooltip is the reason.
    var status: CapabilityStatus = .available
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title).minimumScaleFactor(0.7)
        }
        .buttonStyle(ConsoleChipButtonStyle(kind, height: height, fullWidth: fullWidth))
        .disabled(ConsoleAvailability.isDisabled(status))
        .accessibilityLabel(help)
        .help(ConsoleAvailability.help(status, normal: help))
    }
}

/// 7 pt status lamp with glow.
struct ConsoleLamp: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: color, radius: 3)
            .accessibilityHidden(true)
    }
}

/// Uniform flexible-column chip grid with 5 pt gaps.
func consoleColumns(_ count: Int) -> [GridItem] {
    Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5), count: count)
}

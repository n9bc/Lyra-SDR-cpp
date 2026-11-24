import SwiftUI

/// The decision behind every gated control, kept pure so it can be tested.
enum ConsoleAvailability {
    /// The reason every transmit-owned control shows until Milestone 5b wires transmit.
    nonisolated static let transmitReason = "Arrives with transmit (Milestone 5b)"

    /// Only an unavailable control is disabled; mocked controls stay usable (they are
    /// labelled as sample data elsewhere).
    nonisolated static func isDisabled(_ status: CapabilityStatus) -> Bool {
        if case .unavailable = status { return true }
        return false
    }

    /// The single tooltip a control shows: the reason when unavailable, otherwise `normal`.
    nonisolated static func help(_ status: CapabilityStatus, normal: String) -> String {
        if case .unavailable(let reason) = status { return reason }
        return normal
    }
}

extension View {
    /// Disables the control when unavailable and sets its one tooltip. Use only on views that
    /// do not set their own `.help` (chips take a `status` instead).
    func consoleAvailability(_ status: CapabilityStatus, help: String) -> some View {
        self.disabled(ConsoleAvailability.isDisabled(status))
            .help(ConsoleAvailability.help(status, normal: help))
    }
}

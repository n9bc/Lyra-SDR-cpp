import SwiftUI

extension View {
    /// Disables the control and shows the reason as its tooltip when the backend marks it
    /// unavailable; otherwise shows `help`. Mocked controls stay enabled (they are labelled
    /// as sample data elsewhere).
    @ViewBuilder
    func consoleAvailability(_ status: CapabilityStatus, help: String) -> some View {
        if case .unavailable(let reason) = status {
            self.disabled(true).help(reason)
        } else {
            self.help(help)
        }
    }
}

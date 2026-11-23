// ObservatoryHost — @objc entry point called from ObservatoryWindow.mm to
// create the SwiftUI NSHostingView for the native console.

import SwiftUI
import AppKit

@MainActor
@objc public class ObservatoryHost: NSObject {
    /// Creates the SwiftUI hosting view for the Observatory window.
    ///
    /// Called from Obj-C++ (`ObservatoryWindow.mm`). Milestone 1 shows the static
    /// console on sample data; Milestone 3 wires the facade into a live backend.
    @objc public static func createHostingView(facade: LyraEngineFacade) -> NSView {
        _ = facade
        return NSHostingView(rootView: ConsoleView(backend: MockRadioBackend()))
    }
}

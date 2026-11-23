// ObservatoryHost — @objc entry point called from ObservatoryWindow.mm to
// create the SwiftUI NSHostingView for the native console.

import SwiftUI
import AppKit

@MainActor
@objc public class ObservatoryHost: NSObject {
    /// The console's menus and window rules; lives for the app's lifetime.
    private static var shell: ConsoleShell?

    /// Creates the SwiftUI hosting view for the Observatory window.
    ///
    /// Called from Obj-C++ (`ObservatoryWindow.mm`). Milestone 2 runs the console on sample
    /// data; Milestone 3 wires the facade into a live backend.
    @objc public static func createHostingView(facade: LyraEngineFacade) -> NSView {
        _ = facade
        let shell = ConsoleShell(backend: MockRadioBackend(), display: DisplayStore())
        Self.shell = shell
        return NSHostingView(rootView: ConsoleView(backend: shell.backend, displayStore: shell.display)
            .background(ConsoleWindowAttachment { shell.attach($0) }))
    }
}

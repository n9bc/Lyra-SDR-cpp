// ObservatoryHost — @objc entry point called from ObservatoryWindow.mm to
// create the SwiftUI NSHostingView for the native console.

import SwiftUI
import AppKit

@MainActor
@objc public class ObservatoryHost: NSObject {
    /// The console's menus and window rules; lives for the app's lifetime.
    private static var shell: ConsoleShell?
    /// Quits the app when the console window closes.
    private static var facade: LyraEngineFacade?
    private static var closeObserver: NSObjectProtocol?

    /// Creates the SwiftUI hosting view for the Observatory window.
    ///
    /// Called from Obj-C++ (`ObservatoryWindow.mm`). The console runs on the live engine through
    /// the facade; `LYRA_CONSOLE_SAMPLE=1` runs it on sample data instead.
    @objc public static func createHostingView(facade: LyraEngineFacade) -> NSView {
        Self.facade = facade
        let backend: any RadioBackend
        if ProcessInfo.processInfo.environment["LYRA_CONSOLE_SAMPLE"] == "1" {
            backend = MockRadioBackend()
        } else {
            let live = LiveRadioBackend(facade: facade)
            backend = live
            // Next runloop turn: main.cpp attaches the host window right after this returns,
            // and the connect goes through it.
            DispatchQueue.main.async { live.connectOnLaunchIfEnabled() }
        }
        let openSettings: @MainActor () -> Void = { Self.facade?.openSettings() }
        let shell = ConsoleShell(backend: backend, display: DisplayStore(), openSettings: openSettings)
        Self.shell = shell
        return NSHostingView(rootView: ConsoleView(backend: shell.backend, displayStore: shell.display,
                                                   openSettings: openSettings)
            .background(ConsoleWindowAttachment { window in
                shell.attach(window)
                Self.quitWhenClosed(window)
            }))
    }

    /// The console is the app's only visible window, so closing it quits.
    private static func quitWhenClosed(_ window: NSWindow) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.facade?.quitApplication() }
        }
    }
}

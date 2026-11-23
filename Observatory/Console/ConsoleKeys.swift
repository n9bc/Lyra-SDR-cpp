import SwiftUI
import AppKit

/// The arrow keys the console tunes with.
enum ConsoleKey: Equatable {
    case left, right, up, down

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        default: return nil
        }
    }
}

/// Maps a key press to a radio command (spec §5.6): arrows tune the focused receiver.
enum ConsoleKeyMap {
    /// Modifiers that make an arrow press someone else's shortcut. `.function`, `.numericPad`
    /// and `.capsLock` are ignored: macOS sets the first two on every arrow key.
    nonisolated static let blockingModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    nonisolated static func command(for key: ConsoleKey, modifiers: NSEvent.ModifierFlags,
                                    snapshot: RadioSnapshot, textInputActive: Bool) -> RadioCommand? {
        guard !textInputActive, !snapshot.session.vfoLocked,
              modifiers.intersection(blockingModifiers).isEmpty else { return nil }
        let delta: Int64
        switch key {
        case .left: delta = -1_000
        case .right: delta = 1_000
        case .down: delta = -10
        case .up: delta = 10
        }
        return .tune(snapshot.session.focused, deltaHz: delta)
    }
}

/// Installs a local key-down monitor while its view is in a window, and routes arrow keys
/// through `ConsoleKeyMap`. Consumes an event only when a command was sent.
struct ConsoleKeyMonitor: NSViewRepresentable {
    let snapshot: () -> RadioSnapshot
    let send: (RadioCommand) -> Void

    init(snapshot: @escaping () -> RadioSnapshot, send: @escaping (RadioCommand) -> Void) {
        self.snapshot = snapshot
        self.send = send
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.snapshot = snapshot
        view.send = send
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.snapshot = snapshot
        view.send = send
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        MainActor.assumeIsolated { view.removeMonitor() }
    }

    final class MonitorView: NSView {
        var snapshot: (() -> RadioSnapshot)?
        var send: ((RadioCommand) -> Void)?
        private var token: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let consumed = MainActor.assumeIsolated { self.handle(event) }
                return consumed ? nil : event
            }
        }

        func removeMonitor() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }

        /// True when the event became a command and must not reach the responder chain.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  let key = ConsoleKey(keyCode: event.keyCode),
                  let snapshot, let send else { return false }
            let textActive = window.firstResponder is NSText
            guard let command = ConsoleKeyMap.command(for: key, modifiers: event.modifierFlags,
                                                      snapshot: snapshot(), textInputActive: textActive)
            else { return false }
            send(command)
            return true
        }
    }
}

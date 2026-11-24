import SwiftUI
import AppKit

/// Where the console window opens and how a remembered frame is brought back on screen.
enum WindowFrameRules {
    /// Defaults key holding the console window's last frame (`NSStringFromRect`).
    nonisolated static let autosaveName = "LyraConsoleWindow"
    nonisolated static let defaultContentSize = CGSize(width: 1600, height: 1100)

    /// First-launch content size: the default, shrunk to the screen, never below the minimum.
    nonisolated static func initialContentSize(visible: CGSize) -> CGSize {
        let minimum = ConsoleLayout.minWindow
        return CGSize(width: max(minimum.width, min(defaultContentSize.width, visible.width)),
                      height: max(minimum.height, min(defaultContentSize.height, visible.height)))
    }

    /// The screen (index into `visibles`) holding the largest part of `frame`, or nil when the
    /// frame is on no current screen (its display was disconnected).
    nonisolated static func screenIndex(for frame: CGRect, among visibles: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, visible) in visibles.enumerated() {
            let overlap = frame.intersection(visible)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }

    /// `frame` sized to fit `visible` (but never below `minSize`) and moved inside it. A window
    /// wider than the screen starts at its left edge; one taller than the screen is top-aligned,
    /// so the title bar stays reachable.
    nonisolated static func clamp(_ frame: CGRect, into visible: CGRect, minSize: CGSize) -> CGRect {
        let width = max(minSize.width, min(frame.width, visible.width))
        let height = max(minSize.height, min(frame.height, visible.height))
        let x = width > visible.width
            ? visible.minX
            : min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = height > visible.height
            ? visible.maxY - height
            : min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Suspends the spectrum pump while its window is not visible at all (fully covered, minimised or
/// on another Space), per `NSWindow.occlusionState`, so the console stops pulling frames nobody
/// can see. The engine's analyzer keeps running; only the console's pulls stop.
@MainActor
final class SpectrumOcclusionGate {
    private let pump: SpectrumPump
    private weak var window: NSWindow?
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(pump: SpectrumPump) { self.pump = pump }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Follows `window`'s occlusion from now on (once per window).
    func watch(_ window: NSWindow) {
        guard window !== self.window else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.window = window
        apply(window.occlusionState)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.apply(window.occlusionState)
            }
        }
    }

    private func apply(_ state: NSWindow.OcclusionState) {
        pump.isSuspended = Self.suspends(state)
    }

    /// Any visible part keeps the pump running.
    nonisolated static func suspends(_ state: NSWindow.OcclusionState) -> Bool {
        !state.contains(.visible)
    }
}

/// Reports the `NSWindow` its view joins, once per window, so AppKit-only setup (menus,
/// frame autosave) can run without touching the code that created the window.
struct ConsoleWindowAttachment: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void) {
        self.onAttach = onAttach
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        view.onAttach = onAttach
    }

    final class AttachmentView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        private weak var attachedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== attachedWindow else { return }
            attachedWindow = window
            onAttach?(window)
        }
    }
}

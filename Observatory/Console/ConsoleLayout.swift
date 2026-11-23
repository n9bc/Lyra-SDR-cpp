import CoreGraphics

/// Fixed region sizes for the native console. Minimum window content is 1280x800;
/// the display area absorbs extra space and side columns scroll when short.
enum ConsoleLayout {
    nonisolated static let minWindow = CGSize(width: 1280, height: 800)
    nonisolated static let topBarHeight: CGFloat = 46
    nonisolated static let vfoRowHeight: CGFloat = 212
    nonisolated static let vfoCenterWidth: CGFloat = 190
    nonisolated static let sideColumnWidth: CGFloat = 300
    nonisolated static let txDeckHeight: CGFloat = 122
    nonisolated static let statusBarHeight: CGFloat = 26
    nonisolated static let gap: CGFloat = 8
    nonisolated static let minDisplayWidth: CGFloat = 640
    nonisolated static let minBodyHeight: CGFloat = 330

    /// Minimum content width: both side columns, the display, and 4 gaps.
    nonisolated static var minWidth: CGFloat { 2 * sideColumnWidth + minDisplayWidth + 4 * gap }

    /// Minimum content height: the five stacked regions plus 4 gaps.
    nonisolated static var minHeight: CGFloat {
        topBarHeight + vfoRowHeight + txDeckHeight + statusBarHeight + minBodyHeight + 4 * gap
    }

    /// True when `size` can hold every fixed region without clipping.
    nonisolated static func fits(_ size: CGSize) -> Bool {
        size.width >= minWidth && size.height >= minHeight
    }
}

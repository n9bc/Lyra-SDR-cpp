import SwiftUI

/// Sidebar/grouping category for a panel.
enum PanelCategory: String, CaseIterable, Codable {
    case receive, transmit, bands, tools
}

/// A dockable Observatory panel. Conformers are registered with `PanelRegistry`.
protocol LyraPanel: Identifiable, Hashable {
    var id: String { get }
    var title: String { get }
    var systemImage: String { get }
    var category: PanelCategory { get }
    var defaultVisible: Bool { get }
    // Swift does not allow `some View` as a protocol requirement; an associated type is the
    // equivalent spelling. Conformers still write `var content: some View`.
    associatedtype Content: View
    @ViewBuilder var content: Content { get }
}

extension LyraPanel {
    // Identity is the panel ID; two panels with the same ID are the same panel.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

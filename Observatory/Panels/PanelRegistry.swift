import AppKit
import Foundation
import Observation

/// A saved arrangement of visible panels.
struct PanelLayout: Codable, Equatable {
    var name: String
    var visiblePanelIDs: Set<String>
    var selectedPanelID: String?
    /// Every panel registered when the layout was captured, so a hidden panel can be told
    /// apart from one added later. nil for layouts saved before this field existed.
    var knownPanelIDs: Set<String>?
}

enum PanelLayoutError: Error, Equatable {
    case reservedName(String)
    case slotsFull(limit: Int)
}

/// Tracks registered panels, which are visible, and persists layouts to UserDefaults.
///
/// Persistence: the live layout is auto-saved on `willTerminateNotification` and
/// auto-restored as panels register at launch. Up to `maxOperatorSlots` named
/// layouts can be stored; "factory" is derived from each panel's `defaultVisible`
/// and is always recallable.
@MainActor
@Observable
final class PanelRegistry {
    static let factoryLayoutName = "factory"
    static let maxOperatorSlots = 4

    private(set) var panels: [any LyraPanel] = []
    private(set) var visiblePanelIDs: Set<String> = []
    var selectedPanelID: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingLayout: PanelLayout?
    @ObservationIgnored nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    private static let currentKey = "observatory.layout.current"
    private static let slotsKey = "observatory.layout.slots"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pendingLayout = Self.decode(PanelLayout.self, defaults.data(forKey: Self.currentKey))
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCurrentLayout() }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    // MARK: Registration and visibility

    func register(_ panel: some LyraPanel) {
        guard !panels.contains(where: { $0.id == panel.id }) else { return }
        panels.append(panel)
        if let pending = pendingLayout {
            // Auto-restore: the last session's layout decides visibility. IDs it lists
            // that never register are simply never consulted (silently dropped).
            if pending.visiblePanelIDs.contains(panel.id) { visiblePanelIDs.insert(panel.id) }
            if selectedPanelID == nil, pending.selectedPanelID == panel.id {
                selectedPanelID = panel.id
            }
            // Panels added since the layout was saved have no stored state: use their default.
            if let known = pending.knownPanelIDs, !known.contains(panel.id), panel.defaultVisible {
                visiblePanelIDs.insert(panel.id)
            }
        } else if panel.defaultVisible {
            visiblePanelIDs.insert(panel.id)
        }
    }

    func isVisible(_ id: String) -> Bool { visiblePanelIDs.contains(id) }

    func toggleVisibility(_ id: String) {
        guard panels.contains(where: { $0.id == id }) else { return }
        if visiblePanelIDs.contains(id) { visiblePanelIDs.remove(id) } else { visiblePanelIDs.insert(id) }
        pendingLayout = nil
    }

    func panelsForCategory(_ category: PanelCategory) -> [any LyraPanel] {
        panels.filter { $0.category == category }
    }

    // MARK: Layouts

    /// Hardcoded-by-definition default: every panel that opts in via `defaultVisible`.
    var factoryLayout: PanelLayout {
        PanelLayout(name: Self.factoryLayoutName,
                    visiblePanelIDs: Set(panels.filter(\.defaultVisible).map(\.id)),
                    selectedPanelID: nil)
    }

    var currentLayout: PanelLayout {
        PanelLayout(name: "current", visiblePanelIDs: visiblePanelIDs, selectedPanelID: selectedPanelID,
                    knownPanelIDs: Set(panels.map(\.id)))
    }

    var savedLayoutNames: [String] { loadSlots().keys.sorted() }

    /// Applies a layout, silently dropping IDs that are not registered in this build.
    func applyLayout(_ layout: PanelLayout) {
        let known = Set(panels.map(\.id))
        visiblePanelIDs = layout.visiblePanelIDs.intersection(known)
        selectedPanelID = layout.selectedPanelID.flatMap { known.contains($0) ? $0 : nil }
        pendingLayout = nil
    }

    /// Saves the current arrangement into a named operator slot (max 4).
    func saveLayout(named name: String) throws {
        guard name != Self.factoryLayoutName else { throw PanelLayoutError.reservedName(name) }
        var slots = loadSlots()
        if slots[name] == nil, slots.count >= Self.maxOperatorSlots {
            throw PanelLayoutError.slotsFull(limit: Self.maxOperatorSlots)
        }
        var layout = currentLayout
        layout.name = name
        slots[name] = layout
        if let data = try? JSONEncoder().encode(slots) { defaults.set(data, forKey: Self.slotsKey) }
    }

    /// Restores a named slot or "factory". Returns false if no such layout exists.
    @discardableResult
    func restoreLayout(named name: String) -> Bool {
        if name == Self.factoryLayoutName {
            applyLayout(factoryLayout)
            return true
        }
        guard let layout = loadSlots()[name] else { return false }
        applyLayout(layout)
        return true
    }

    /// Persists the live layout for auto-restore on next launch.
    func saveCurrentLayout() {
        if let data = try? JSONEncoder().encode(currentLayout) { defaults.set(data, forKey: Self.currentKey) }
    }

    // MARK: Private

    private func loadSlots() -> [String: PanelLayout] {
        Self.decode([String: PanelLayout].self, defaults.data(forKey: Self.slotsKey)) ?? [:]
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

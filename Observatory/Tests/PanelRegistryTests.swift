import SwiftUI
import XCTest
@testable import Observatory

struct StubPanel: LyraPanel {
    let id: String
    var title: String { id }
    var systemImage: String { "circle" }
    let category: PanelCategory
    var defaultVisible: Bool = true
    var content: some View { Text(id) }

    init(id: String, category: PanelCategory, defaultVisible: Bool = true) {
        self.id = id
        self.category = category
        self.defaultVisible = defaultVisible
    }
}

@MainActor
final class PanelRegistryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PanelRegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeRegistry() -> PanelRegistry {
        PanelRegistry(defaults: defaults)
    }

    func testRegisterAndRetrieve() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "test", category: .receive))
        XCTAssertEqual(registry.panels.count, 1)
        XCTAssertTrue(registry.isVisible("test"))
    }

    func testToggleVisibility() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "test", category: .receive, defaultVisible: true))
        XCTAssertTrue(registry.isVisible("test"))
        registry.toggleVisibility("test")
        XCTAssertFalse(registry.isVisible("test"))
        registry.toggleVisibility("test")
        XCTAssertTrue(registry.isVisible("test"))
    }

    func testNonDefaultVisiblePanelStartsHidden() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "hidden", category: .tools, defaultVisible: false))
        XCTAssertFalse(registry.isVisible("hidden"))
    }

    func testPanelsForCategory() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "a", category: .receive))
        registry.register(StubPanel(id: "b", category: .transmit))
        registry.register(StubPanel(id: "c", category: .receive))
        XCTAssertEqual(registry.panelsForCategory(.receive).map(\.id), ["a", "c"])
        XCTAssertEqual(registry.panelsForCategory(.bands).count, 0)
    }

    func testRegisterIgnoresDuplicateID() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "a", category: .receive))
        registry.register(StubPanel(id: "a", category: .tools))
        XCTAssertEqual(registry.panels.count, 1)
    }

    func testRestoreLayoutSkipsUnknownPanels() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "spectrum", category: .receive))
        let layout = PanelLayout(name: "test",
                                 visiblePanelIDs: ["spectrum", "nonexistent"],
                                 selectedPanelID: "nonexistent")
        registry.applyLayout(layout)
        XCTAssertTrue(registry.isVisible("spectrum"))
        XCTAssertFalse(registry.visiblePanelIDs.contains("nonexistent"))
        XCTAssertNil(registry.selectedPanelID)
    }

    func testSaveAndRestoreNamedLayout() throws {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "a", category: .receive))
        registry.register(StubPanel(id: "b", category: .receive))
        registry.selectedPanelID = "a"
        registry.toggleVisibility("b")
        try registry.saveLayout(named: "slot1")
        registry.toggleVisibility("b")
        registry.selectedPanelID = nil
        XCTAssertTrue(registry.restoreLayout(named: "slot1"))
        XCTAssertEqual(registry.visiblePanelIDs, ["a"])
        XCTAssertEqual(registry.selectedPanelID, "a")
    }

    func testRestoreMissingLayoutReturnsFalse() {
        XCTAssertFalse(makeRegistry().restoreLayout(named: "nope"))
    }

    func testSavedLayoutWithUnknownIDsRestoresWithoutCrash() throws {
        let first = makeRegistry()
        first.register(StubPanel(id: "a", category: .receive))
        first.register(StubPanel(id: "gone", category: .receive))
        try first.saveLayout(named: "slot1")

        let second = makeRegistry()
        second.register(StubPanel(id: "a", category: .receive))
        XCTAssertTrue(second.restoreLayout(named: "slot1"))
        XCTAssertEqual(second.visiblePanelIDs, ["a"])
    }

    func testFactoryLayoutRecallable() {
        let registry = makeRegistry()
        registry.register(StubPanel(id: "a", category: .receive, defaultVisible: true))
        registry.register(StubPanel(id: "b", category: .tools, defaultVisible: false))
        registry.toggleVisibility("a")
        registry.toggleVisibility("b")
        XCTAssertTrue(registry.restoreLayout(named: PanelRegistry.factoryLayoutName))
        XCTAssertEqual(registry.visiblePanelIDs, ["a"])
    }

    func testFactoryLayoutCannotBeOverwritten() {
        let registry = makeRegistry()
        XCTAssertThrowsError(try registry.saveLayout(named: PanelRegistry.factoryLayoutName))
    }

    func testOperatorSlotLimitIsFour() throws {
        let registry = makeRegistry()
        for i in 1...4 { try registry.saveLayout(named: "slot\(i)") }
        XCTAssertThrowsError(try registry.saveLayout(named: "slot5"))
        // Overwriting an existing slot is allowed.
        XCTAssertNoThrow(try registry.saveLayout(named: "slot1"))
        XCTAssertEqual(registry.savedLayoutNames.count, 4)
    }

    func testCurrentLayoutPersistsAndAutoRestoresOnRegister() {
        let first = makeRegistry()
        first.register(StubPanel(id: "a", category: .receive))
        first.register(StubPanel(id: "b", category: .receive))
        first.toggleVisibility("b")
        first.selectedPanelID = "a"
        first.saveCurrentLayout()

        let second = makeRegistry()
        second.register(StubPanel(id: "a", category: .receive))
        second.register(StubPanel(id: "b", category: .receive))
        XCTAssertTrue(second.isVisible("a"))
        XCTAssertFalse(second.isVisible("b"))
        XCTAssertEqual(second.selectedPanelID, "a")
    }

    func testPanelAddedAfterSavedLayoutUsesDefaultVisible() {
        let first = makeRegistry()
        first.register(StubPanel(id: "a", category: .receive))
        first.toggleVisibility("a")
        first.saveCurrentLayout()

        let second = makeRegistry()
        second.register(StubPanel(id: "a", category: .receive))
        second.register(StubPanel(id: "new", category: .receive))
        second.register(StubPanel(id: "newHidden", category: .receive, defaultVisible: false))
        XCTAssertFalse(second.isVisible("a"))
        XCTAssertTrue(second.isVisible("new"))
        XCTAssertFalse(second.isVisible("newHidden"))
    }

    func testWillTerminateSavesCurrentLayout() {
        let first = makeRegistry()
        first.register(StubPanel(id: "a", category: .receive))
        first.toggleVisibility("a")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        let second = makeRegistry()
        second.register(StubPanel(id: "a", category: .receive))
        XCTAssertFalse(second.isVisible("a"))
    }

    func testPanelCategoryCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(PanelCategory.allCases)
        XCTAssertEqual(try JSONDecoder().decode([PanelCategory].self, from: data), PanelCategory.allCases)
        XCTAssertEqual(PanelCategory.receive.rawValue, "receive")
    }
}

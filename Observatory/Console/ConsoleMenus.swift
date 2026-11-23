import AppKit

/// Everything the console's View menu can do.
enum ConsoleMenuAction: Hashable {
    case focus(ReceiverID)
    case toggleSub
    case layout(DisplayLayout)
    case toggleTerrain
    case terrainView(TerrainView)

    /// The menu shortcut, if any. ⌘1/⌘2 focus a receiver, ⌥⌘1–3 pick a layout in
    /// `DisplayLayout.allCases` order, ⌥⌘T shows or hides the audio terrain.
    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch self {
        case .focus(.main): ("1", [.command])
        case .focus(.sub): ("2", [.command])
        case .layout(let layout):
            (String((DisplayLayout.allCases.firstIndex(of: layout) ?? 0) + 1), [.command, .option])
        case .toggleTerrain: ("t", [.command, .option])
        case .toggleSub, .terrainView: nil
        }
    }
}

/// What the View menu shows for the current radio snapshot and display choices.
struct ConsoleMenuState {
    let snapshot: RadioSnapshot
    let layout: DisplayLayout
    let terrainExpanded: Bool
    let terrainView: TerrainView

    init(snapshot: RadioSnapshot, layout: DisplayLayout, terrainExpanded: Bool, terrainView: TerrainView) {
        self.snapshot = snapshot
        self.layout = layout
        self.terrainExpanded = terrainExpanded
        self.terrainView = terrainView
    }

    /// Only focusing Sub is ever unavailable: there is nothing to focus while it is off.
    func isEnabled(_ action: ConsoleMenuAction) -> Bool {
        if case .focus(.sub) = action { return snapshot.sub.enabled }
        return true
    }

    func isChecked(_ action: ConsoleMenuAction) -> Bool {
        switch action {
        case .focus(let id): snapshot.session.focused == id
        case .toggleSub: snapshot.sub.enabled
        case .layout(let l): layout == l
        case .toggleTerrain: false
        case .terrainView(let v): terrainView == v
        }
    }

    func title(_ action: ConsoleMenuAction) -> String {
        switch action {
        case .focus(.main): "Focus Main Receiver"
        case .focus(.sub): "Focus Sub Receiver"
        case .toggleSub: "Sub Receiver"
        case .layout(let l): l.title
        case .toggleTerrain: terrainExpanded ? "Hide Audio Terrain" : "Show Audio Terrain"
        case .terrainView(let v): v.rawValue
        }
    }
}

/// Owns the console's View and Window menus and the window's size rules. Engine-owned state
/// changes only through `backend.send(_:)`; screen-only state goes to `display`.
@MainActor
final class ConsoleShell: NSObject, NSMenuItemValidation {
    let backend: any RadioBackend
    let display: DisplayStore

    private static let viewMenuID = NSUserInterfaceItemIdentifier("lyra.console.view")
    private static let windowMenuID = NSUserInterfaceItemIdentifier("lyra.console.window")

    /// Carries a `ConsoleMenuAction` on an `NSMenuItem` (`representedObject` needs an object).
    private final class ActionBox: NSObject {
        let action: ConsoleMenuAction
        init(_ action: ConsoleMenuAction) { self.action = action }
    }

    /// Windows already attached, so each gets one frame restore and one set of observers.
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var windowObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    /// The Window menu we made `NSApp.windowsMenu`, so a later rebuild can replace our own
    /// stale one without ever taking over a Window menu someone else installed.
    private weak var ownWindowsMenu: NSMenu?

    init(backend: any RadioBackend, display: DisplayStore, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.display = display
        self.defaults = defaults
    }

    private var state: ConsoleMenuState {
        ConsoleMenuState(snapshot: backend.snapshot, layout: display.layout,
                         terrainExpanded: display.terrainExpanded, terrainView: display.terrainView)
    }

    func perform(_ action: ConsoleMenuAction) {
        switch action {
        case .focus(let id): backend.send(.focus(id))
        case .toggleSub: backend.send(.setSubEnabled(!backend.snapshot.sub.enabled))
        case .layout(let l): display.layout = l
        case .toggleTerrain: display.terrainExpanded.toggle()
        case .terrainView(let v): display.terrainView = v
        }
    }

    // MARK: - Window

    func attach(_ window: NSWindow) {
        guard !attachedWindows.contains(window) else { return }
        attachedWindows.add(window)
        window.contentMinSize = ConsoleLayout.minWindow

        // Deferred one main-loop turn: the window's creator centres it after building this
        // view, which would undo a frame restored synchronously here.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restoreFrame(of: window)
            self.installMenus()
            let center = NotificationCenter.default
            // Qt rebuilds the main menu when its own windows (such as Settings) take focus.
            self.windowObservers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.installMenus() }
            })
            // Registered after the restore, so the creator's initial placement is never saved.
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                self.windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.saveFrame(of: window)
                    }
                })
            }
        }
    }

    /// AppKit's frame autosave is not used: `setFrameUsingName` maps a frame saved on a second
    /// display proportionally onto whichever screen the window is on at the time, so the window
    /// would reopen on the wrong display. The frame is saved and placed here instead.
    private func saveFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: WindowFrameRules.autosaveName)
    }

    /// Puts the window back where it was saved, on the screen holding most of it, or on the
    /// window's own screen when that display is gone; first launch gets the default size,
    /// centred. Either way the frame is then clamped onto that screen.
    private func restoreFrame(of window: NSWindow) {
        let screens = NSScreen.screens
        let frame: CGRect
        let screen: NSScreen?
        if let string = defaults.string(forKey: WindowFrameRules.autosaveName),
           case let saved = NSRectFromString(string), saved.width > 0, saved.height > 0 {
            frame = saved
            screen = WindowFrameRules.screenIndex(for: saved, among: screens.map(\.visibleFrame)).map { screens[$0] }
                ?? window.screen ?? NSScreen.main
        } else {
            screen = window.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setContentSize(WindowFrameRules.initialContentSize(visible: visible.size))
                window.center()
            }
            frame = window.frame
        }
        guard let visible = screen?.visibleFrame else { return }
        let minFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: ConsoleLayout.minWindow)).size
        window.setFrame(WindowFrameRules.clamp(frame, into: visible, minSize: minFrame), display: true)
        saveFrame(of: window)
    }

    // MARK: - Menus

    /// Inserts the View menu after the app menu and a Window menu after it, replacing only
    /// items this method inserted earlier; everything else in the main menu belongs to Qt.
    func installMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where item.identifier == Self.viewMenuID || item.identifier == Self.windowMenuID {
            mainMenu.removeItem(item)
        }

        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.identifier = Self.viewMenuID
        viewItem.submenu = makeViewMenu()
        viewItem.setAccessibilityLabel("View")
        let viewIndex = min(1, mainMenu.numberOfItems)
        mainMenu.insertItem(viewItem, at: viewIndex)

        let windowMenu = makeWindowMenu()
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.identifier = Self.windowMenuID
        windowItem.submenu = windowMenu
        windowItem.setAccessibilityLabel("Window")
        mainMenu.insertItem(windowItem, at: viewIndex + 1)

        if NSApp.windowsMenu == nil || (ownWindowsMenu != nil && NSApp.windowsMenu === ownWindowsMenu) {
            NSApp.windowsMenu = windowMenu
            ownWindowsMenu = windowMenu
        }
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item(.focus(.main)))
        menu.addItem(item(.focus(.sub)))
        menu.addItem(.separator())
        menu.addItem(item(.toggleSub))
        menu.addItem(.separator())
        for layout in DisplayLayout.allCases { menu.addItem(item(.layout(layout))) }
        menu.addItem(.separator())
        menu.addItem(item(.toggleTerrain))

        let terrain = NSMenu(title: "Audio Terrain View")
        for view in TerrainView.allCases { terrain.addItem(item(.terrainView(view))) }
        let terrainItem = NSMenuItem(title: "Audio Terrain View", action: nil, keyEquivalent: "")
        terrainItem.submenu = terrain
        terrainItem.setAccessibilityLabel("Audio Terrain View")
        menu.addItem(terrainItem)
        return menu
    }

    private func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.keyEquivalentModifierMask = [.command]
        minimize.setAccessibilityLabel("Minimize")
        menu.addItem(minimize)
        let zoom = NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoom.setAccessibilityLabel("Zoom")
        menu.addItem(zoom)
        return menu
    }

    private func item(_ action: ConsoleMenuAction) -> NSMenuItem {
        let title = state.title(action)
        let key = action.keyEquivalent
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: key?.key ?? "")
        if let key { item.keyEquivalentModifierMask = key.modifiers }
        item.target = self
        item.representedObject = ActionBox(action)
        item.setAccessibilityLabel(title)
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let box = menuItem.representedObject as? ActionBox else { return true }
        let state = state
        let title = state.title(box.action)
        menuItem.title = title
        menuItem.setAccessibilityLabel(title)
        menuItem.state = state.isChecked(box.action) ? .on : .off
        return state.isEnabled(box.action)
    }
}

import SwiftUI

#if !LYRA_BRIDGE
@main
#endif
struct ObservatoryApp: App {
    @State private var backend = MockRadioBackend()
    @State private var displayStore = DisplayStore()

    var body: some Scene {
        WindowGroup {
            ConsoleView(backend: backend, displayStore: displayStore)
        }
    }
}

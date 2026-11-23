import SwiftUI

#if !LYRA_BRIDGE
@main
#endif
struct ObservatoryApp: App {
    @State private var backend = MockRadioBackend()

    var body: some Scene {
        WindowGroup {
            ConsoleView(backend: backend)
        }
    }
}

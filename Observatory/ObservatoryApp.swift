import SwiftUI

@main
struct ObservatoryApp: App {
    @State private var radio = RadioBridge.mock()
    @State private var dsp = DspBridge.mock()
    @State private var meter = MeterBridge.mock()
    @State private var audio = AudioBridge.mock()
    @State private var registry = PanelRegistry()
    // TODO(Task 6): register P0 panels with `registry`.

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(radio)
                .environment(dsp)
                .environment(meter)
                .environment(audio)
                .environment(registry)
                .frame(minWidth: 960, minHeight: 640)
        }
    }
}

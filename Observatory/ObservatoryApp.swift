import SwiftUI

#if !LYRA_BRIDGE
@main
#endif
struct ObservatoryApp: App {
    @State private var radio = RadioBridge.mock()
    @State private var dsp = DspBridge.mock()
    @State private var meter = MeterBridge.mock()
    @State private var audio = AudioBridge.mock()
    @State private var registry: PanelRegistry

    init() {
        // @State storage cannot be read in init, so build and populate the registry here.
        let registry = PanelRegistry()
        registry.register(SpectrumPanel())
        registry.register(VfoTuningPanel())
        registry.register(AudioDspPanel())
        registry.register(BandSelectorPanel())
        registry.register(FiltersPanel())
        registry.register(MetersPanel())
        _registry = State(initialValue: registry)
    }

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

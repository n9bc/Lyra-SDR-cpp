// ObservatoryHost — @objc entry point called from ObservatoryWindow.mm to
// create the SwiftUI NSHostingView with all four bridge instances wired up.

import SwiftUI
import AppKit

@MainActor
@objc public class ObservatoryHost: NSObject {
    /// Creates the SwiftUI hosting view for the Observatory window.
    ///
    /// Called from Obj-C++ (`ObservatoryWindow.mm`). The facade is the single
    /// Obj-C++ object bridging every C++ subsystem; the four protocol-based
    /// bridge classes each take a different slice of it.
    @objc public static func createHostingView(facade: LyraEngineFacade) -> NSView {
        let radio = RadioBridge(facade: facade)
        let dsp = DspBridge(facade: facade)
        let meter = MeterBridge(facade: facade)
        let audio = AudioBridge(facade: facade)
        let spectrum = SpectrumBridge(source: facade)

        let registry = PanelRegistry()
        registry.register(SpectrumPanel())
        registry.register(VfoTuningPanel())
        registry.register(AudioDspPanel())
        registry.register(BandSelectorPanel())
        registry.register(FiltersPanel())
        registry.register(MetersPanel())
        registry.register(ControlGalleryPanel())

        let content = ContentView()
            .environment(radio)
            .environment(dsp)
            .environment(meter)
            .environment(audio)
            .environment(spectrum)
            .environment(registry)
            .frame(minWidth: 960, minHeight: 640)

        return NSHostingView(rootView: content)
    }
}

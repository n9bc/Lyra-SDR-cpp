import SwiftUI

/// Spectrum display-range controls (the trace itself is drawn by `NeonSpectrumView`).
struct SpectrumPanel: LyraPanel {
    let id = "spectrum"
    let title = "Spectrum"
    let systemImage = "waveform"
    let category = PanelCategory.receive
    let defaultVisible = true

    var content: some View { SpectrumPanelContent() }
}

private struct SpectrumPanelContent: View {
    @Environment(SpectrumBridge.self) private var spectrum

    var body: some View {
        @Bindable var spectrum = spectrum
        let floor = Binding<Double>(
            get: { spectrum.dbFloor },
            set: { v in
                let r = SpectrumBridge.constrained(floor: v, ceiling: spectrum.dbCeiling)
                spectrum.dbFloor = r.floor; spectrum.dbCeiling = r.ceiling
            })
        let ceiling = Binding<Double>(
            get: { spectrum.dbCeiling },
            set: { v in
                let r = SpectrumBridge.constrained(floor: spectrum.dbFloor, ceiling: v)
                spectrum.dbFloor = r.floor; spectrum.dbCeiling = r.ceiling
            })
        VStack(alignment: .leading, spacing: 10) {
            LyraSlider("Floor", value: floor, in: -160...(-40), step: 1, unit: "dB")
            LyraSlider("Ceiling", value: ceiling, in: -100...0, step: 1, unit: "dB")
            LyraButton("Reset") {
                spectrum.dbFloor = -130
                spectrum.dbCeiling = -20
            }
        }
    }
}

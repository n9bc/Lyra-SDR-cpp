import SwiftUI

/// Live waterfall: the Metal ring-texture renderer for this stack's receiver.
struct WaterfallView: View {
    @Environment(SpectrumBridge.self) private var bridge
    @State private var renderer: WaterfallRenderer?
    @State private var rendererFailed = false

    var body: some View {
        ZStack {
            LyraDS.Palette.void
            if let renderer {
                LyraMetalView(renderer: renderer)
            } else if rendererFailed {
                Text("Metal unavailable").foregroundStyle(LyraDS.Palette.textMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waterfall")
        .onAppear(perform: makeRendererIfNeeded)
    }

    private func makeRendererIfNeeded() {
        guard renderer == nil, !rendererFailed else { return }
        guard let ctx = MetalContext.shared,
              let r = try? WaterfallRenderer(bridge: bridge, context: ctx) else {
            rendererFailed = true
            return
        }
        renderer = r
    }
}

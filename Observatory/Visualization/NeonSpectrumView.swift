import SwiftUI

/// Live neon spectrum: the Metal renderer under a SwiftUI dB / division grid.
struct NeonSpectrumView: View {
    @Environment(SpectrumBridge.self) private var bridge
    @State private var renderer: NeonSpectrumRenderer?
    @State private var rendererFailed = false

    /// Vertical division lines drawn across the span.
    static let verticalDivisions = 8
    static let dbStep: Double = 10

    var body: some View {
        ZStack {
            LyraDS.Palette.void
            if let renderer {
                LyraMetalView(renderer: renderer)
            } else if rendererFailed {
                Text("Metal unavailable")
                    .foregroundStyle(LyraDS.Palette.textMuted)
            }
            grid
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectrum")
        .onAppear(perform: makeRendererIfNeeded)
    }

    private func makeRendererIfNeeded() {
        guard renderer == nil, !rendererFailed else { return }
        guard let ctx = MetalContext.shared,
              let r = try? NeonSpectrumRenderer(bridge: bridge, context: ctx) else {
            rendererFailed = true
            return
        }
        renderer = r
    }

    private var grid: some View {
        let floor = bridge.dbFloor
        let ceiling = bridge.dbCeiling
        return Canvas { ctx, size in
            guard size.width > 0, size.height > 0, ceiling > floor else { return }
            let range = ceiling - floor
            let line = GraphicsContext.Shading.color(LyraDS.Palette.border)

            var db = (floor / Self.dbStep).rounded(.up) * Self.dbStep
            while db <= ceiling {
                let y = ((1 - (db - floor) / range) * size.height).rounded() + 0.5
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: line, lineWidth: 1)

                let label = Text("\(Int(db))")
                    .font(LyraDS.Font.label(size: 9))
                    .foregroundStyle(LyraDS.Palette.textDim)
                // Keep the top label inside the view.
                let anchor: UnitPoint = y < 12 ? .topLeading : .bottomLeading
                ctx.draw(label, at: CGPoint(x: 4, y: anchor == .topLeading ? y + 2 : y - 2), anchor: anchor)
                db += Self.dbStep
            }

            for i in 1...Self.verticalDivisions {
                let x = (size.width * CGFloat(i) / CGFloat(Self.verticalDivisions + 1)).rounded() + 0.5
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: line, lineWidth: 1)
            }
        }
    }
}

#Preview {
    NeonSpectrumView()
        .environment(SpectrumBridge.mock())
        .frame(width: 900, height: 320)
}

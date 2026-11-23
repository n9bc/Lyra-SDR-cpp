import SwiftUI

/// Live neon spectrum: the Metal renderer under a SwiftUI dB / division grid.
struct NeonSpectrumView: View {
    @Environment(SpectrumBridge.self) private var bridge
    @State private var renderer: NeonSpectrumRenderer?
    @State private var rendererFailed = false

    /// Vertical division lines drawn across the span.
    static let verticalDivisions = 8
    static let dbStep: Double = 10

    /// Label every k-th grid line, where k is the smallest integer that keeps labels
    /// at least `minSpacing` points apart. Degenerate input returns 1.
    nonisolated static func labelStride(height: CGFloat, range: Double, step: Double,
                                        minSpacing: CGFloat = 14) -> Int {
        guard height > 0, range > 0, step > 0, minSpacing > 0 else { return 1 }
        let perStep = CGFloat(step / range) * height
        guard perStep > 0, perStep.isFinite else { return 1 }
        return max(1, Int((minSpacing / perStep).rounded(.up)))
    }

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

            let labelEvery = Self.labelStride(height: size.height, range: range, step: Self.dbStep)
            var index = 0
            var db = (floor / Self.dbStep).rounded(.up) * Self.dbStep
            while db <= ceiling {
                let y = ((1 - (db - floor) / range) * size.height).rounded() + 0.5
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: line, lineWidth: 1)

                defer { db += Self.dbStep; index += 1 }
                guard index % labelEvery == 0 else { continue }
                let label = Text("\(Int(db))")
                    .font(LyraDS.Font.label(size: 9))
                    .foregroundStyle(LyraDS.Palette.textDim)
                // Keep the top label inside the view.
                let anchor: UnitPoint = y < 12 ? .topLeading : .bottomLeading
                ctx.draw(label, at: CGPoint(x: 4, y: anchor == .topLeading ? y + 2 : y - 2), anchor: anchor)
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

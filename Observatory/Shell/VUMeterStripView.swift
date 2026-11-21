import SwiftUI

/// S-meter, TX power and SWR as horizontal bars.
struct VUMeterStripView: View {
    @Environment(MeterBridge.self) private var meter

    private static let ratedPowerW = 100.0

    var body: some View {
        HStack(spacing: 24) {
            column("S-METER", level: meter.sMeterLevel, text: meter.sMeterText,
                   secondary: meter.dbmText,
                   colors: [LyraTheme.cyan.opacity(0.4), LyraTheme.cyan])
            column("TX POWER", level: meter.txPowerW / Self.ratedPowerW,
                   text: String(format: "%.1f W", meter.txPowerW), secondary: nil,
                   colors: [LyraTheme.amber.opacity(0.4), LyraTheme.amber])
            column("SWR", level: (meter.swr - 1) / 2,
                   text: String(format: "%.1f:1", meter.swr), secondary: nil,
                   colors: [.green.opacity(0.4), .green])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func column(_ label: String, level: Double, text: String,
                        secondary: String?, colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(LyraTheme.textMuted)
                Spacer()
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LyraTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(LyraTheme.surface)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(max(level, 0), 1))
                }
            }
            .frame(height: 8)
            Text(secondary ?? " ").font(.system(size: 9, design: .monospaced))
                .foregroundStyle(LyraTheme.textDim)
        }
        .frame(maxWidth: .infinity)
    }
}

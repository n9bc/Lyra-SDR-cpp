import SwiftUI

/// Horizontal row of glass pills; the selected mode glows cyan.
struct ModeSelector: View {
    let modes: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modes, id: \.self) { mode in
                BandChip(label: mode, isActive: mode == selected) {
                    selected = mode
                }
            }
        }
    }
}

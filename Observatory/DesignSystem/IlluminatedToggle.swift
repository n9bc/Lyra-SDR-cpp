import SwiftUI

/// Glass toggle with a bottom-edge light bar and text glow when on.
struct IlluminatedToggle: View {
    let label: String
    @Binding var isOn: Bool
    let accentColor: Color

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassButton(isActive: isOn, accentColor: accentColor)
                .overlay(alignment: .bottom) {
                    if isOn {
                        Capsule()
                            .fill(accentColor)
                            .frame(height: 2)
                            .padding(.horizontal, 4)
                            .shadow(color: accentColor, radius: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

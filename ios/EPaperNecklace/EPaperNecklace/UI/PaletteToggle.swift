import SwiftUI

/// Custom two-up switch between the black & white and black/white/red palettes.
/// Flipping it re-dithers the current photo immediately.
struct PaletteToggle: View {
    @Binding var selection: PaletteMode
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PaletteMode.allCases) { mode in
                let isSelected = mode == selection
                Button {
                    guard mode != selection else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selection = mode
                    }
                } label: {
                    VStack(spacing: 6) {
                        swatches(for: mode)
                        Text(mode.title)
                            .roundedFont(14, weight: isSelected ? .bold : .medium)
                            .foregroundColor(isSelected ? Theme.ink : Theme.softInk)
                        Text(mode.subtitle)
                            .roundedFont(11)
                            .foregroundColor(Theme.softInk.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        ZStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Theme.butter.opacity(0.55))
                                    .matchedGeometryEffect(id: "palette", in: namespace)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.paper)
                .shadow(color: Theme.ink.opacity(0.07), radius: 12, y: 5)
        )
    }

    private func swatches(for mode: PaletteMode) -> some View {
        HStack(spacing: 4) {
            ForEach(mode.inks, id: \.rawValue) { ink in
                Circle()
                    .fill(Color(red: Double(ink.displayRGB.r) / 255,
                                green: Double(ink.displayRGB.g) / 255,
                                blue: Double(ink.displayRGB.b) / 255))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.12), lineWidth: 1))
            }
        }
    }
}

import SwiftUI

/// Modal overlay covering the upload: a soft progress ring while chunks fly,
/// then a little celebration once the necklace acknowledges the final byte.
struct TransferOverlay: View {
    enum Phase: Equatable {
        case sending
        case celebrating
    }

    let phase: Phase

    /// Observed directly so per-packet progress reaches the ring without the
    /// parent view having to re-publish it.
    @ObservedObject var ble: NecklaceBLEManager
    var onDismiss: () -> Void

    @State private var spin = false
    @State private var pop = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                switch phase {
                case .sending:
                    ring
                    Text("Sending to your necklace")
                        .roundedFont(17, weight: .semibold)
                        .foregroundColor(Theme.ink)
                    Text(detail)
                        .roundedFont(13)
                        .foregroundColor(Theme.softInk)
                        .monospacedDigit()

                case .celebrating:
                    celebration
                    Text("All sent!")
                        .roundedFont(20, weight: .bold)
                        .foregroundColor(Theme.ink)
                    Text("The panel takes about \(Int(PanelSpec.refreshDuration)) seconds to finish redrawing. Hold still, it's worth it.")
                        .roundedFont(13)
                        .foregroundColor(Theme.softInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    Button("Lovely", action: onDismiss)
                        .buttonStyle(SquishyButtonStyle())
                        .padding(.top, 4)
                }
            }
            .padding(26)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            )
            .padding(.horizontal, 36)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var fraction: Double {
        ble.progress?.fraction ?? 0
    }

    private var detail: String {
        guard let progress = ble.progress else { return "Waking up the panel..." }
        return "packet \(progress.packetsSent) of \(progress.totalPackets)  ·  \(Int(fraction * 100))%"
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Theme.lilac.opacity(0.2), lineWidth: 12)

            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    AngularGradient(colors: [Theme.lilac, Theme.blush, Theme.butter, Theme.lilac],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)

            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Theme.lilac)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: 120, height: 120)
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }

    private var celebration: some View {
        ZStack {
            Circle()
                .fill(Theme.mint.opacity(0.25))
                .frame(width: 110, height: 110)
                .scaleEffect(pop ? 1 : 0.6)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(Theme.mint)
                .scaleEffect(pop ? 1 : 0.4)
                .rotationEffect(.degrees(pop ? 0 : -25))
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) {
                pop = true
            }
        }
    }
}

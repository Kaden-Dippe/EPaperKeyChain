import SwiftUI

/// Persistent header showing whether the necklace is awake and listening.
struct StatusHeaderView: View {
    @ObservedObject var ble: NecklaceBLEManager
    var onTap: () -> Void

    @State private var sparkle = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(bubbleColor.opacity(0.22))
                        .frame(width: 46, height: 46)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(bubbleColor)
                        .symbolRenderingMode(.hierarchical)
                        .scaleEffect(sparkle && ble.state.isReady ? 1.12 : 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .roundedFont(16, weight: .semibold)
                        .foregroundColor(Theme.ink)
                    Text(subtitle)
                        .roundedFont(12.5)
                        .foregroundColor(Theme.softInk)
                }

                Spacer()

                if ble.state.isBusy {
                    ProgressView().tint(Theme.softInk)
                } else {
                    Image(systemName: ble.state.isReady ? "chevron.right" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.softInk.opacity(0.6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 4)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                sparkle = true
            }
        }
    }

    private var title: String {
        switch ble.state {
        case .ready: return ble.connectedName ?? "Necklace connected"
        case .scanning: return "Looking around..."
        case .connecting: return "Saying hello..."
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission needed"
        case .unsupported: return "No Bluetooth here"
        case .disconnected, .unknown: return "Necklace asleep"
        }
    }

    private var subtitle: String {
        switch ble.state {
        case .ready: return "Ready for a new picture"
        case .scanning: return "Searching for \(NecklaceProtocol.deviceName)"
        case .connecting: return "Opening the channel"
        case .poweredOff: return "Turn Bluetooth on to continue"
        case .unauthorized: return "Enable it in Settings"
        case .unsupported: return "This device can't talk to the necklace"
        case .disconnected, .unknown: return "Tap to wake it up"
        }
    }

    private var symbol: String {
        switch ble.state {
        case .ready: return "sparkles"
        case .scanning, .connecting: return "dot.radiowaves.left.and.right"
        case .poweredOff, .unauthorized, .unsupported: return "exclamationmark.triangle.fill"
        case .disconnected, .unknown: return "moon.zzz.fill"
        }
    }

    private var bubbleColor: Color {
        switch ble.state {
        case .ready: return Theme.mint
        case .scanning, .connecting: return Theme.lilac
        case .poweredOff, .unauthorized, .unsupported: return Theme.panelRed
        case .disconnected, .unknown: return Theme.softInk
        }
    }
}

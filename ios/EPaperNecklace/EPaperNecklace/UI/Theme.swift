import SwiftUI

/// Soft, rounded, pastel. The necklace is jewellery, so the app should feel
/// like a toy rather than a firmware tool.
///
/// These are the palette used by the app's own views. Separately,
/// `Assets.xcassets/AccentColor.colorset` sets the app-wide accent colour that
/// UIKit and SwiftUI apply to standard controls - links, pickers, the tint on
/// system buttons - anywhere this palette isn't explicitly applied.
enum Theme {

    static let blush = Color(red: 0.99, green: 0.76, blue: 0.83)
    static let lilac = Color(red: 0.80, green: 0.77, blue: 0.98)
    static let mint = Color(red: 0.71, green: 0.93, blue: 0.85)
    static let butter = Color(red: 1.00, green: 0.90, blue: 0.71)
    static let ink = Color(red: 0.20, green: 0.18, blue: 0.27)
    static let softInk = Color(red: 0.45, green: 0.43, blue: 0.55)
    static let paper = Color(red: 0.99, green: 0.98, blue: 1.00)
    static let panelRed = Color(red: 0.78, green: 0.19, blue: 0.17)

    static var background: LinearGradient {
        LinearGradient(colors: [Color(red: 1.00, green: 0.96, blue: 0.98),
                                Color(red: 0.94, green: 0.95, blue: 1.00),
                                Color(red: 0.93, green: 0.99, blue: 0.98)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    static var primaryButton: LinearGradient {
        LinearGradient(colors: [lilac, blush], startPoint: .leading, endPoint: .trailing)
    }

    static let cardRadius: CGFloat = 26
    static let buttonRadius: CGFloat = 22
}

/// A rounded, softly shadowed container used for every block on the main screen.
struct SoftCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: Theme.ink.opacity(0.08), radius: 18, x: 0, y: 8)
            )
    }
}

/// The big inviting call-to-action button style.
struct SquishyButtonStyle: ButtonStyle {
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.primaryButton)
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundColor(foreground)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .fill(fill)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension View {
    func roundedFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
    }
}

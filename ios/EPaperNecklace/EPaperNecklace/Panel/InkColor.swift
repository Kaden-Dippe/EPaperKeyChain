import Foundation

/// A colour the e-paper panel can physically render.
///
/// The raw values are the two bits that get packed into the payload, and they
/// match the Inkplate 2 driver's own colour constants (`BLACK`, `WHITE`, `RED`).
/// The fourth 2-bit combination (`0b11`) is unused by the hardware.
enum InkColor: UInt8, CaseIterable {
    case black = 0b00
    case white = 0b01
    case red   = 0b10

    /// How the ink actually looks on the panel.
    ///
    /// The red channel is a fairly muted vermilion rather than a pure #FF0000,
    /// so using these values for both palette matching and the on-screen
    /// preview keeps the preview honest about what the necklace will show.
    var displayRGB: RGBFloat {
        switch self {
        case .black: return RGBFloat(r: 22, g: 22, b: 26)
        case .white: return RGBFloat(r: 244, g: 243, b: 238)
        case .red:   return RGBFloat(r: 198, g: 48, b: 44)
        }
    }
}

/// The palettes the user can choose between in the UI.
enum PaletteMode: String, CaseIterable, Identifiable {
    case classic
    case accent

    var id: String { rawValue }

    /// The ink colours the ditherer is allowed to use.
    var inks: [InkColor] {
        switch self {
        case .classic: return [.black, .white]
        case .accent:  return [.black, .white, .red]
        }
    }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .accent:  return "Accent"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "Black & white"
        case .accent:  return "Black, white & red"
        }
    }

    var symbolName: String {
        switch self {
        case .classic: return "circle.lefthalf.filled"
        case .accent:  return "heart.fill"
        }
    }
}

/// A floating point RGB triple in 0...255. Used as the ditherer's working
/// representation so quantisation error can go negative and overshoot.
struct RGBFloat: Equatable {
    var r: Float
    var g: Float
    var b: Float

    init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Luma / chroma representation used for palette matching.
///
/// Matching in YCbCr rather than raw RGB matters once red joins the palette:
/// mid grey sits almost exactly halfway between black, white and red in plain
/// RGB distance, which speckles flat grey areas with red pixels. Weighting the
/// chroma difference more heavily pushes neutral tones back to black/white and
/// reserves red for pixels that are genuinely red.
struct YCbCr {
    let y: Float
    let cb: Float
    let cr: Float

    /// How much more a chroma error counts than a luma error.
    ///
    /// Tuned against flat test fields: at 1.0 a flat 50% grey picks up ~10%
    /// stray red pixels, at 2.0 it picks up none, while a warm skin/brick tone
    /// still lands ~84% red ink either way.
    static let chromaWeight: Float = 2.0

    init(_ rgb: RGBFloat) {
        y  =  0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b
        cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b + 128
        cr =  0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b + 128
    }

    func distanceSquared(to other: YCbCr) -> Float {
        let dy = y - other.y
        let dcb = cb - other.cb
        let dcr = cr - other.cr
        return dy * dy + YCbCr.chromaWeight * (dcb * dcb + dcr * dcr)
    }
}

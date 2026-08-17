import Foundation

/// Physical characteristics of the Inkplate 2 panel that lives on the necklace.
///
/// Every number in here is dictated by the hardware, so the whole pipeline
/// (render -> dither -> pack -> transfer) reads its sizes from this one place.
enum PanelSpec {

    /// Native panel width, in pixels, in the orientation the firmware expects.
    static let width = 212

    /// Native panel height, in pixels.
    static let height = 104

    /// 212 * 104 = 22,048 pixels.
    static let pixelCount = width * height

    /// Two bits per pixel: enough for the panel's three inks plus one unused
    /// code. See `InkColor` for which value each ink packs to.
    static let bitsPerPixel = 2

    /// Eight bits to a byte at two bits each, so four pixels share a byte.
    static let pixelsPerByte = 8 / bitsPerPixel

    /// 22,048 / 4 = 5,512 bytes. The firmware expects exactly this many.
    static let payloadByteCount = pixelCount / pixelsPerByte

    /// Landscape aspect ratio (212:104), used to constrain cropping.
    static let landscapeAspectRatio = Double(width) / Double(height)

    /// Portrait aspect ratio (104:212). Portrait crops are rotated a quarter
    /// turn during rendering so the packed buffer is always landscape.
    static let portraitAspectRatio = Double(height) / Double(width)

    /// Roughly how long the panel takes to fully refresh once it has the file.
    static let refreshDuration: TimeInterval = 30
}

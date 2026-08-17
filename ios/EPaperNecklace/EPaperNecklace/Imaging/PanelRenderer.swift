import CoreGraphics
import Foundation

/// How a crop needs to be turned before it lands on the landscape panel.
enum PanelRotation {
    case none
    case clockwise
    case counterClockwise

    var isQuarterTurn: Bool { self != .none }
}

enum ImagingError: LocalizedError {
    case emptyCrop
    case contextUnavailable
    case unexpectedPixelCount(expected: Int, actual: Int)

    var alertTitle: String {
        switch self {
        case .emptyCrop: return "Nothing to crop"
        case .contextUnavailable: return "Couldn't process that"
        case .unexpectedPixelCount: return "Pipeline mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyCrop:
            return "That crop came out empty - try framing the photo again."
        case .contextUnavailable:
            return "Couldn't create a drawing buffer for the panel."
        case .unexpectedPixelCount(let expected, let actual):
            return "Expected \(expected) pixels but the pipeline produced \(actual)."
        }
    }
}

/// Turns a cropped region of a source image into a 212 x 104 RGBA raster, and
/// turns dithered pixels back into a `CGImage` for the preview.
enum PanelRenderer {

    /// Crops, rotates and downsamples in a single Core Graphics pass.
    ///
    /// - Parameters:
    ///   - source: an up-oriented image; see `UIImage.normalizedCGImage()`.
    ///   - crop: rectangle in source pixel coordinates, origin top-left.
    ///   - rotation: quarter turn applied to portrait crops so the packed
    ///     buffer is always in the panel's landscape orientation.
    /// - Returns: `212 * 104 * 4` bytes of RGBA (alpha unused, always opaque).
    static func makePanelRaster(source: CGImage,
                                crop: CGRect,
                                rotation: PanelRotation) throws -> [UInt8] {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let cropRect = crop.integral.intersection(bounds)
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else {
            throw ImagingError.emptyCrop
        }

        let width = PanelSpec.width
        let height = PanelSpec.height
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImagingError.contextUnavailable
        }

        // Anything the crop doesn't cover reads as white paper.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        switch rotation {
        case .none:
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        case .clockwise, .counterClockwise:
            // Rotate about the centre, then draw the portrait crop into a
            // rect whose axes have been swapped by the quarter turn.
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: rotation == .clockwise ? -.pi / 2 : .pi / 2)
            context.draw(cropped, in: CGRect(x: -CGFloat(height) / 2,
                                             y: -CGFloat(width) / 2,
                                             width: CGFloat(height),
                                             height: CGFloat(width)))
        }

        guard let raw = context.data else { throw ImagingError.contextUnavailable }
        let byteCount = width * height * 4
        let pointer = raw.bindMemory(to: UInt8.self, capacity: byteCount)
        return [UInt8](UnsafeBufferPointer(start: pointer, count: byteCount))
    }

    /// Builds a 1:1 image of the dithered result. Interpolation is disabled so
    /// the preview stays pixel-perfect however far the UI scales it up.
    static func makePreviewImage(pixels: [InkColor],
                                 width: Int = PanelSpec.width,
                                 height: Int = PanelSpec.height) throws -> CGImage {
        guard pixels.count == width * height else {
            throw ImagingError.unexpectedPixelCount(expected: width * height, actual: pixels.count)
        }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices {
            let ink = pixels[index].displayRGB
            rgba[index * 4 + 0] = UInt8(clamping: Int(ink.r))
            rgba[index * 4 + 1] = UInt8(clamping: Int(ink.g))
            rgba[index * 4 + 2] = UInt8(clamping: Int(ink.b))
            rgba[index * 4 + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ImagingError.contextUnavailable
        }
        return image
    }
}

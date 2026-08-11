import CoreGraphics
import UIKit

extension UIImage {

    /// Returns a `CGImage` whose pixel rows match what the user sees.
    ///
    /// Photos from the camera usually carry an orientation flag rather than
    /// rotated pixels. Baking the orientation in here means the crop maths and
    /// the panel renderer can both treat (0, 0) as the visible top-left.
    func normalizedCGImage() -> CGImage? {
        if imageOrientation == .up, let cgImage {
            return cgImage
        }

        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return cgImage }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let redrawn = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        return redrawn.cgImage
    }
}

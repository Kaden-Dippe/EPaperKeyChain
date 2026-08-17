import Foundation

/// Atkinson error-diffusion dithering onto a fixed ink palette.
///
/// Atkinson only propagates 6/8 of the quantisation error (1/8 to each of six
/// neighbours) and throws the remaining 2/8 away. Losing that error is the
/// point: it keeps contrast crisp and stops highlights and shadows from
/// smearing, which is what makes photos read well on a 1-bit-ish panel.
///
///     matrix (X = current pixel, each neighbour receives err/8)
///
///         X  1  1
///      1  1  1
///         1
///
enum AtkinsonDitherer {

    /// Dithers a tightly packed RGBA8 buffer down to one ink colour per pixel.
    ///
    /// - Parameters:
    ///   - rgba: `width * height * 4` bytes, row major, alpha ignored.
    ///   - palette: the ink colours the output is allowed to use.
    /// - Returns: `width * height` ink colours, row major, top-left first.
    static func dither(rgba: [UInt8], width: Int, height: Int, palette: [InkColor]) -> [InkColor] {
        precondition(width > 0 && height > 0, "empty raster")
        precondition(rgba.count >= width * height * 4, "raster smaller than its stated size")
        precondition(!palette.isEmpty, "the palette needs at least one ink")

        let pixelCount = width * height

        // Working buffer is float RGB so error can accumulate past 0...255.
        var work = [Float](repeating: 0, count: pixelCount * 3)
        for index in 0..<pixelCount {
            work[index * 3 + 0] = Float(rgba[index * 4 + 0])
            work[index * 3 + 1] = Float(rgba[index * 4 + 1])
            work[index * 3 + 2] = Float(rgba[index * 4 + 2])
        }

        let inks = palette
        let inkRGB = palette.map { $0.displayRGB }
        let inkYCbCr = inkRGB.map { YCbCr($0) }

        var output = [InkColor](repeating: inks[0], count: pixelCount)

        work.withUnsafeMutableBufferPointer { buffer in
            output.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    for x in 0..<width {
                        let base = (y * width + x) * 3
                        let old = RGBFloat(r: buffer[base], g: buffer[base + 1], b: buffer[base + 2])

                        // Closest ink in the active palette.
                        let target = YCbCr(old)
                        var bestIndex = 0
                        var bestDistance = Float.greatestFiniteMagnitude
                        for candidate in inkYCbCr.indices {
                            let distance = target.distanceSquared(to: inkYCbCr[candidate])
                            if distance < bestDistance {
                                bestDistance = distance
                                bestIndex = candidate
                            }
                        }

                        out[y * width + x] = inks[bestIndex]

                        // One eighth of the quantisation error, per channel.
                        let chosen = inkRGB[bestIndex]
                        let shareR = (old.r - chosen.r) / 8
                        let shareG = (old.g - chosen.g) / 8
                        let shareB = (old.b - chosen.b) / 8

                        func spread(_ dx: Int, _ dy: Int) {
                            let nx = x + dx
                            let ny = y + dy
                            guard nx >= 0, nx < width, ny < height else { return }
                            let neighbour = (ny * width + nx) * 3
                            buffer[neighbour + 0] += shareR
                            buffer[neighbour + 1] += shareG
                            buffer[neighbour + 2] += shareB
                        }

                        spread(1, 0)
                        spread(2, 0)
                        spread(-1, 1)
                        spread(0, 1)
                        spread(1, 1)
                        spread(0, 2)
                        // The remaining 2/8 of the error is deliberately dropped.
                    }
                }
            }
        }

        return output
    }
}

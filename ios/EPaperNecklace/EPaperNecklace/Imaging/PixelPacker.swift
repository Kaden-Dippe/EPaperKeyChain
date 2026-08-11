import Foundation

/// Packs dithered pixels into the 5,512 byte payload the firmware writes to flash.
///
/// Four pixels share a byte at 2 bits each, most significant bits first, so the
/// left-most pixel of a group occupies bits 7-6:
///
///     byte = p0 << 6 | p1 << 4 | p2 << 2 | p3
///
/// The packing is identical in both palette modes - "Classic" simply never
/// emits the `red` code - because the firmware always reads a fixed-size,
/// 2-bit-per-pixel file.
enum PixelPacker {

    static func pack(_ pixels: [InkColor]) throws -> Data {
        guard pixels.count == PanelSpec.pixelCount else {
            throw ImagingError.unexpectedPixelCount(expected: PanelSpec.pixelCount, actual: pixels.count)
        }

        var payload = Data(count: PanelSpec.payloadByteCount)
        payload.withUnsafeMutableBytes { raw in
            guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for byteIndex in 0..<PanelSpec.payloadByteCount {
                let first = byteIndex * PanelSpec.pixelsPerByte
                out[byteIndex] = pixels[first].rawValue << 6
                    | pixels[first + 1].rawValue << 4
                    | pixels[first + 2].rawValue << 2
                    | pixels[first + 3].rawValue
            }
        }
        return payload
    }
}

import Foundation

/// Packs dithered pixels into the 5,512 byte payload the firmware writes to flash.
///
/// Four pixels share a byte at `PanelSpec.bitsPerPixel` each, most significant
/// bits first, so the left-most pixel of a group occupies bits 7-6:
///
///     byte = p0 << 6 | p1 << 4 | p2 << 2 | p3
///
/// The two-bit code for each ink is `InkColor`'s raw value, which is the single
/// definition of the bit patterns and matches the Inkplate 2 driver's own
/// colour constants:
///
///     InkColor.black = 0b00
///     InkColor.white = 0b01
///     InkColor.red   = 0b10
///     0b11 is unused by the hardware
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
            let shift = UInt8(PanelSpec.bitsPerPixel)
            for byteIndex in 0..<PanelSpec.payloadByteCount {
                let first = byteIndex * PanelSpec.pixelsPerByte
                var byte: UInt8 = 0
                for offset in 0..<PanelSpec.pixelsPerByte {
                    byte = (byte << shift) | pixels[first + offset].rawValue
                }
                out[byteIndex] = byte
            }
        }
        return payload
    }
}

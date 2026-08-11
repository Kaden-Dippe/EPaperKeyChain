import CoreGraphics
import Foundation

/// Everything the UI and the BLE transfer need about one processed photo.
struct PanelArtwork: Identifiable {
    let id = UUID()

    /// One ink colour per panel pixel, row major.
    let pixels: [InkColor]

    /// Exactly `PanelSpec.payloadByteCount` bytes, ready for the necklace.
    let payload: Data

    /// 212 x 104 rendering of `pixels` for the on-screen preview.
    let preview: CGImage

    /// Which palette produced this artwork.
    let palette: PaletteMode
}

/// The framing the user settled on, kept around so the palette toggle can
/// re-dither the same crop without sending them back through the crop screen.
struct CropSelection {
    let source: CGImage
    let rect: CGRect
    let rotation: PanelRotation
}

/// Crop -> scale -> dither -> pack, off the main thread.
enum ImagePipeline {

    static func makeArtwork(selection: CropSelection, palette: PaletteMode) async throws -> PanelArtwork {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try makeArtworkSynchronously(selection: selection,
                                                                                palette: palette))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func makeArtworkSynchronously(selection: CropSelection, palette: PaletteMode) throws -> PanelArtwork {
        let raster = try PanelRenderer.makePanelRaster(source: selection.source,
                                                       crop: selection.rect,
                                                       rotation: selection.rotation)
        let pixels = AtkinsonDitherer.dither(rgba: raster,
                                             width: PanelSpec.width,
                                             height: PanelSpec.height,
                                             palette: palette.inks)
        let payload = try PixelPacker.pack(pixels)
        let preview = try PanelRenderer.makePreviewImage(pixels: pixels)
        return PanelArtwork(pixels: pixels, payload: payload, preview: preview, palette: palette)
    }
}

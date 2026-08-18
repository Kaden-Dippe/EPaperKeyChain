import CoreGraphics
import PhotosUI
import SwiftUI
import UIKit

/// Owns the screen-to-screen flow: pick a photo, crop it, dither it, send it.
@MainActor
final class AppModel: ObservableObject {

    struct CropRequest: Identifiable {
        let id = UUID()
        let image: CGImage
    }

    struct AlertContent: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let ble = NecklaceBLEManager()

    @Published var paletteMode: PaletteMode = .accent
    @Published var photoSelection: PhotosPickerItem?
    @Published var isShowingPhotoPicker = false
    @Published var isShowingCamera = false
    @Published var cropRequest: CropRequest?
    @Published var alert: AlertContent?
    @Published private(set) var artwork: PanelArtwork?
    @Published private(set) var isRendering = false
    @Published private(set) var overlayPhase: TransferOverlay.Phase?

    /// The framing the user chose, kept so the palette toggle can re-dither
    /// without sending them back to the crop screen.
    private var selection: CropSelection?
    private var renderTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    var hasPhoto: Bool { artwork != nil }

    // MARK: - Connection

    func toggleConnection() {
        if ble.state.isReady {
            ble.disconnect()
            return
        }
        Task {
            Telemetry.shared.begin("connect requested")
            do {
                try await ble.connect()
                Telemetry.shared.flush("connected")
            } catch {
                present(error)
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Telemetry.shared.log("error: \(message)")
                Telemetry.shared.flush("connect failed")
            }
        }
    }

    // MARK: - Picking

    func photoSelectionChanged(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let normalized = image.normalizedCGImage() else {
                    photoSelection = nil
                    present(title: "Couldn't open that one",
                            message: "Try a different photo from your library.")
                    return
                }
                photoSelection = nil
                cropRequest = CropRequest(image: normalized)
            } catch {
                photoSelection = nil
                present(error)
            }
        }
    }

    func cameraCaptured(_ image: UIImage) {
        isShowingCamera = false
        guard let normalized = image.normalizedCGImage() else {
            present(title: "Couldn't use that shot", message: "Give it another go.")
            return
        }
        cropRequest = CropRequest(image: normalized)
    }

    // MARK: - Rendering

    func apply(_ selection: CropSelection) {
        self.selection = selection
        cropRequest = nil
        render()
    }

    func cancelCrop() {
        cropRequest = nil
    }

    func startOver() {
        renderTask?.cancel()
        selection = nil
        artwork = nil
    }

    /// Re-runs the pipeline for the current crop and palette. Cheap enough
    /// (22k pixels) to fire on every toggle flip.
    func render() {
        guard let selection else { return }
        renderTask?.cancel()
        isRendering = true
        let palette = paletteMode
        renderTask = Task { [weak self] in
            guard let self else { return }
            // `defer` rather than a trailing assignment: an early return on
            // cancellation would otherwise leave the spinner up forever when
            // no replacement render follows, as after startOver().
            defer { self.isRendering = false }
            do {
                let result = try await ImagePipeline.makeArtwork(selection: selection, palette: palette)
                if Task.isCancelled { return }
                self.artwork = result
            } catch {
                if !Task.isCancelled { self.present(error) }
            }
        }
    }

    // MARK: - Uploading

    func upload() {
        guard let artwork else { return }
        guard uploadTask == nil else { return }

        uploadTask = Task { [weak self] in
            guard let self else { return }
            self.overlayPhase = .sending

            // One batch per attempt, so a failure arrives as a single message
            // containing everything that led up to it.
            Telemetry.shared.begin("upload starting (\(artwork.palette.title), \(artwork.payload.count) bytes)")

            do {
                if !self.ble.state.isReady {
                    try await self.ble.connect()
                }
                try await self.ble.send(payload: artwork.payload)
                self.overlayPhase = .celebrating
                Telemetry.shared.flush("upload ok")
            } catch {
                self.overlayPhase = nil
                self.present(error)
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Telemetry.shared.log("error: \(message)")
                Telemetry.shared.flush("upload failed")
            }
            self.uploadTask = nil
        }
    }

    func dismissOverlay() {
        overlayPhase = nil
    }

    // MARK: - Alerts

    private func present(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let title = (error as? NecklaceError)?.alertTitle
            ?? (error as? ImagingError)?.alertTitle
            ?? "That didn't work"
        present(title: title, message: message)
    }

    private func present(title: String, message: String) {
        alert = AlertContent(title: title, message: message)
    }
}

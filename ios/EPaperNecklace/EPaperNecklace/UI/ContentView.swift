import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Namespace private var paletteNamespace

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                StatusHeaderView(ble: model.ble) { model.toggleConnection() }

                ScrollView {
                    VStack(spacing: 18) {
                        titleBlock
                        previewCard
                        PaletteToggle(selection: $model.paletteMode, namespace: paletteNamespace)
                        actionButtons
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }

            if let phase = model.overlayPhase {
                TransferOverlay(phase: phase, ble: model.ble) {
                    model.dismissOverlay()
                }
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.overlayPhase)
        .photosPicker(isPresented: $model.isShowingPhotoPicker,
                      selection: $model.photoSelection,
                      matching: .images,
                      photoLibrary: .shared())
        .onChange(of: model.photoSelection) { item in
            model.photoSelectionChanged(item)
        }
        .onChange(of: model.paletteMode) { _ in
            model.render()
        }
        .fullScreenCover(item: $model.cropRequest) { request in
            CropView(source: request.image) {
                model.cancelCrop()
            } onConfirm: { selection in
                model.apply(selection)
            }
        }
        .sheet(isPresented: $model.isShowingCamera) {
            CameraPicker { image in
                model.cameraCaptured(image)
            } onCancel: {
                model.isShowingCamera = false
            }
            .ignoresSafeArea()
        }
        .alert(item: $model.alert) { content in
            Alert(title: Text(content.title),
                  message: Text(content.message),
                  dismissButton: .default(Text("Got it")))
        }
    }

    // MARK: - Sections

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text("Tiny Gallery")
                .roundedFont(28, weight: .bold)
                .foregroundColor(Theme.ink)
            Text("Pick a picture for your necklace")
                .roundedFont(14)
                .foregroundColor(Theme.softInk)
        }
        .padding(.top, 6)
    }

    private var previewCard: some View {
        SoftCard {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.ink.opacity(0.06))

                    if let artwork = model.artwork {
                        Image(decorative: artwork.preview, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(CGFloat(PanelSpec.landscapeAspectRatio), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(6)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 30, weight: .light))
                                .foregroundColor(Theme.softInk.opacity(0.6))
                            Text("Nothing on the panel yet")
                                .roundedFont(13)
                                .foregroundColor(Theme.softInk)
                        }
                    }

                    if model.isRendering {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.paper.opacity(0.7))
                        ProgressView().tint(Theme.softInk)
                    }
                }
                .aspectRatio(CGFloat(PanelSpec.landscapeAspectRatio), contentMode: .fit)
                .animation(.easeInOut(duration: 0.2), value: model.artwork?.id)

                Text(model.hasPhoto
                     ? "Exactly what the necklace will show - \(PanelSpec.width) x \(PanelSpec.height), \(PanelSpec.payloadByteCount) bytes."
                     : "Snap something or pick a favourite to see the preview.")
                    .roundedFont(12)
                    .foregroundColor(Theme.softInk)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if CameraPicker.isAvailable {
                Button {
                    model.isShowingCamera = true
                } label: {
                    Label("Snap a photo", systemImage: "camera.fill")
                }
                .buttonStyle(SquishyButtonStyle())
            }

            Button {
                model.isShowingPhotoPicker = true
            } label: {
                Label("Pick from gallery", systemImage: "photo.stack.fill")
            }
            .buttonStyle(SquishyButtonStyle(fill: AnyShapeStyle(Theme.paper),
                                            foreground: Theme.ink))

            if model.hasPhoto {
                Button {
                    model.upload()
                } label: {
                    Label("Upload to necklace", systemImage: "arrow.up.heart.fill")
                }
                .buttonStyle(SquishyButtonStyle(fill: AnyShapeStyle(
                    LinearGradient(colors: [Theme.mint, Theme.lilac],
                                   startPoint: .leading,
                                   endPoint: .trailing))))
                .disabled(model.overlayPhase != nil)

                Button("Choose a different photo") {
                    withAnimation { model.startOver() }
                }
                .roundedFont(14, weight: .medium)
                .foregroundColor(Theme.softInk)
                .padding(.top, 2)

                ConnectionHint(ble: model.ble)
            }
        }
    }
}

/// Reminder that uploading will connect on demand. Kept as its own view so it
/// observes the manager directly and refreshes with the connection state.
private struct ConnectionHint: View {
    @ObservedObject var ble: NecklaceBLEManager

    var body: some View {
        if !ble.state.isReady {
            Text("Not connected yet - uploading will go find your necklace first.")
                .roundedFont(12)
                .foregroundColor(Theme.softInk.opacity(0.9))
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    ContentView()
}

import CoreGraphics
import SwiftUI

/// Frames a photo to the panel's exact aspect ratio.
///
/// The crop window is locked to 212:104 (or 104:212 for portrait framing), so
/// whatever the user lines up here is exactly what gets dithered - there is no
/// hidden letterboxing or stretching later in the pipeline.
struct CropView: View {

    let source: CGImage
    var onCancel: () -> Void
    var onConfirm: (CropSelection) -> Void

    @State private var isPortraitFrame: Bool
    @State private var turnsClockwise = true
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 8

    init(source: CGImage,
         onCancel: @escaping () -> Void,
         onConfirm: @escaping (CropSelection) -> Void) {
        self.source = source
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _isPortraitFrame = State(initialValue: source.height > source.width)
    }

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.08, blue: 0.13).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                GeometryReader { geometry in
                    cropStage(in: geometry.size)
                        .onAppear { containerSize = geometry.size }
                        .onChange(of: geometry.size) { newValue in
                            containerSize = newValue
                            clampTransform()
                        }
                }

                controls
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .roundedFont(16, weight: .medium)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            VStack(spacing: 2) {
                Text("Frame it")
                    .roundedFont(17, weight: .semibold)
                    .foregroundColor(.white)
                Text("\(PanelSpec.width) x \(PanelSpec.height) pixels")
                    .roundedFont(12)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            Button {
                confirm()
            } label: {
                Text("Use")
                    .roundedFont(16, weight: .bold)
                    .foregroundColor(Theme.blush)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func cropStage(in size: CGSize) -> some View {
        let window = windowSize(in: size)
        let display = displaySize(window: window, scale: liveScale)
        let translation = clamped(offset: liveOffset, display: display, window: window)

        return ZStack {
            photo(display: display, translation: translation)
                .opacity(0.28)

            photo(display: display, translation: translation)
                .mask(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .frame(width: window.width, height: window.height)
                )

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: window.width, height: window.height)
                .shadow(color: .black.opacity(0.35), radius: 10)

            // Gestures live on a transparent layer so panning works anywhere.
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(window: window))
                .simultaneousGesture(magnifyGesture(window: window))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func photo(display: CGSize, translation: CGSize) -> some View {
        Image(decorative: source, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .frame(width: display.width, height: display.height)
            .offset(translation)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                orientationChip(title: "Landscape", symbol: "rectangle", portrait: false)
                orientationChip(title: "Portrait", symbol: "rectangle.portrait", portrait: true)
            }

            if isPortraitFrame {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { turnsClockwise.toggle() }
                } label: {
                    Label(turnsClockwise ? "Top points right" : "Top points left",
                          systemImage: turnsClockwise ? "rotate.right" : "rotate.left")
                        .roundedFont(14, weight: .medium)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }

                Text("Portrait shots get a quarter turn so they fill the wide panel.")
                    .roundedFont(12)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            } else {
                Text("Pinch to zoom, drag to reposition.")
                    .roundedFont(12)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
        .padding(.top, 10)
    }

    private func orientationChip(title: String, symbol: String, portrait: Bool) -> some View {
        let selected = isPortraitFrame == portrait
        return Button {
            guard isPortraitFrame != portrait else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isPortraitFrame = portrait
                scale = 1
                offset = .zero
            }
        } label: {
            Label(title, systemImage: symbol)
                .roundedFont(14, weight: selected ? .semibold : .regular)
                .foregroundColor(selected ? Theme.ink : .white.opacity(0.8))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(selected ? Color.white : Color.white.opacity(0.12))
                )
        }
    }

    // MARK: - Gestures

    private var liveScale: CGFloat {
        min(max(scale * pinch, minScale), maxScale)
    }

    private var liveOffset: CGSize {
        CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
    }

    private func dragGesture(window: CGSize) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = clamped(offset: CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height),
                                 display: displaySize(window: window, scale: scale),
                                 window: window)
            }
    }

    private func magnifyGesture(window: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = min(max(scale * value, minScale), maxScale)
                offset = clamped(offset: offset,
                                 display: displaySize(window: window, scale: scale),
                                 window: window)
            }
    }

    private func clampTransform() {
        let window = windowSize(in: containerSize)
        scale = min(max(scale, minScale), maxScale)
        offset = clamped(offset: offset, display: displaySize(window: window, scale: scale), window: window)
    }

    // MARK: - Geometry

    private var frameAspectRatio: CGFloat {
        isPortraitFrame ? CGFloat(PanelSpec.portraitAspectRatio) : CGFloat(PanelSpec.landscapeAspectRatio)
    }

    /// The fixed-aspect crop window, fitted into whatever space we were given.
    private func windowSize(in container: CGSize) -> CGSize {
        let available = CGSize(width: max(container.width - 40, 1),
                               height: max(container.height - 40, 1))
        if available.width / available.height > frameAspectRatio {
            return CGSize(width: available.height * frameAspectRatio, height: available.height)
        } else {
            return CGSize(width: available.width, height: available.width / frameAspectRatio)
        }
    }

    /// Size of the photo on screen at a given zoom. At scale 1 the photo
    /// exactly covers the crop window (aspect fill), so there is never a gap.
    private func displaySize(window: CGSize, scale: CGFloat) -> CGSize {
        let imageWidth = CGFloat(source.width)
        let imageHeight = CGFloat(source.height)
        guard imageWidth > 0, imageHeight > 0 else { return window }
        let fill = max(window.width / imageWidth, window.height / imageHeight)
        return CGSize(width: imageWidth * fill * scale, height: imageHeight * fill * scale)
    }

    /// Keeps the crop window fully covered by the photo.
    private func clamped(offset: CGSize, display: CGSize, window: CGSize) -> CGSize {
        let limitX = max(0, (display.width - window.width) / 2)
        let limitY = max(0, (display.height - window.height) / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    // MARK: - Result

    private func confirm() {
        let window = windowSize(in: containerSize)
        let display = displaySize(window: window, scale: scale)
        let translation = clamped(offset: offset, display: display, window: window)

        // Where the crop window sits inside the on-screen photo, converted
        // back into source pixels. SwiftUI's y grows downwards, and so does
        // CGImage.cropping's, so no flip is needed here.
        let originX = display.width / 2 - window.width / 2 - translation.width
        let originY = display.height / 2 - window.height / 2 - translation.height
        let pixelsPerPoint = display.width > 0 ? CGFloat(source.width) / display.width : 1

        let rect = CGRect(x: originX * pixelsPerPoint,
                          y: originY * pixelsPerPoint,
                          width: window.width * pixelsPerPoint,
                          height: window.height * pixelsPerPoint)

        let rotation: PanelRotation = isPortraitFrame
            ? (turnsClockwise ? .clockwise : .counterClockwise)
            : .none

        onConfirm(CropSelection(source: source, rect: rect, rotation: rotation))
    }
}

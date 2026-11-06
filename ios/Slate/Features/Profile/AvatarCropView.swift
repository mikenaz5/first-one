import SwiftUI
import UIKit

/// "Move and scale": the person drags and pinches the photo until the part they want sits inside the circle, then taps Choose.
/// What is saved is the square under the circle (the profile photo is shown round everywhere).
struct AvatarCropView: View {
    let photo: WorkingPhoto
    let onCancel: () -> Void
    let onDone: (Data) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// The zoom and offset when the current pinch or drag began, so the gesture adds to them instead of restarting.
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    /// The circle's size on screen, kept up to date by the layout below so Choose and the slider can use it.
    @State private var cropSide: CGFloat = 0
    @State private var isSaving = false
    @State private var failed = false

    private var pixelSize: CGSize {
        let size = photo.image.size   // scale 1, so points are pixels
        return CGSize(width: size.width, height: size.height)
    }

    private var geometry: CropGeometry {
        CropGeometry(imageSize: pixelSize, cropSide: max(cropSide, 1))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(min(proxy.size.width - Space.xl * 2, proxy.size.height * 0.62), 120)
                let live = CropGeometry(imageSize: pixelSize, cropSide: side)
                VStack(spacing: Space.xl) {
                    canvas(side: side, live: live, width: proxy.size.width)
                    controls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear { cropSide = side }
                .onChange(of: side) { _, new in
                    cropSide = new
                    offset = CropGeometry(imageSize: pixelSize, cropSide: new).clampedOffset(offset, atZoom: zoom)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Move and scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Choose") { choose() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert("Couldn't use that photo", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try a different photo.")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: Pieces

    /// The photo, dimmed everywhere except inside the circle.
    private func canvas(side: CGFloat, live: CropGeometry, width: CGFloat) -> some View {
        let shown = live.displaySize(atZoom: zoom)
        let place = live.clampedOffset(offset, atZoom: zoom)
        return ZStack {
            Image(uiImage: photo.image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .offset(place)
            CropMask(side: side)
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                .frame(width: side, height: side)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: side + Space.xl * 2)
        .clipped()
        .contentShape(Rectangle())
        .gesture(drag(live))
        .simultaneousGesture(pinch(live))
        .onTapGesture(count: 2) { toggleZoom(live) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile photo")
        .accessibilityHint("Use the zoom control to zoom, or the move actions to move the photo inside the circle")
        .accessibilityValue("Zoom \(Int((zoom * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            nudgeZoom(direction == .increment ? 0.5 : -0.5)
        }
        .accessibilityAction(named: "Move photo left") { nudge(dx: -48, dy: 0) }
        .accessibilityAction(named: "Move photo right") { nudge(dx: 48, dy: 0) }
        .accessibilityAction(named: "Move photo up") { nudge(dx: 0, dy: -48) }
        .accessibilityAction(named: "Move photo down") { nudge(dx: 0, dy: 48) }
    }

    private var controls: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(systemName: "minus.magnifyingglass")
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { zoom },
                        set: { newValue in
                            zoom = geometry.clampedZoom(newValue)
                            offset = geometry.clampedOffset(offset, atZoom: zoom)
                        }
                    ),
                    in: 1...CropGeometry.maxZoom
                )
                .accessibilityLabel("Zoom")
                .accessibilityValue("\(Int((zoom * 100).rounded())) percent")
                Image(systemName: "plus.magnifyingglass")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.white.opacity(0.85))

            Text("Drag to move. Pinch or use the slider to zoom. Double-tap to zoom in and out.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Space.page)
    }

    // MARK: Gestures

    private func drag(_ live: CropGeometry) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? live.clampedOffset(offset, atZoom: zoom)
                dragStart = start
                let moved = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                offset = live.clampedOffset(moved, atZoom: zoom)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func pinch(_ live: CropGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = live.clampedZoom(start * value.magnification)
                offset = live.clampedOffset(offset, atZoom: zoom)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func toggleZoom(_ live: CropGeometry) {
        withAnimation(reduceMotion ? nil : .slateSpring) {
            zoom = zoom > 1.01 ? 1 : 2.5
            offset = live.clampedOffset(offset, atZoom: zoom)
        }
    }

    private func nudgeZoom(_ step: CGFloat) {
        zoom = geometry.clampedZoom(zoom + step)
        offset = geometry.clampedOffset(offset, atZoom: zoom)
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        let moved = CGSize(width: offset.width + dx, height: offset.height + dy)
        offset = geometry.clampedOffset(moved, atZoom: zoom)
    }

    // MARK: Choose

    private func choose() {
        guard !isSaving, cropSide > 0 else { return }
        isSaving = true
        let rect = geometry.sourceRect(atZoom: zoom, offset: offset)
        let picture = photo
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                PhotoCrop.croppedJPEG(from: picture, rect: rect)
            }.value
            isSaving = false
            if let data {
                onDone(data)
            } else {
                failed = true
            }
        }
    }
}

/// A full rectangle with a circle cut out of it (filled with the even-odd rule), used to dim all but the circle.
private struct CropMask: Shape {
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        return path
    }
}

import SwiftUI

// MARK: - A grid of a delivery's files

/// Square tiles for a delivery's files. Tapping one opens it; the creator side can remove a file from its menu.
struct FileGrid: View {
    let delivery: FileDelivery
    let bookingID: UUID
    /// Shown on the creator's side only: a way to take a file away.
    var onRemove: ((DeliveryFile) -> Void)?
    let onOpen: (DeliveryFile) -> Void

    private var shown: [DeliveryFile] {
        delivery.files.filter { $0.status != .removed }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.fileTileMinWidth), spacing: Metrics.gridSpacing)], spacing: Metrics.gridSpacing) {
            ForEach(shown) { file in
                Button {
                    onOpen(file)
                } label: {
                    FileTile(file: file, delivery: delivery, bookingID: bookingID)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(file))
                .accessibilityHint(file.status == .expired ? "" : "Opens it full screen")
                .contextMenu {
                    if let onRemove, file.status != .expired {
                        Button(role: .destructive) {
                            onRemove(file)
                        } label: {
                            Label("Remove from delivery", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }

    private func accessibilityLabel(_ file: DeliveryFile) -> String {
        var parts = [file.kind.title, file.name]
        if let duration = file.durationText { parts.append(duration) }
        if file.isSaved { parts.append("saved") }
        if file.status == .uploading { parts.append("still uploading") }
        if file.status == .expired { parts.append("expired") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One tile

struct FileTile: View {
    @Environment(AppModel.self) private var model

    let file: DeliveryFile
    let delivery: FileDelivery
    let bookingID: UUID

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.slateCard
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed || file.status == .expired {
                    Image(systemName: file.kind.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let duration = file.durationText {
                    Label(duration, systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(Space.xs)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                badge
                    .padding(Space.xs)
                    .accessibilityHidden(true)
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: file.id) {
                guard file.status != .expired else { return }
                if let loaded = await model.tileImage(for: file, in: delivery, bookingID: bookingID) {
                    image = loaded
                } else {
                    failed = true
                }
            }
    }

    @ViewBuilder
    private var badge: some View {
        if file.isSaved {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.slateOnAccent, Color.slateSuccess)
                .font(.title3)
        } else if file.status == .uploading {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.title3)
        }
    }
}

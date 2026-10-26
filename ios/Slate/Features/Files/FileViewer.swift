import AVKit
import SwiftUI

/// What the viewer is opened on: a file in a delivery.
struct FileViewerTarget: Identifiable, Equatable {
    var id: UUID { fileID }
    var deliveryID: UUID
    var fileID: UUID
}

// MARK: - Full screen

/// A delivery's files, one full screen at a time, swiping between them. A preview has no Save or Share: those appear only
/// when the backend says the originals can be opened.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let bookingID: UUID
    let target: FileViewerTarget

    @State private var selection: UUID
    @State private var reporting: DeliveryFile?
    @State private var exportItem: ExportItem?
    @State private var savedCount = 0

    init(bookingID: UUID, target: FileViewerTarget) {
        self.bookingID = bookingID
        self.target = target
        _selection = State(initialValue: target.fileID)
    }

    private var delivery: FileDelivery? {
        model.files(for: bookingID)?.deliveries.first { $0.id == target.deliveryID }
    }

    private var files: [DeliveryFile] {
        (delivery?.files ?? []).filter { $0.status == .ready || $0.status == .uploading }
    }

    private var current: DeliveryFile? { files.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            Group {
                if let delivery, !files.isEmpty {
                    TabView(selection: $selection) {
                        ForEach(files) { file in
                            FilePage(file: file, delivery: delivery, bookingID: bookingID)
                                .tag(file.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("These files aren't available any more", systemImage: "clock.badge.xmark")
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(current?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let current, let delivery {
                    ToolbarItem(placement: .primaryAction) {
                        actions(for: current, in: delivery)
                    }
                }
            }
            .sheet(item: $reporting) { file in
                ReportFileSheet(file: file)
            }
            .sheet(item: $exportItem) { item in
                ActivityView(items: [item.url]) { completed in
                    exportItem = nil
                    try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
                    if completed { Task { await model.markSaved(item.file, bookingID: bookingID); savedCount += 1 } }
                }
                .presentationDetents([.medium, .large])
            }
            .sensoryFeedback(.success, trigger: savedCount)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func actions(for file: DeliveryFile, in delivery: FileDelivery) -> some View {
        Menu {
            if delivery.originalsOpen, file.status == .ready {
                Button {
                    Task {
                        if await model.saveToPhotos(file, bookingID: bookingID) { savedCount += 1 }
                    }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task {
                        if let url = await model.downloadOriginal(file, bookingID: bookingID) {
                            exportItem = ExportItem(url: url, file: file)
                        }
                    }
                } label: {
                    Label("Save to Files…", systemImage: "folder")
                }
            }
            Button {
                reporting = file
            } label: {
                Label("Report this file", systemImage: "exclamationmark.bubble")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
        }
        .accessibilityLabel("More")
    }
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
    let file: DeliveryFile
}

// MARK: - One file

private struct FilePage: View {
    @Environment(AppModel.self) private var model

    let file: DeliveryFile
    let delivery: FileDelivery
    let bookingID: UUID

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false

    private var showsVideo: Bool {
        file.kind == .video && (delivery.originalsOpen || FileRules.previewIsVideo(kind: file.kind, deliveryKind: delivery.kind))
    }

    var body: some View {
        ZStack {
            if showsVideo {
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel("Video, \(file.name)")
                } else if failed {
                    unavailable
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                ZoomableImage(image: image)
                    .accessibilityLabel("\(file.kind.title), \(file.name)")
            } else if failed {
                unavailable
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file.id) { await load() }
        .onDisappear { player?.pause() }
    }

    private var unavailable: some View {
        ContentUnavailableView("Couldn't open this file", systemImage: file.kind.symbol, description: Text("Check your connection and try again."))
    }

    private func load() async {
        if showsVideo {
            guard let url = await model.videoURL(for: file, in: delivery, bookingID: bookingID) else {
                failed = true
                return
            }
            player = AVPlayer(url: url)
        } else if let loaded = await model.fullImage(for: file, in: delivery, bookingID: bookingID) {
            image = loaded
        } else {
            failed = true
        }
    }
}

// MARK: - Zoom

/// A picture that can be pinched, dragged when zoomed in, and double-tapped to zoom.
private struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = max(1, min(6, settledScale * value.magnification)) }
                    .onEnded { _ in
                        settledScale = scale
                        if scale <= 1 { reset() }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                    }
                    .onEnded { _ in settledOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.slateSnappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        settledScale = 2.5
                    }
                }
            }
            .accessibilityAddTraits(.isImage)
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}

// MARK: - The system's share sheet

/// The share sheet, for "Save to Files" and the like. `completion` says whether the person finished with an action.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var completion: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Reporting

struct ReportFileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let file: DeliveryFile

    @State private var reason = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's wrong with it?", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Report \(file.name)")
                } footer: {
                    Text("This goes to the \(AppConfig.productName) team. It isn't shown to the other person.")
                }
                .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Report a file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task {
                                isSending = true
                                let sent = await model.reportFile(file, reason: reason)
                                isSending = false
                                if sent { dismiss() }
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

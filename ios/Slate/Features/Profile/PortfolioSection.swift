import AVKit
import PhotosUI
import SwiftUI

/// The portfolio grid with a Photos/Reels filter. Owners can add, reorder and delete.
struct PortfolioSection: View {
    let items: [PortfolioItem]
    let isOwner: Bool

    @Environment(AppModel.self) private var model

    @State private var filter: PortfolioFilter = .all
    @State private var picks: [PhotosPickerItem] = []
    @State private var importer = PortfolioImporter()
    @State private var viewing: PortfolioItem?
    @State private var pendingDelete: PortfolioItem?
    @Namespace private var zoom

    private var filtered: [PortfolioItem] { items.filter(filter.matches) }
    private var remaining: Int { max(0, AppConfig.portfolioLimit - items.count) }

    /// Reels are portrait, so they get two wider columns; everything else is a tight square grid.
    private var columns: [GridItem] {
        let count = filter == .reels ? 2 : 3
        return Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing), count: count)
    }

    private var cellAspect: CGFloat { filter == .reels ? 9.0 / 16.0 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Portfolio") {
                if isOwner && remaining > 0 && !items.isEmpty {
                    addButton
                }
            }

            if items.isEmpty {
                emptyState
            } else {
                if items.contains(where: \.isVideo) && items.contains(where: { !$0.isVideo }) {
                    Picker("Show", selection: $filter.animation(.slateSmooth)) {
                        ForEach(PortfolioFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if filtered.isEmpty {
                    Text("Nothing here yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    grid
                }
            }

            if importer.isImporting {
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Adding \(min(importer.completed + 1, importer.total)) of \(importer.total)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(importer.skipped, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.slateWarning)
            }
        }
        .onChange(of: picks) { _, newPicks in
            guard !newPicks.isEmpty else { return }
            Task {
                let added = await importer.load(newPicks)
                picks = []
                await model.addPortfolio(added)
            }
        }
        .navigationDestination(item: $viewing) { item in
            PortfolioViewer(items: items, startID: item.id, namespace: zoom)
        }
        .confirmationDialog(
            "Delete this \(pendingDelete?.isVideo == true ? "reel" : "photo")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await model.deletePortfolioItem(item) }
            }
        }
        .sensoryFeedback(trigger: items.count) { old, new in new > old ? .success : .warning }
    }

    // MARK: Pieces

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
            ForEach(filtered) { item in
                Button {
                    viewing = item
                } label: {
                    PortfolioCell(item: item, aspect: cellAspect)
                }
                .buttonStyle(PressableTileStyle())
                .zoomSource(id: item.id, in: zoom)
                .contextMenu {
                    if isOwner {
                        if item.id != items.first?.id {
                            Button("Move to front", systemImage: "arrow.up.to.line") {
                                Task { await model.movePortfolioItemToFront(item) }
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            pendingDelete = item
                        }
                    }
                }
                .accessibilityLabel(item.accessibilityDescription)
                .accessibilityHint("Opens full screen")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .motionSafe(.slateSmooth, value: filter)
    }

    private var addButton: some View {
        PhotosPicker(
            selection: $picks,
            maxSelectionCount: remaining,
            matching: .any(of: [.images, .videos])
        ) {
            Label("Add", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Space.m)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .disabled(importer.isImporting)
        .accessibilityLabel("Add to portfolio")
    }

    @ViewBuilder
    private var emptyState: some View {
        if isOwner {
            PhotosPicker(
                selection: $picks,
                maxSelectionCount: AppConfig.portfolioLimit,
                matching: .any(of: [.images, .videos])
            ) {
                VStack(spacing: Space.s) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Add your best work").font(.headline)
                    Text("Photos and reels, up to \(AppConfig.portfolioLimit).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
            .disabled(importer.isImporting)
        } else {
            Text("No work to show yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }
}

// MARK: - Cell

struct PortfolioCell: View {
    let item: PortfolioItem
    let aspect: CGFloat

    var body: some View {
        Color.slateFill
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "play.fill")
                        if let duration = item.duration {
                            Text(Duration.seconds(Int(duration.rounded())).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(Space.xs)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

// MARK: - Viewer

/// Full-screen pager for photos and reels. Reels play when their page is showing.
struct PortfolioViewer: View {
    let items: [PortfolioItem]
    let namespace: Namespace.ID

    @State private var selection: PortfolioItem.ID

    init(items: [PortfolioItem], startID: PortfolioItem.ID, namespace: Namespace.ID) {
        self.items = items
        self.namespace = namespace
        _selection = State(initialValue: startID)
    }

    private var index: Int { items.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                PortfolioPage(item: item, isActive: item.id == selection)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("\(index + 1) of \(items.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .zoomDestination(sourceID: selection, in: namespace)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct PortfolioPage: View {
    let item: PortfolioItem
    let isActive: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottom) {
            media

            if !item.caption.isEmpty {
                Text(item.caption)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.4))
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                play()
            } else {
                player?.pause()
                player?.seek(to: .zero)
            }
        }
        .onDisappear { player?.pause() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityDescription)
    }

    @ViewBuilder
    private var media: some View {
        if item.isVideo, let player {
            VideoPlayer(player: player)
        } else {
            AsyncImage(url: item.imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
    }

    private func play() {
        guard item.isVideo, let url = item.videoURL else { return }
        if player == nil { player = AVPlayer(url: url) }
        player?.play()
    }
}

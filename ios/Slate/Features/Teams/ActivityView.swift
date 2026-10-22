import SwiftUI

/// Who changed what: bookings, contracts, prices and team members, newest first.
struct ActivityView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [ActivityEntry] = []
    @State private var phase: Phase = .loading
    @State private var reachedEnd = false
    @State private var isLoadingMore = false

    private enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    private let pageSize = 50

    var body: some View {
        List {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                    .listRowBackground(Color.clear)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't load activity", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
                .listRowBackground(Color.clear)
            case .ready:
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Changes to bookings, contracts, prices and the team are listed here, with who made them.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        ActivityRow(entry: entry)
                            .task { await loadMoreIfLast(entry) }
                    }
                    if isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        do {
            let first = try await model.loadActivity(limit: pageSize)
            entries = first
            reachedEnd = first.count < pageSize
            phase = .ready
        } catch {
            if entries.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    private func loadMoreIfLast(_ entry: ActivityEntry) async {
        guard entry.id == entries.last?.id, !reachedEnd, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let older = try? await model.loadActivity(before: entry.createdAt, limit: pageSize) else { return }
        let known = Set(entries.map(\.id))
        let fresh = older.filter { !known.contains($0.id) }
        entries += fresh
        reachedEnd = older.count < pageSize || fresh.isEmpty
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: entry.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(entry.summary).font(.subheadline)
                Text("\(entry.actorName) · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.xs)
        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

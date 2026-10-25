import SwiftUI

/// The explore grid under the search box on a client's Home: creators a client could book, best first (see
/// `FeaturedRules`), with a row of specialties to narrow it. With a place (a city they chose, or the one their phone
/// found), creators who work there come first and each tile says how far away it is. Tapping a tile opens that
/// creator's page.
struct FeaturedCreatorsSection: View {
    private enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    private struct LoadKey: Equatable {
        var specialty: Specialty?
        var reload: Int
        var place: GeoPoint?
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Changes when Home is pulled to refresh, so the grid reloads with everything else.
    var reload = 0

    @AppStorage("slate.featured.locationPromptDismissed") private var promptDismissed = false
    @State private var specialty: Specialty?
    @State private var creators: [FeaturedCreator] = []
    @State private var phase = Phase.loading
    @State private var finder = DeviceLocationFinder()
    @State private var findingPlace = false
    @State private var showCityPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Featured creators") { placeMenu }
            if model.clientPlace == nil && !promptDismissed {
                locationPrompt
            }
            filters
            content
        }
        .task(id: LoadKey(specialty: specialty, reload: reload, place: model.clientPlace?.point)) { await load() }
        .sheet(isPresented: $showCityPicker) {
            LocationPickerSheet { place in
                model.setClientPlace(ClientPlace(name: place.name, point: GeoPoint(latitude: place.latitude, longitude: place.longitude)))
            }
        }
    }

    // MARK: Where

    /// The place creators are measured from, and the way to change it.
    private var placeMenu: some View {
        Menu {
            Button {
                useMyLocation()
            } label: {
                Label("Use my current location", systemImage: "location")
            }
            Button {
                showCityPicker = true
            } label: {
                Label("Choose a city", systemImage: "magnifyingglass")
            }
            if model.clientPlace != nil {
                Button(role: .destructive) {
                    model.setClientPlace(nil)
                } label: {
                    Label("Don't use a place", systemImage: "xmark")
                }
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "mappin.and.ellipse")
                    .accessibilityHidden(true)
                Text(model.clientPlace?.name ?? "Near me")
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.slateAccentText)
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(model.clientPlace.map { "Creators near \($0.name)" } ?? "Choose where to look for creators")
        .accessibilityHint("Opens a menu to use your location or choose a city")
    }

    /// Shown until a place is chosen, and until it is waved away.
    private var locationPrompt: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("See creators near you")
                .font(.headline)
            Text("Creators who work in your area come first. Slate keeps only your city, on this phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AdaptiveStack(alignment: .center, spacing: Space.s) {
                Button {
                    useMyLocation()
                } label: {
                    if findingPlace {
                        ProgressView()
                    } else {
                        Text("Use my location")
                    }
                }
                .buttonStyle(.slatePrimary)
                .disabled(findingPlace)
                Button("Choose a city") { showCityPicker = true }
                    .buttonStyle(.slateOutline)
            }
            Button("Not now") { promptDismissed = true }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: Metrics.minTapTarget)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(.outlined)
    }

    private func useMyLocation() {
        guard !findingPlace else { return }
        findingPlace = true
        Task {
            defer { findingPlace = false }
            do {
                model.setClientPlace(try await finder.currentPlace())
            } catch {
                model.show(error, title: "Couldn't find where you are")
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.s) {
                ExploreAllChip(isSelected: specialty == nil) { specialty = nil }
                ForEach(Specialty.allCases) { option in
                    SpecialtyChip(specialty: option, isSelected: specialty == option) {
                        specialty = specialty == option ? nil : option
                    }
                }
            }
            .padding(.vertical, Space.xxs)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Tiles

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .failed(let message):
            VStack(spacing: Space.m) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .loaded:
            if creators.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.s) {
            Text(specialty.map { "Nobody who shoots \($0.title.lowercased()) yet" } ?? "No creators to show yet")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(specialty == nil ? "Creators appear here once they publish a package." : "Try another kind of work, or search by name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
        .card(.outlined)
    }

    private var grid: some View {
        // One tile across at the largest text sizes, where a caption wouldn't fit a half-width tile.
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: Metrics.exploreColumnMinWidth), spacing: Space.m)]
        return LazyVGrid(columns: columns, spacing: Space.m) {
            ForEach(creators) { creator in
                FeaturedTile(creator: creator)
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            creators = try await model.featuredCreators(specialty: specialty)
            phase = .loaded
        } catch {
            // A newer choice replaced this one: it is already loading, so say nothing about this one.
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// "All", first in the row of specialties. Looks like `SpecialtyChip`, without a specialty.
private struct ExploreAllChip: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("All")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Space.m)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(isSelected ? Color.slateOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.slateFill, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.slateHairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motionSafe(.slateSnappy, value: isSelected)
    }
}

/// One creator in the grid: their first picture, filling the tile, with their name, rating and starting price over it.
private struct FeaturedTile: View {
    @Environment(AppModel.self) private var model

    let creator: FeaturedCreator

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.m, style: .continuous) }

    var body: some View {
        Button {
            Task { await model.openCreatorPage(creator.id) }
        } label: {
            Color.slateFill
                .aspectRatio(Metrics.exploreTileAspect, contentMode: .fit)
                .overlay { cover }
                .overlay(alignment: .bottomLeading) { caption }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.slateHairline, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressableTileStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(creator.accessibilitySummary)
        .accessibilityHint("Opens their page so you can book")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Picture

    @ViewBuilder
    private var cover: some View {
        if let url = creator.coverURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// For a creator with no pictures yet, or while one loads: a soft colour of their own with their kind of work on it.
    private var placeholder: some View {
        let hue = Double(creator.id.uuid.0) / 255
        let nearby = hue < 0.9 ? hue + 0.08 : hue - 0.08
        return ZStack {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55), Color(hue: nearby, saturation: 0.65, brightness: 0.28)],
                startPoint: .top, endPoint: .bottom
            )
            Image(systemName: creator.profile.specialties.first?.symbol ?? "camera.aperture")
                .heroSymbol(40)
                .foregroundStyle(.white.opacity(0.4))
                .accessibilityHidden(true)
        }
    }

    /// "4 mi away" with a place chosen, otherwise the creator's city.
    private var whereLine: String? {
        if let distance = creator.distanceText { return "\(distance) away" }
        return creator.profile.location?.name
    }

    // MARK: Words over the picture

    private var caption: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(creator.profile.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: Space.xs) {
                if let average = creator.reviews.average {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.slateStar)
                        .accessibilityHidden(true)
                    Text(average.formatted(.number.precision(.fractionLength(1))))
                    Text("·").accessibilityHidden(true)
                }
                Text(creator.priceText)
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            if let line = whereLine {
                Text(line)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        // A dark fade under the words so they read on any picture.
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }
}

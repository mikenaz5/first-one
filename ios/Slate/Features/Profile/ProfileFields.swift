import Combine
import CoreLocation
import MapKit
import PhotosUI
import SwiftUI

// Form building blocks shared by onboarding and the Edit Profile sheet.

// MARK: - Avatar picker

struct AvatarPicker: View {
    @Bindable var draft: ProfileDraft
    var size: CGFloat = Metrics.avatarXL

    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: draft.displayName, url: draft.avatarURL, imageData: draft.avatarJPEG, size: size)

                Image(systemName: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.slateOnAccent)
                    .frame(width: Metrics.badge, height: Metrics.badge)
                    .background(Color.accentColor, in: Circle())
                    .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Profile photo")
        .accessibilityHint("Choose a photo from your library")
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { await load(newItem) }
        }
        .motionSafe(.slateSpring, value: draft.avatarJPEG)
    }

    private func load(_ pick: PhotosPickerItem) async {
        defer { item = nil }
        guard let data = try? await pick.loadTransferable(type: Data.self) else { return }
        let processed = await Task.detached(priority: .userInitiated) {
            MediaProcessing.jpeg(from: data, maxPixel: 1024, quality: 0.85)
        }.value
        if let processed {
            draft.avatarJPEG = processed.data
        }
    }
}

// MARK: - Handle

/// The `slate.example/<handle>` row, with a debounced availability check.
struct HandleField: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text("\(AppConfig.bookingLinkHost)/")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("yourname", text: $draft.handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.next)
                .accessibilityLabel("Booking link name")
            statusIcon
                .frame(width: 28, height: Metrics.minTapTarget)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .onChange(of: draft.handle) { _, _ in
            draft.normalizeHandle()
        }
        .task(id: draft.handle) {
            await checkAvailability()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch draft.handleStatus {
        case .checking:
            ProgressView()
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.slateSuccess)
                .accessibilityLabel("Available")
        case .taken:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.slateDanger)
                .accessibilityLabel("Taken")
        case .idle, .failed:
            EmptyView()
        }
    }

    private func checkAvailability() async {
        guard draft.handleProblem == nil else {
            draft.handleStatus = .idle
            return
        }
        draft.handleStatus = .checking
        try? await Task.sleep(for: .milliseconds(450)) // Wait for typing to pause.
        guard !Task.isCancelled else { return }
        do {
            let free = try await model.isHandleAvailable(draft.handle)
            guard !Task.isCancelled else { return }
            draft.handleStatus = free ? .available : .taken
        } catch {
            guard !Task.isCancelled else { return }
            draft.handleStatus = .failed
        }
    }
}

/// One line under the handle field explaining its state.
struct HandleStatusText: View {
    let draft: ProfileDraft

    var body: some View {
        Group {
            if draft.handle.isEmpty {
                Text("This is the link you'll share with clients.")
            } else if let problem = draft.handleProblem {
                Text(problem.message).foregroundStyle(Color.slateDanger)
            } else {
                switch draft.handleStatus {
                case .taken: Text("That name is already taken.").foregroundStyle(Color.slateDanger)
                case .available: Text("Available").foregroundStyle(Color.slateSuccess)
                case .failed: Text("Couldn't check right now. We'll confirm when you save.")
                case .idle, .checking: Text("This is the link you'll share with clients.")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Specialties

struct SpecialtyPicker: View {
    @Bindable var draft: ProfileDraft
    @State private var limitHit = 0

    var body: some View {
        FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
            ForEach(Specialty.allCases) { specialty in
                SpecialtyChip(specialty: specialty, isSelected: draft.isSelected(specialty)) {
                    if !draft.toggle(specialty) { limitHit += 1 }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: draft.specialties)
        .sensoryFeedback(.warning, trigger: limitHit)
    }
}

// MARK: - Bio

struct BioField: View {
    @Bindable var draft: ProfileDraft

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            TextField(
                "What you shoot, your style, how you work with clients",
                text: $draft.bio,
                axis: .vertical
            )
            .lineLimit(5...10)
            .frame(minHeight: Metrics.minTapTarget, alignment: .topLeading)
            .onChange(of: draft.bio) { _, _ in draft.clampBio() }

            Text("\(draft.bio.count)/\(AppConfig.bioLimit)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(draft.bio.count >= AppConfig.bioLimit ? Color.slateWarning : Color.secondary)
                .accessibilityLabel("\(draft.bio.count) of \(AppConfig.bioLimit) characters")
        }
    }
}

// MARK: - Location

struct LocationField: View {
    @Bindable var draft: ProfileDraft
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                        .frame(minWidth: Metrics.iconColumn)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(draft.location?.name ?? "Choose your city")
                            .font(.body.weight(draft.location == nil ? .regular : .semibold))
                            .foregroundStyle(draft.location == nil ? Color.secondary : Color.primary)
                        if draft.location != nil {
                            Text("Home base").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Searches for your city")

            if draft.location != nil {
                TravelRadiusPicker(draft: draft)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motionSafe(.slateSmooth, value: draft.location != nil)
        .sheet(isPresented: $showPicker) {
            LocationPickerSheet { place in
                draft.setPlace(name: place.name, latitude: place.latitude, longitude: place.longitude)
            }
        }
        .sensoryFeedback(.success, trigger: draft.location?.name)
    }
}

struct TravelRadiusPicker: View {
    @Bindable var draft: ProfileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("I'll travel up to").font(.subheadline).foregroundStyle(.secondary)
            Picker("Travel radius", selection: Binding(
                get: { TravelRadius.nearestPreset(to: draft.location?.travelRadiusKm ?? TravelRadius.defaultKm) },
                set: { draft.setTravelRadius($0) }
            )) {
                ForEach(TravelRadius.presets(), id: \.self) { km in
                    Text(TravelRadius.label(km: km)).tag(km)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Location search

struct PlaceSelection {
    var name: String
    var latitude: Double
    var longitude: Double
}

@MainActor
final class LocationSearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = ""
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var isResolving = false

    private let completer = MKLocalSearchCompleter()
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        cancellable = $query
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.results = []
                } else {
                    self.completer.queryFragment = text
                }
            }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = completer.results
        Task { @MainActor in self.results = found }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }

    /// Resolves a suggestion to a city-level place. Street addresses are never stored.
    func resolve(_ completion: MKLocalSearchCompletion) async -> PlaceSelection? {
        isResolving = true
        defer { isResolving = false }
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let item = response.mapItems.first else { return nil }
            let placemark = item.placemark
            let parts = [placemark.locality, placemark.administrativeArea ?? placemark.country]
            let name = parts.compactMap { $0 }.joined(separator: ", ")
            // ~1 km precision is plenty for "where do you work", and keeps exact spots private.
            let latitude = (placemark.coordinate.latitude * 100).rounded() / 100
            let longitude = (placemark.coordinate.longitude * 100).rounded() / 100
            return PlaceSelection(
                name: name.isEmpty ? completion.title : name,
                latitude: latitude,
                longitude: longitude
            )
        } catch {
            return nil
        }
    }
}

struct LocationPickerSheet: View {
    var onSelect: (PlaceSelection) -> Void

    @StateObject private var search = LocationSearchModel()
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if search.results.isEmpty {
                    ContentUnavailableView {
                        Label("Find your city", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search for the city or town you're based in.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(search.results, id: \.self) { completion in
                        Button {
                            Task {
                                if let place = await search.resolve(completion) {
                                    onSelect(place)
                                    dismiss()
                                } else {
                                    failed = true
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(completion.title).foregroundStyle(.primary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or town")
            .navigationTitle("Home base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if search.isResolving { ProgressView() }
            }
            .alert("Couldn't find that place", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try another search.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

import SwiftUI

/// The Profile tab: the creator's own page, with editing and account actions.
struct ProfileView: View {
    @Environment(AppModel.self) private var model

    @State private var showEditor = false
    @State private var showPreview = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let profile = model.profile {
                    CreatorPageView(profile: profile, portfolio: model.portfolio, mode: .owner)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountButton()
                }
                if model.can(.companyEdit) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showEditor = true }
                            .disabled(model.profile == nil)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Preview as a client", systemImage: "eye") { showPreview = true }
                        if let url = model.profile.flatMap({ AppConfig.bookingURL(handle: $0.handle) }) {
                            ShareLink(item: url) {
                                Label("Share booking link", systemImage: "square.and.arrow.up")
                            }
                        }
                        Divider()
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    }
                    .accessibilityLabel("More")
                }
            }
            .navigationDestination(isPresented: $showPreview) {
                if let profile = model.profile {
                    CreatorPageView(
                        profile: profile, portfolio: model.portfolio, packages: model.publishedPackages,
                        team: model.publicTeam, mode: .preview
                    )
                        .navigationTitle("Client view")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showEditor) {
                if let profile = model.profile {
                    EditProfileSheet(profile: profile)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

// MARK: - Shared creator page

/// How a creator's page looks. `owner` adds editing affordances; `preview` is what clients see.
struct CreatorPageView: View {
    /// `owner` is your own page with editing tools, `preview` is your page as a client sees it,
    /// and `client` is someone else's page opened from a booking link.
    enum Mode { case owner, preview, client }

    let profile: CreatorProfile
    let portfolio: [PortfolioItem]
    var packages: [ServicePackage] = []
    /// For a company's page: the people a client can book directly.
    var team: [PublicTeamMember] = []
    let mode: Mode

    @Environment(AppModel.self) private var model
    @State private var bookingTarget: BookingTarget?
    /// A person the client has chosen to book directly. Nil means whoever is free.
    @State private var chosenMember: UUID?

    /// Editing tools show only on your own page, and only to a role that may change it.
    private var canEditPage: Bool { mode == .owner && model.can(.companyEdit) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if mode == .preview {
                    Label("This is how clients see your page. Bookings made here are test bookings.", systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                header

                if canEditPage, let completeness = model.completeness, !completeness.isComplete {
                    CompletenessCard(completeness: completeness)
                }

                if mode != .owner {
                    if !team.isEmpty {
                        teamSection
                    }
                    packagesSection
                }

                PortfolioSection(items: portfolio, isOwner: canEditPage)

                ReviewsSection(creatorID: profile.id, isOwner: mode == .owner)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: Metrics.pageWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await model.refresh()
            await model.loadReviews(for: profile.id)
        }
        .slatePageBackground()
        .sheet(item: $bookingTarget) { target in
            BookingSheet(creator: profile, package: target.package, team: team, memberID: target.memberID)
        }
    }

    private var chosenName: String {
        team.first(where: { $0.userID == chosenMember })?.displayName ?? "them"
    }

    private struct BookingTarget: Identifiable {
        let package: ServicePackage
        let memberID: UUID?
        var id: UUID { package.id }
    }

    /// A company's people. Choosing one books them directly; leaving it alone books whoever is free.
    private var teamSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Book a person")
            ScrollView(.horizontal) {
                HStack(spacing: Space.m) {
                    ForEach(team) { person in
                        TeamPersonTile(person: person, isChosen: chosenMember == person.userID) {
                            withAnimation(.slateSnappy) {
                                chosenMember = chosenMember == person.userID ? nil : person.userID
                            }
                        }
                    }
                }
                .padding(.vertical, Space.xxs)
            }
            .scrollIndicators(.hidden)
            Text(chosenMember == nil
                 ? "Or choose a service below and we'll match you with whoever is free."
                 : "Choose a service below to book \(chosenName).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sensoryFeedback(.selection, trigger: chosenMember)
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Packages")
            if packages.isEmpty {
                Text("No packages to book yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                    .card(.outlined)
            } else {
                ForEach(packages) { package in
                    Button {
                        bookingTarget = BookingTarget(package: package, memberID: chosenMember)
                    } label: {
                        PackageCard(package: package, style: .client)
                    }
                    .buttonStyle(PressableTileStyle())
                    .accessibilityHint("Opens booking")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: Space.m) {
            AvatarView(name: profile.displayName, url: profile.avatarURL, size: Metrics.avatarL)

            VStack(spacing: Space.xs) {
                Text(profile.displayName)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("\(AppConfig.bookingLinkHost)/\(profile.handle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let location = profile.location {
                Label("\(location.name) · travels up to \(TravelRadius.label(km: location.travelRadiusKm))",
                      systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !profile.specialties.isEmpty {
                FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                    ForEach(profile.specialties) { specialty in
                        TagChip(title: specialty.title, symbol: specialty.symbol)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if mode == .owner {
                Text("Add a short bio so clients know what to expect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: Space.xl)
    }
}

// MARK: - Team

/// One person on a company's page, to choose when booking.
private struct TeamPersonTile: View {
    let person: PublicTeamMember
    let isChosen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                AvatarView(name: person.displayName, url: person.avatarURL, size: Metrics.avatarM)
                    .overlay(alignment: .bottomTrailing) {
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.slateOnAccent, Color.accentColor)
                                .font(.title3)
                                .accessibilityHidden(true)
                        }
                    }
                VStack(spacing: Space.xxs) {
                    Text(person.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !person.title.isEmpty {
                        Text(person.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(minWidth: Metrics.avatarL, minHeight: Metrics.minTapTarget)
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .fill(Color.slateCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(isChosen ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isChosen ? "Tap to book whoever is free instead" : "Books \(person.displayName) directly")
    }
}

// MARK: - Completeness

struct CompletenessCard: View {
    let completeness: ProfileCompleteness

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Finish your page").font(.headline)
                Spacer()
                Text("\(Int((completeness.fraction * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: completeness.fraction)
                .tint(Color.accentColor)
                .motionSafe(.slateSmooth, value: completeness.fraction)

            if let next = completeness.nextStep {
                Label(next.title, systemImage: "circle.dashed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finish your page, \(Int((completeness.fraction * 100).rounded())) percent complete")
    }
}

#Preview("Profile (empty model)") {
    ProfileView()
        .environment(AppModel(backend: LocalBackend(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-profile"))))
}

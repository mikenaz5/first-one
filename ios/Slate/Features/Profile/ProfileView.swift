import SwiftUI

/// The Profile tab: the creator's own page, with editing and account actions.
struct ProfileView: View {
    @Environment(AppModel.self) private var model

    @State private var showEditor = false
    @State private var showPreview = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEditor = true }
                        .disabled(model.profile == nil)
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
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            confirmSignOut = true
                        }
                        Button("Delete account…", systemImage: "trash", role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    }
                    .accessibilityLabel("More")
                }
            }
            .navigationDestination(isPresented: $showPreview) {
                if let profile = model.profile {
                    CreatorPageView(profile: profile, portfolio: model.portfolio, packages: model.publishedPackages, mode: .preview)
                        .navigationTitle("Client view")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showEditor) {
                if let profile = model.profile {
                    EditProfileSheet(profile: profile)
                }
            }
            .confirmationDialog("Sign out of Slate?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            } message: {
                Text("This permanently deletes your profile and portfolio. This can't be undone.")
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
    let mode: Mode

    @Environment(AppModel.self) private var model
    @State private var bookingTarget: ServicePackage?

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

                if mode == .owner, let completeness = model.completeness, !completeness.isComplete {
                    CompletenessCard(completeness: completeness)
                }

                if mode != .owner {
                    packagesSection
                }

                PortfolioSection(items: portfolio, isOwner: mode == .owner)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refresh() }
        .slatePageBackground()
        .sheet(item: $bookingTarget) { package in
            BookingSheet(creator: profile, package: package)
        }
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Packages")
            if packages.isEmpty {
                Text("No packages to book yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .card(.outlined)
            } else {
                ForEach(packages) { package in
                    Button {
                        bookingTarget = package
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

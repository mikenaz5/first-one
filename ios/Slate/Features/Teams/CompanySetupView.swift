import SwiftUI

/// The form for a company: its name, logo, link, the name on contracts, what it shoots, a bio and a home base.
/// Used when someone starts a company from scratch, when an individual upgrades, and in onboarding.
struct CompanySetupView: View {
    enum Mode { case new, upgrade }

    let mode: Mode
    /// Set when this is a step in onboarding: it shows its own back button and button bar, and goes back to the
    /// choice of account type.
    var onBack: (() -> Void)?
    /// Called once the company exists, so a sheet around this can close.
    var onDone: (() -> Void)?

    @Environment(AppModel.self) private var model

    @State private var draft = ProfileDraft()
    @State private var legalName = ""
    @State private var legalTouched = false
    @State private var legalAddress = ""
    @State private var ownerName = ""
    @State private var prepared = false
    @State private var isSaving = false
    @State private var created = false

    private var isOnboarding: Bool { onBack != nil }
    /// A person starting out with a company has no profile of their own yet, so the team needs a name for them.
    private var needsOwnerName: Bool { model.personalProfile == nil }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var organizationDraft: OrganizationDraft {
        OrganizationDraft(
            name: draft.trimmedName,
            handle: draft.handle,
            legalName: trimmed(legalName),
            legalAddress: trimmed(legalAddress),
            bio: trimmed(draft.bio),
            specialties: draft.specialties,
            ownerDisplayName: needsOwnerName ? trimmed(ownerName) : nil
        )
    }

    private var canCreate: Bool {
        draft.identityIsValid
            && draft.specialtiesAreValid
            && organizationDraft.problem == nil
            && (!needsOwnerName || !trimmed(ownerName).isEmpty)
            && !isSaving
    }

    private var buttonTitle: String { mode == .upgrade ? "Upgrade to a company" : "Create company" }

    var body: some View {
        Group {
            if isOnboarding {
                onboardingBody
            } else {
                navigationBody
            }
        }
        .onAppear(perform: prepare)
        .sensoryFeedback(.success, trigger: created)
    }

    // MARK: Layouts

    private var navigationBody: some View {
        Form { fields }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode == .upgrade ? "Your company" : "New company")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(mode == .upgrade ? "Upgrade" : "Create") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!canCreate)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
    }

    private var onboardingBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onBack?()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
                .disabled(isSaving)
                Spacer()
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.xs)

            VStack(alignment: .leading, spacing: Space.s) {
                Text("Set up your company")
                    .font(SlateFont.display)
                    .accessibilityAddTraits(.isHeader)
                Text("Your team shares this page, and clients book it. You can change all of it later.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)

            Form { fields }
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
        }
        .slatePageBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(Color.slateOnAccent)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slatePrimary)
            .controlSize(.large)
            .disabled(!canCreate)
            .accessibilityHint(canCreate ? "" : "Complete the required fields to continue")
            .padding(.horizontal, Space.page)
            .padding(.top, Space.m)
            .padding(.bottom, Space.s)
            .background(.bar)
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        Section {
            AvatarPicker(draft: draft, size: Metrics.avatarL)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } footer: {
            Text("Your logo, or a photo of the team.")
                .frame(maxWidth: .infinity)
        }
            .listRowBackground(Color.slateCard)

        Section("Company name") {
            TextField("Northlight Films", text: $draft.displayName)
                .textContentType(.organizationName)
                .frame(minHeight: Metrics.minTapTarget)
                .onChange(of: draft.displayName) { _, name in
                    draft.updateSuggestedHandle()
                    if !legalTouched { legalName = name }
                }
        }
            .listRowBackground(Color.slateCard)

        Section {
            HandleField(draft: draft)
        } header: {
            Text("Booking link")
        } footer: {
            HandleStatusText(draft: draft)
        }
            .listRowBackground(Color.slateCard)

        Section {
            TextField("Legal name", text: Binding(
                get: { legalName },
                set: { legalName = $0; legalTouched = true }
            ))
            .frame(minHeight: Metrics.minTapTarget)
            TextField("Address (optional)", text: $legalAddress, axis: .vertical)
                .lineLimit(2...4)
                .textContentType(.fullStreetAddress)
                .frame(minHeight: Metrics.minTapTarget, alignment: .topLeading)
        } header: {
            Text("On contracts")
        } footer: {
            Text("Every contract is made in this name, and signed for the company by someone you choose.")
        }
            .listRowBackground(Color.slateCard)

        Section {
            SpecialtyPicker(draft: draft)
                .padding(.vertical, Space.xs)
        } header: {
            Text("What the company shoots")
        } footer: {
            Text("\(draft.specialties.count) of \(AppConfig.maxSpecialties) selected")
        }
            .listRowBackground(Color.slateCard)

        Section("About") {
            BioField(draft: draft)
        }
            .listRowBackground(Color.slateCard)

        Section("Home base") {
            LocationField(draft: draft)
        }
            .listRowBackground(Color.slateCard)

        if needsOwnerName {
            Section {
                TextField("Your name", text: $ownerName)
                    .textContentType(.name)
                    .frame(minHeight: Metrics.minTapTarget)
            } header: {
                Text("You")
            } footer: {
                Text("How your team sees you. You'll be the company's Owner.")
            }
                .listRowBackground(Color.slateCard)
        }
    }

    // MARK: Actions

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        draft.isNewAccount = true
        ownerName = model.session?.fullName ?? ""
        if mode == .upgrade, let personal = model.personalProfile {
            // The company starts from the person's own description of their work; the name and link are new.
            draft.bio = personal.bio
            draft.specialties = personal.specialties
            draft.location = personal.location
        }
    }

    private func save() async {
        guard canCreate else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch mode {
            case .new:
                try await model.createCompany(organizationDraft, location: draft.location, avatarJPEG: draft.avatarJPEG)
            case .upgrade:
                try await model.upgradeToCompany(organizationDraft, location: draft.location, avatarJPEG: draft.avatarJPEG)
            }
            created = true
            onDone?()
        } catch SlateError.handleTaken {
            draft.handleStatus = .taken
            model.show(SlateError.handleTaken, title: "Choose another link name")
        } catch {
            model.show(error, title: mode == .upgrade ? "Couldn't upgrade" : "Couldn't start your company")
        }
    }
}

// MARK: - Sheets

/// Starting another company from the account switcher.
struct NewCompanySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CompanySetupView(mode: .new, onDone: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Moving an individual account up to a company: what moves, what stays, then the company's details.
struct UpgradeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Move up to a company")
                            .font(SlateFont.display)
                            .accessibilityAddTraits(.isHeader)
                        Text("A company has its own page, a team with roles, shared services and one calendar. Nothing you've built is lost.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Space.l) {
                        point("arrow.right.circle", "Your services and contracts move",
                              "They become the company's, so everyone on the team can offer them.")
                        point("person.crop.circle", "Your own profile stays yours",
                              "You keep your personal page and can switch back to it from the Profile tab.")
                        point("lock.doc", "Bookings and signed contracts stay put",
                              "Work you've already agreed keeps the terms and the name it was signed under.")
                        point("person.badge.key", "You become the Owner",
                              "You can invite people, set their roles, and decide who signs contracts.")
                    }
                    .card()

                    Label {
                        Text("Companies are billed per seat, for at least \(model.teamConfig.seatMinimum) seats. You choose the plan after the company is set up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "creditcard")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        CompanySetupView(mode: .upgrade, onDone: { dismiss() })
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                    }
                    .buttonStyle(.slatePrimary)
                    .controlSize(.large)
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .slatePageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

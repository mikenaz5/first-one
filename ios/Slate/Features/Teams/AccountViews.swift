import SwiftUI

// The account switcher and the invite sheet: how a person moves between their own account and the companies they
// work for, the way Apple's apps switch accounts.

// MARK: - Switcher button

/// The small avatar at the top of a screen that shows who the person is acting as. Tapping it opens the switcher.
struct AccountButton: View {
    @Environment(AppModel.self) private var model

    @State private var showSwitcher = false

    private var name: String { model.profile?.displayName ?? "Account" }

    var body: some View {
        Button {
            showSwitcher = true
        } label: {
            HStack(spacing: Space.xs) {
                AvatarView(name: name, url: model.profile?.avatarURL, size: Metrics.avatarXS)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Account: \(name)")
        .accessibilityHint("Switch between your accounts")
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
        }
    }
}

// MARK: - Switcher

struct AccountSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var switching: ActiveAccount?
    /// The account that was showing when the switcher opened, to tell whether starting a company moved the person.
    @State private var openedOn: ActiveAccount?
    @State private var showUpgrade = false
    @State private var showNewCompany = false

    /// An individual can move their own account up to a company once; after that, new companies start from nothing.
    private var canUpgrade: Bool {
        model.personalProfile?.isComplete == true && !model.accounts.companies.contains { $0.role == .owner }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let personal = model.personalProfile {
                        AccountRow(
                            name: personal.displayName,
                            detail: "Individual account",
                            avatarURL: personal.avatarURL,
                            isSelected: model.activeAccount == .personal,
                            isSwitching: switching == .personal
                        ) { choose(.personal) }
                    }
                    ForEach(model.accounts.companies) { company in
                        AccountRow(
                            name: company.name,
                            detail: company.title.isEmpty ? company.role.title : "\(company.role.title) · \(company.title)",
                            avatarURL: company.avatarURL,
                            isSelected: model.activeAccount == .company(company.organizationID),
                            isSwitching: switching == .company(company.organizationID),
                            note: company.state == .lapsed ? "Plan needs attention" : nil
                        ) { choose(.company(company.organizationID)) }
                    }
                } header: {
                    Text("Accounts")
                }

                Section {
                    if canUpgrade {
                        Button {
                            showUpgrade = true
                        } label: {
                            Label("Upgrade to a company", systemImage: "arrow.up.circle")
                                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        }
                    }
                    Button {
                        showNewCompany = true
                    } label: {
                        Label("Start a new company", systemImage: "plus.circle")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                } footer: {
                    Text(canUpgrade
                         ? "Upgrading moves your services and contracts to a company with a team. Your profile, bookings and signed contracts stay as they are."
                         : "A company has its own page, team, services and calendar. Your own account stays as it is.")
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showUpgrade, onDismiss: closeIfSwitched) { UpgradeSheet() }
            .sheet(isPresented: $showNewCompany, onDismiss: closeIfSwitched) { NewCompanySheet() }
            .sensoryFeedback(.selection, trigger: model.activeAccount)
            .onAppear { if openedOn == nil { openedOn = model.activeAccount } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ account: ActiveAccount) {
        guard account != model.activeAccount else {
            dismiss()
            return
        }
        switching = account
        Task {
            await model.switchAccount(to: account)
            switching = nil
            dismiss()
        }
    }

    /// Starting or upgrading to a company opens it, so the switcher has nothing left to do.
    private func closeIfSwitched() {
        if model.activeAccount != openedOn { dismiss() }
    }
}

private struct AccountRow: View {
    let name: String
    let detail: String
    let avatarURL: URL?
    let isSelected: Bool
    let isSwitching: Bool
    var note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                AvatarView(name: name, url: avatarURL, size: Metrics.avatarS)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(name).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Color.slateWarning)
                    }
                }
                Spacer(minLength: Space.s)
                if isSwitching {
                    ProgressView()
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Invite

/// What a person sees when they open a company invite link: who invited them, to what, and as what.
struct InviteOfferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let offer: InviteOffer

    @State private var name = ""
    @State private var isJoining = false
    @State private var joined = false

    private var preview: InvitePreview { offer.preview }
    private var needsName: Bool { !preview.hasProfile }
    private var canJoin: Bool { !isJoining && (!needsName || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(spacing: Space.m) {
                        Image(systemName: "building.2")
                            .heroSymbol(48, weight: .light)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text("Join \(preview.organizationName)")
                            .font(SlateFont.display)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(invitedLine)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .top, spacing: Space.m) {
                        Image(systemName: preview.role.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(minWidth: Metrics.iconColumn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(preview.role.title).font(.headline)
                            Text(preview.role.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .card()
                    .accessibilityElement(children: .combine)

                    if needsName {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Your name").eyebrow()
                            TextField("How your team sees you", text: $name)
                                .textContentType(.name)
                                .submitLabel(.done)
                                .frame(minHeight: Metrics.minTapTarget)
                                .padding(.horizontal, Space.l)
                                .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        }
                    }

                    Text("You join with your own Apple ID and keep your own profile. You can switch between it and \(preview.organizationName) from the Profile tab, and leave whenever you like.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(spacing: Space.s) {
                        Button {
                            Task { await join() }
                        } label: {
                            Group {
                                if isJoining {
                                    ProgressView().tint(Color.slateOnAccent)
                                } else {
                                    Text("Join \(preview.organizationName)")
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canJoin)

                        Button("Not now") {
                            model.declineInvite()
                            dismiss()
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                        .disabled(isJoining)
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .slatePageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if name.isEmpty { name = model.session?.fullName ?? "" }
            }
            .sensoryFeedback(.success, trigger: joined)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isJoining)
    }

    private var invitedLine: String {
        let who = preview.invitedByName.map { $0.isEmpty ? "You've been invited" : "\($0) invited you" } ?? "You've been invited"
        return "\(who) to join as \(preview.role.title)."
    }

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.acceptInvite(offer, displayName: needsName ? given : nil)
            joined = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't join")
            // A link that no longer works shouldn't stay open.
            if let slate = error as? SlateError, slate == .inviteInvalid || slate == .alreadyMember {
                model.declineInvite()
                dismiss()
            }
        }
    }
}

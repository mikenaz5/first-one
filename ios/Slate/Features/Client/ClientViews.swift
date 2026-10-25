import SwiftUI

/// The five tabs for someone who books and doesn't sell. The same places, with client meanings: Creators takes the
/// place of Services, and Profile is about the person.
struct ClientTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            BookingsView()
                .tabItem { Label("Bookings", systemImage: "calendar") }
                .tag(AppTab.bookings)

            ClientCreatorsView()
                .tabItem { Label("Creators", systemImage: "camera.aperture") }
                .tag(AppTab.services)

            MessagesView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .badge(model.unreadMessageCount)
                .tag(AppTab.messages)

            ClientProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .sensoryFeedback(.selection, trigger: model.selectedTab)
    }
}

// MARK: - Finding a creator

/// Paste a booking link, or type a creator's name, to open their page.
struct FindCreatorCard: View {
    @Environment(AppModel.self) private var model

    @State private var text = ""
    @State private var notALink = false
    @State private var isOpening = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label("Have a booking link?", systemImage: "link")
                .font(.headline)
            Text("Paste a creator's link, or type their name, to see their packages and book.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("\(AppConfig.bookingLinkHost)/maya", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { open() }
                .onChange(of: text) { _, _ in notALink = false }
                .padding(.horizontal, Space.m)
                .frame(minHeight: Metrics.minTapTarget)
                .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))

            if notALink {
                Text("That doesn't look like a booking link or a creator's name.")
                    .font(.footnote)
                    .foregroundStyle(Color.slateDanger)
            }

            Button {
                open()
            } label: {
                HStack {
                    Text("Open page")
                    if isOpening { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slatePrimary)
            .controlSize(.large)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isOpening)
        }
        .card()
    }

    private func open() {
        guard !isOpening else { return }
        focused = false
        isOpening = true
        Task {
            let found = await model.openBookingLink(text: text)
            notALink = !found
            if found { text = "" }
            isOpening = false
        }
    }
}

// MARK: - Creators tab

/// The creators this person has booked, so booking again is a tap, and a place to paste a link.
struct ClientCreatorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    FindCreatorCard()

                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionHeader("Creators you've booked")
                        if model.creatorsBooked.isEmpty {
                            Text("Creators you book show up here, so you can book them again.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                                .card(.outlined)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(model.creatorsBooked.enumerated()), id: \.element.id) { index, creator in
                                    if index > 0 { Divider() }
                                    Button {
                                        Task { await model.openCreatorPage(creator.id) }
                                    } label: {
                                        BookedCreatorRow(creator: creator)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .card()
                        }
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .slatePageBackground()
            .navigationTitle("Creators")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct BookedCreatorRow: View {
    let creator: BookedCreator

    var body: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: creator.name, url: nil, size: Metrics.avatarS)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(creator.name).font(.headline)
                Text(creator.bookingCount == 1 ? "1 booking" : "\(creator.bookingCount) bookings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Text("Book again")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.slateAccentText)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens their page so you can book again")
    }
}

// MARK: - Profile tab

/// A client's Profile: who they are, how to start selling, and the account actions.
struct ClientProfileView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.dark.rawValue
    @State private var showNotifications = false
    @State private var showName = false
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    private var name: String {
        let value = model.session?.fullName ?? ""
        return value.isEmpty ? "Your name" : value
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Space.m) {
                        AvatarView(name: name, url: nil, size: Metrics.avatarM)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(name).font(.headline)
                            if let email = model.session?.email, !email.isEmpty {
                                Text(email).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text("Client account · free").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Space.xs)
                    .accessibilityElement(children: .combine)

                    Button {
                        showName = true
                    } label: {
                        Label("Change the name on my contracts", systemImage: "pencil")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    Button {
                        model.startingCreatorSetup = true
                    } label: {
                        Label("Start taking bookings", systemImage: "camera.aperture")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Sell on Slate")
                } footer: {
                    Text("Set up a page as an individual or a company. Your bookings and contracts stay with you.")
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    Picker(selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                } header: {
                    Text("Look")
                }
                    .listRowBackground(Color.slateCard)

                Section("You") {
                    Button {
                        showNotifications = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    Button {
                        confirmSignOut = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete account…", systemImage: "trash")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                } footer: {
                    Text("Deleting your account removes your sign-in. Contracts you've already signed stay with the creators you booked.")
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showNotifications) {
                NotificationSettingsSheet()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showName) {
                NavigationStack {
                    ClientNameForm(
                        heading: "Your name",
                        detail: "This is the name on the contracts you sign.",
                        buttonTitle: "Save",
                        initialName: model.session?.fullName ?? ""
                    ) { name in
                        try await model.becomeClient(name: name)
                        showName = false
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showName = false } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Sign out of Slate?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            } message: {
                Text("This permanently deletes your account. This can't be undone.")
            }
        }
    }
}

// MARK: - Name

/// Asks for the name that goes on contracts. Used when someone becomes a client without one, and to change it later.
struct ClientNameForm: View {
    let heading: String
    let detail: String
    let buttonTitle: String
    var initialName: String = ""
    let onSave: (String) async throws -> Void

    @State private var name = ""
    @State private var isSaving = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var canSave: Bool { EmailCodeRules.cleanName(name) != nil && !isSaving }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(heading)
                        .font(SlateFont.display)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { save() }
                        .padding(.horizontal, Space.m)
                        .frame(minHeight: Metrics.minTapTarget)
                        .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(Color.slateDanger)
                    }
                }

                Button {
                    save()
                } label: {
                    HStack {
                        Text(buttonTitle)
                        if isSaving { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slatePrimary)
                .controlSize(.large)
                .disabled(!canSave)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .slateGlowBackground()
        .onAppear {
            if name.isEmpty { name = initialName }
            focused = true
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        problem = nil
        Task {
            do {
                try await onSave(name)
            } catch {
                problem = error.localizedDescription
            }
            isSaving = false
        }
    }
}

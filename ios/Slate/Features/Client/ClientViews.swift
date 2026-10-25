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

// MARK: - Home pieces

/// The search field on a client's Home. It looks like one; tapping it goes to the Creators tab to search.
struct ClientSearchEntry: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = .services
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Search creators, or paste a link")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m)
            .frame(minHeight: Metrics.minTapTarget)
            .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search creators")
        .accessibilityHint("Opens the Creators tab, where you can search by name, link or what they shoot")
    }
}

/// The creators a client has booked, a tap from booking again.
struct BookAgainShelf: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.creatorsBooked.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Book again")
                ScrollView(.horizontal) {
                    HStack(spacing: Space.m) {
                        ForEach(model.creatorsBooked) { creator in
                            Button {
                                Task { await model.openCreatorPage(creator.id) }
                            } label: {
                                VStack(spacing: Space.s) {
                                    AvatarView(name: creator.name, url: nil, size: Metrics.avatarL)
                                    Text(creator.name)
                                        .font(.footnote.weight(.medium))
                                        .lineLimit(1)
                                        .frame(width: Metrics.avatarL + Space.l)
                                }
                                .padding(.vertical, Space.xxs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Book \(creator.name) again")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - Creators tab

/// Search for a creator, or pick up where the last booking left off.
struct ClientCreatorsView: View {
    private enum Phase: Equatable {
        case idle, searching, done, failed(String)
    }

    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var results: [CreatorProfile] = []
    @State private var phase = Phase.idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if CreatorSearchRules.clean(query) == nil {
                        browse
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .slatePageBackground()
            .navigationTitle("Creators")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, link or what they shoot")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { openIfLink() }
            .task(id: query) { await search() }
        }
    }

    // MARK: Before searching

    private var browse: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("What do you need?")
                FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                    ForEach(Specialty.allCases) { specialty in
                        SpecialtyChip(specialty: specialty, isSelected: false) { query = specialty.title }
                    }
                }
                Text("Or search above by a creator's name or link name. You can paste a booking link there too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
    }

    // MARK: Results

    @ViewBuilder
    private var searchResults: some View {
        switch phase {
        case .idle, .searching:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .failed(let message):
            VStack(spacing: Space.m) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await search() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .done:
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No creators found", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a name, a link name, or what they shoot, like weddings or portraits.")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, creator in
                        if index > 0 { Divider() }
                        Button {
                            Task { await model.openBookingLink(text: creator.handle) }
                        } label: {
                            CreatorSearchRow(creator: creator)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card()
            }
        }
    }

    private func search() async {
        guard let words = CreatorSearchRules.clean(query) else {
            results = []
            phase = .idle
            return
        }
        // A link is opened when the person presses search, not searched for.
        if CreatorSearchRules.looksLikeLink(query) {
            results = []
            phase = .done
            return
        }
        phase = .searching
        do {
            // Wait for a pause in the typing; the next letter cancels this and starts again.
            try await Task.sleep(for: .milliseconds(300))
            results = try await model.findCreators(words)
            phase = .done
        } catch is CancellationError {
            // Replaced by a newer search.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func openIfLink() {
        guard CreatorSearchRules.looksLikeLink(query) else { return }
        Task {
            if await model.openBookingLink(text: query) {
                query = ""
            } else {
                phase = .failed("That isn't a booking link.")
            }
        }
    }
}

private struct CreatorSearchRow: View {
    let creator: CreatorProfile

    private var detail: String {
        var parts = creator.specialties.prefix(2).map(\.title)
        if let place = creator.location?.name, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: creator.displayName, url: creator.avatarURL, size: Metrics.avatarM)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(creator.displayName).font(.headline)
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens their page so you can book")
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

/// A client's Profile: who they are, their contracts and payments in one place, and the account actions.
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

    /// "2 cards", or nothing before any are saved.
    private var cardsDetail: String? {
        switch model.cards.count {
        case 0: nil
        case 1: "1 card"
        default: "\(model.cards.count) cards"
        }
    }

    private var paidText: String {
        let cents = ClientActivity.netPaidCents(model.payments)
        return cents == 0 ? "" : Money.format(cents, code: model.payments.first?.currencyCode ?? Money.defaultCurrencyCode)
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
                            Text("Free account").font(.footnote).foregroundStyle(.secondary)
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
                    NavigationLink {
                        ClientContractsView()
                    } label: {
                        row("signature", "My contracts", detail: model.contractedBookings.isEmpty ? nil : "\(model.contractedBookings.count)")
                    }
                    NavigationLink {
                        ClientPaymentsView()
                    } label: {
                        row("creditcard", "Payments and receipts", detail: paidText.isEmpty ? nil : paidText)
                    }
                } header: {
                    Text("Your paperwork")
                } footer: {
                    Text("Every contract you've signed and everything you've paid, with refunds, in one place.")
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    NavigationLink {
                        ClientCardsView()
                    } label: {
                        row("wallet.pass", "Cards on file", detail: cardsDetail)
                    }
                } header: {
                    Text("Payment methods")
                } footer: {
                    Text("Keep a card with Stripe, and choose which creators you've booked may charge the balance to it.")
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
                    Button {
                        showNotifications = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Preferences")
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
            .task { await model.loadCards() }
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
            .confirmationDialog("Sign out of Slate Pro?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            } message: {
                Text("This permanently deletes your account. This can't be undone.")
            }
        }
    }

    private func row(_ symbol: String, _ title: String, detail: String?) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: Space.s)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Contracts and payments

/// Every contract the client has signed.
struct ClientContractsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.contractedBookings.isEmpty {
                ContentUnavailableView {
                    Label("No contracts yet", systemImage: "signature")
                } description: {
                    Text("When you book and sign, your contract is kept here.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.contractedBookings) { booking in
                        NavigationLink {
                            SignedContractView(booking: booking)
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(booking.packageName).font(.headline)
                                Text("\(booking.creatorName) · \(booking.startAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        }
                    }
                } footer: {
                    Text("Open one to read it or save the signed PDF.")
                }
                    .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("My contracts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the client has paid and been refunded, newest first.
struct ClientPaymentsView: View {
    @Environment(AppModel.self) private var model

    private var history: [Payment] { ClientActivity.history(model.payments) }

    var body: some View {
        List {
            if history.isEmpty {
                ContentUnavailableView {
                    Label("No payments yet", systemImage: "creditcard")
                } description: {
                    Text("Deposits, balances and refunds are listed here.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    LabeledContent("Paid so far") {
                        Text(Money.format(ClientActivity.netPaidCents(model.payments), code: history.first?.currencyCode ?? Money.defaultCurrencyCode))
                            .font(.headline)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                } footer: {
                    Text("What you've paid, less refunds.")
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    ForEach(history) { payment in
                        paymentRow(payment)
                    }
                }
                    .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Payments")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paymentRow(_ payment: Payment) -> some View {
        let booking = model.bookings.first { $0.id == payment.bookingID }
        let isRefund = payment.kind == .refund
        return HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("\(payment.kind.title) · \(booking?.packageName ?? "Booking")").font(.headline)
                Text("\(booking?.creatorName ?? "") \(booking == nil ? "" : "· ")\(payment.statusTitle) · \((payment.paidAt ?? payment.createdAt).formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Text("\(isRefund ? "+" : "")\(Money.format(payment.amountCents, code: payment.currencyCode))")
                .font(.headline.monospacedDigit())
                .foregroundStyle(isRefund ? Color.slateSuccess : Color.primary)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
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

import AuthenticationServices
import SwiftUI

// MARK: - Cards on file (Profile ▸ Payment methods)

/// The client's cards, and the creators they have allowed to charge one for the balance of a booking.
///
/// A card is typed on Stripe's own page, so this app never sees a number. A creator can charge only after the client has
/// allowed them here (or from a booking), only the balance, and only once the client has confirmed their files.
struct ClientCardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var isLoading = true
    @State private var loadProblem: String?
    @State private var isAdding = false
    @State private var cardToRemove: SavedCard?
    @State private var permissionToStop: CardPermission?
    @State private var showAllow = false

    private var now: Date { model.clock() }

    var body: some View {
        List {
            cardsSection
            allowedSection
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Payment methods")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadProblem = await model.loadCards()
            isLoading = false
            // Stripe is the one that knows: this also picks up a card typed on its page a moment ago.
            await model.syncCards()
        }
        .sheet(isPresented: $showAllow) {
            AllowCreatorSheet()
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            cardToRemove.map { "Remove \($0.title)?" } ?? "Remove this card?",
            isPresented: Binding(get: { cardToRemove != nil }, set: { if !$0 { cardToRemove = nil } }),
            titleVisibility: .visible,
            presenting: cardToRemove
        ) { card in
            Button("Remove Card", role: .destructive) { Task { await model.removeCard(card) } }
        } message: { card in
            Text(removeMessage(for: card))
        }
        .confirmationDialog(
            permissionToStop.map { "Stop \($0.creatorName) charging your card?" } ?? "Stop this?",
            isPresented: Binding(get: { permissionToStop != nil }, set: { if !$0 { permissionToStop = nil } }),
            titleVisibility: .visible,
            presenting: permissionToStop
        ) { permission in
            Button("Stop Access", role: .destructive) { Task { await model.stopAllowing(permission) } }
        } message: { permission in
            Text("\(permission.creatorName) won't be able to charge your \(permission.cardTitle) any more. You can allow them again whenever you like.")
        }
        .sensoryFeedback(.success, trigger: model.cardPermissions.count)
    }

    // MARK: Cards

    private var cardsSection: some View {
        Section {
            if model.cards.isEmpty {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                } else {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(loadProblem == nil ? "No cards yet" : "Couldn't load your cards")
                            .font(.headline)
                        Text(loadProblem ?? "Add a card, then choose which creators you've booked may take the balance from it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            ForEach(model.orderedCards) { card in
                CardRow(card: card, allowedCount: model.cardPermissions.filter { $0.cardID == card.id }.count) {
                    cardToRemove = card
                }
                .swipeActions(edge: .trailing) {
                    Button("Remove", role: .destructive) { cardToRemove = card }
                }
            }
            Button {
                Task { await addCard() }
            } label: {
                HStack {
                    Label("Add a card", systemImage: "plus.circle.fill")
                    if isAdding {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
            .disabled(isAdding || !model.canAddCard)
        } header: {
            Text("Your cards")
        } footer: {
            Text(cardsFooter)
        }
            .listRowBackground(Color.slateCard)
    }

    private var cardsFooter: String {
        if !model.canAddCard { return "You can keep up to \(CardRules.maxCards) cards. Remove one to add another." }
        if model.paymentsAreSimulated { return "Demo mode: these are pretend cards. No card is read and no money moves." }
        return "You type the card on Stripe's own page. Slate Pro never sees the number; it only shows the brand, the last four digits and the expiry."
    }

    private func removeMessage(for card: SavedCard) -> String {
        let count = model.cardPermissions.filter { $0.cardID == card.id }.count
        let base = "It's removed from Stripe as well."
        switch count {
        case 0: return base
        case 1: return "\(base) This also stops 1 creator from using it."
        default: return "\(base) This also stops \(count) creators from using it."
        }
    }

    private func addCard() async {
        isAdding = true
        defer { isAdding = false }
        guard let url = await model.beginAddingCard() else { return }
        do {
            _ = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: AppConfig.urlScheme)
        } catch {
            // Closing the page early is fine; Stripe remembers whatever was saved.
        }
        await model.syncCards()
    }

    // MARK: Creators

    private var allowedSection: some View {
        Section {
            if model.cardPermissions.isEmpty {
                Text("No creator can charge a card.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
            }
            ForEach(model.cardPermissions) { permission in
                PermissionRow(permission: permission, now: now) { permissionToStop = permission }
            }
            Button {
                showAllow = true
            } label: {
                Label("Allow a creator…", systemImage: "person.badge.plus")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
            .disabled(model.usableCards.isEmpty || model.creatorsToAllow.isEmpty)
        } header: {
            Text("Creators who can charge a card")
        } footer: {
            Text(allowedFooter)
        }
            .listRowBackground(Color.slateCard)
    }

    private var allowedFooter: String {
        if model.usableCards.isEmpty { return "Add a card first. Then you can allow a creator you've booked." }
        if model.creatorsToAllow.isEmpty && model.cardPermissions.isEmpty { return "You can allow a creator once you've booked them." }
        return "A creator can charge only the balance of a booking, and only after you've confirmed you have your files. They never see your card number. You can stop it at any time."
    }
}

// MARK: - Rows

private struct CardRow: View {
    @Environment(AppModel.self) private var model

    let card: SavedCard
    let allowedCount: Int
    let remove: () -> Void

    var body: some View {
        let now = model.clock()
        let expired = card.isExpired(at: now)
        HStack(spacing: Space.m) {
            HStack(spacing: Space.m) {
                Image(systemName: "creditcard.fill")
                    .font(.title3)
                    .foregroundStyle(expired ? Color.secondary : Color.accentColor)
                    .frame(minWidth: Metrics.iconColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(card.title).font(.headline)
                    Text(card.detail(at: now))
                        .font(.subheadline)
                        .foregroundStyle(expired ? Color.slateDanger : Color.secondary)
                    if allowedCount > 0 {
                        Text(allowedCount == 1 ? "1 creator can charge it" : "\(allowedCount) creators can charge it")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(card.accessibilitySummary(at: now))\(allowedCount > 0 ? ". \(allowedCount) \(allowedCount == 1 ? "creator" : "creators") can charge it." : "")")

            Spacer(minLength: Space.s)

            Menu {
                Button("Remove Card", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(card.title)")
        }
        .frame(minHeight: Metrics.minTapTarget)
    }
}

private struct PermissionRow: View {
    let permission: CardPermission
    let now: Date
    let stop: () -> Void

    var body: some View {
        let expired = permission.isExpired(at: now)
        AdaptiveStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(permission.creatorName).font(.headline)
                Text("Can charge the balance to \(permission.cardTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if expired {
                    Text("That card has expired, so they can't use it.")
                        .font(.footnote)
                        .foregroundStyle(Color.slateDanger)
                } else {
                    Text("Allowed \(permission.allowedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.s)
            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .tint(Color.slateDanger)
                .frame(minHeight: Metrics.minTapTarget)
                .accessibilityLabel("Stop \(permission.creatorName) charging your card")
        }
        .frame(minHeight: Metrics.minTapTarget)
    }
}

// MARK: - Allowing a creator

/// The agreement: who, which card, and what it means, in plain words, before the one button that gives permission.
/// Opened from the cards screen, or from a booking with the creator already chosen.
struct AllowCreatorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// A creator chosen already (from their booking). Otherwise the person picks one they've booked.
    var preselected: UUID?

    @State private var creatorID: UUID?
    @State private var cardID: UUID?
    @State private var isSaving = false

    init(preselected: UUID? = nil) {
        self.preselected = preselected
    }

    private var candidates: [CardRules.Candidate] {
        let all = model.creatorsToAllow
        guard let preselected else { return all }
        return all.filter { $0.creatorID == preselected }
    }

    private var creator: CardRules.Candidate? {
        candidates.first { $0.creatorID == (creatorID ?? candidates.first?.creatorID) }
    }

    private var card: SavedCard? {
        let usable = model.usableCards
        return usable.first { $0.id == cardID } ?? CardRules.ordered(usable, at: model.clock()).first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if let creator, let card {
                        Text(CardConsent.title(creator: creator.name))
                            .font(SlateFont.display)
                            .accessibilityAddTraits(.isHeader)

                        if candidates.count > 1 {
                            choice("Creator") {
                                Picker("Creator", selection: Binding(get: { creator.creatorID }, set: { creatorID = $0 })) {
                                    ForEach(candidates) { Text($0.name).tag($0.creatorID) }
                                }
                            }
                        }
                        if model.usableCards.count > 1 {
                            choice("Card") {
                                Picker("Card", selection: Binding(get: { card.id }, set: { cardID = $0 })) {
                                    ForEach(CardRules.ordered(model.usableCards, at: model.clock())) { Text($0.title).tag($0.id) }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: Space.m) {
                            ForEach(CardConsent.paragraphs(creator: creator.name, card: card), id: \.self) { paragraph in
                                Text(paragraph).font(.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(.outlined)
                        .accessibilityElement(children: .combine)

                        Button {
                            allow(creator, card)
                        } label: {
                            HStack {
                                Text(CardConsent.button(creator: creator.name))
                                if isSaving { ProgressView() }
                            }
                            .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                        }
                        .buttonStyle(.slatePrimary)
                        .controlSize(.large)
                        .disabled(isSaving)
                    } else {
                        ContentUnavailableView {
                            Label("Nobody to allow yet", systemImage: "person.badge.plus")
                        } description: {
                            Text(model.usableCards.isEmpty
                                 ? "Add a card first, then you can allow a creator you've booked."
                                 : "You can allow a creator once you've booked them.")
                        }
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .slatePageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func choice<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                .padding(.horizontal, Space.m)
                .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Color.slateHairline, lineWidth: 1))
        }
    }

    private func allow(_ creator: CardRules.Candidate, _ card: SavedCard) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            if await model.allowCreator(creator.creatorID, with: card) { dismiss() }
            isSaving = false
        }
    }
}

import SwiftUI

/// "Choose a plan": the steps of the company plan, with the price and free trial exactly as Apple returns them, bought with
/// Apple's own purchase sheet. That sheet pays with Apple Pay, a card in Wallet or Apple Account balance, and Slate Pro never
/// sees a card. Shown right after a company is made, from Billing, and when the team is full.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var listings: [PlanListing] = []
    @State private var selected: String?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isBuying = false
    @State private var isRestoring = false
    @State private var note: String?
    @State private var bought = false

    private var covered: Int? { model.organization?.plan.seatsCovered }
    private var people: Int { (model.organization?.seats.used ?? 0) + (model.organization?.seats.pending ?? 0) }
    private var hasPlan: Bool {
        guard let status = model.organization?.plan.status else { return false }
        return status != .none && status != .canceled
    }
    private var chosen: PlanListing? { listings.first { $0.id == selected } }
    private var isBusy: Bool { isBuying || isRestoring }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    if !model.canBuyPlan {
                        Label("Only the company's Owner can buy or change the plan.", systemImage: "person.badge.key")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .card()
                    } else if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                    } else if loadFailed || listings.isEmpty {
                        unavailable
                    } else {
                        options
                        subscribeButton
                    }
                    if let note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isStaticText)
                    }
                    fineprint
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .slatePageBackground()
            .navigationTitle(hasPlan ? "Change plan" : "Choose a plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasPlan ? "Close" : "Not now") { dismiss() }
                        .disabled(isBusy)
                }
            }
            .sensoryFeedback(.success, trigger: bought)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
        .task { await load() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(hasPlan ? "Make room for your team" : "Start your company's plan")
                .font(SlateFont.display)
                .accessibilityAddTraits(.isHeader)
            Text("A plan lets you invite your team, share services and one calendar, and take bookings in the company's name. Pick the size that fits; you can move up later.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        VStack(spacing: Space.s) {
            ForEach(listings) { listing in
                option(listing)
            }
        }
    }

    private func option(_ listing: PlanListing) -> some View {
        let isCurrent = covered == listing.offer.seats && hasPlan
        let tooSmall = listing.offer.seats < people
        let isLower = (covered ?? 0) > listing.offer.seats
        let isSelected = selected == listing.id
        let disabled = isCurrent || tooSmall || isLower
        return Button {
            selected = listing.id
        } label: {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Up to \(listing.offer.seats) people").font(.headline)
                    if isCurrent {
                        Text("Your plan now").font(.footnote).foregroundStyle(.secondary)
                    } else if tooSmall {
                        Text("Your team is bigger than this").font(.footnote).foregroundStyle(.secondary)
                    } else if isLower {
                        Text("To go smaller, use Manage Subscription in Billing").font(.footnote).foregroundStyle(.secondary)
                    } else if !hasPlan, let trial = listing.trial {
                        Text(trial).font(.footnote).foregroundStyle(Color.slateSuccess)
                    }
                }
                Spacer(minLength: Space.s)
                Text("\(listing.price) / \(listing.period)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isBusy)
        .opacity(disabled ? 0.55 : 1)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var subscribeButton: some View {
        Button {
            Task { await buy() }
        } label: {
            if isBuying {
                ProgressView().frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            } else {
                Text(buttonTitle).frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
        }
        .buttonStyle(.slatePrimary)
        .controlSize(.large)
        .disabled(chosen == nil || isBusy)
    }

    private var buttonTitle: String {
        guard let chosen else { return "Choose a plan" }
        if hasPlan { return "Move to \(chosen.offer.seats) people" }
        if chosen.trial != nil { return "Start free trial" }
        return "Subscribe for \(chosen.price) / \(chosen.period)"
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Can't load plans", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Plans come from the App Store. Check your connection and try again.")
        } actions: {
            Button("Try Again") { Task { await load() } }
        }
    }

    /// What Apple asks to be said before someone subscribes, and the way back to a plan bought earlier.
    private var fineprint: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Paid with Apple Pay, a card in your Wallet or your Apple Account balance; Slate Pro never sees your card. Payment is charged to your Apple Account when you confirm, or when the free trial ends if the plan has one. The plan renews each month unless you cancel at least 24 hours before the period ends. Manage or cancel it in your Apple Account settings, under Subscriptions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.l) {
                Button("Terms of Use") { openURL(AppConfig.termsURL) }
                Button("Privacy Policy") { openURL(AppConfig.privacyURL) }
            }
            .font(.footnote)
            if model.canBuyPlan {
                Button {
                    Task { await restore() }
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                .disabled(isBusy)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard model.canBuyPlan else {
            isLoading = false
            return
        }
        isLoading = true
        loadFailed = false
        do {
            listings = try await model.loadPlanListings()
            let offers = listings.map(\.offer)
            let suggestion = PlanRules.suggestion(people: people, covered: hasPlan ? covered : nil, in: offers)
            selected = (suggestion ?? PlanRules.smallest(covering: max(people, 1), in: offers) ?? offers.first)?.productID
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    private func buy() async {
        guard let chosen else { return }
        isBuying = true
        defer { isBuying = false }
        note = nil
        do {
            switch try await model.buyPlan(chosen.offer) {
            case .recorded:
                bought = true
                dismiss()
            case .pending:
                note = "Your purchase is waiting for approval. The plan starts as soon as it's approved."
            case .cancelled:
                break
            }
        } catch {
            model.show(error, title: "Couldn't start the plan")
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        note = nil
        do {
            if try await model.restorePlan() {
                bought = true
                dismiss()
            } else {
                note = "No plan for this company was found on this Apple Account."
            }
        } catch {
            model.show(error, title: "Couldn't restore")
        }
    }
}

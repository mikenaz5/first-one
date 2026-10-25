import SwiftUI

// MARK: - A booking's saved-card note (booking detail)

/// What a booking says about a card on file, for whichever side is looking.
///
/// The client sees which creator may charge which card, or is offered to allow it. The creator sees, when the client has
/// allowed it, that the balance can be charged to their saved card, and a button for it once the balance is payable. The
/// amount is always the booking's balance: nothing here lets anyone choose it.
struct SavedCardSection: View {
    @Environment(AppModel.self) private var model

    let booking: Booking

    @State private var showAllow = false
    @State private var confirmCharge = false
    @State private var message: String?

    /// What the booking says, fetched by `BookingDetailView` (which always exists, so it can load before anything shows).
    private var access: CardAccess { model.cardAccessByBooking[booking.id] ?? .none }
    private var isClient: Bool { booking.clientID == model.session?.userID }
    private var clientName: String { booking.clientName.isEmpty ? "The client" : booking.clientName }
    private var brandName: String { access.brand?.title ?? "card" }
    private var balanceText: String { Money.format(booking.balanceCents, code: booking.currencyCode) }

    var body: some View {
        let phase = model.paymentSummary(for: booking).phase
        Group {
            if isClient {
                clientSection(phase: phase)
            } else if model.canManage(booking) {
                providerSection(phase: phase)
            }
        }
        .sheet(isPresented: $showAllow) {
            AllowCreatorSheet(preselected: booking.creatorID)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Charge \(balanceText) to \(clientName)'s \(brandName)?", isPresented: $confirmCharge, titleVisibility: .visible) {
            Button("Charge \(balanceText)") { Task { await charge() } }
        } message: {
            Text("This is the balance of the booking. \(clientName) is told straight away.")
        }
        .alert("Saved card", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .sensoryFeedback(trigger: message) { _, new in new == nil ? nil : .warning }
    }

    // MARK: Client

    @ViewBuilder
    private func clientSection(phase: PaymentSummary.Phase) -> some View {
        if access.allowed {
            Section {
                Label {
                    Text("\(booking.creatorName) can charge the balance to your \(access.cardTitle ?? "card"), once you've confirmed you have your files.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "creditcard.fill").foregroundStyle(Color.accentColor).frame(minWidth: Metrics.iconColumn)
                }
                NavigationLink {
                    ClientCardsView()
                } label: {
                    Text("Manage in Payment methods")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            } header: {
                Text("Saved card")
            }
                .listRowBackground(Color.slateCard)
        } else if CardRules.shouldOfferToAllow(access: access, phase: phase, hasUsableCard: !model.usableCards.isEmpty) {
            Section {
                Button {
                    showAllow = true
                } label: {
                    Label("Let \(booking.creatorName) charge the balance to my card", systemImage: "creditcard")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            } header: {
                Text("Saved card")
            } footer: {
                Text("They can charge only the balance, after you've confirmed your files. You can stop it at any time in Profile.")
            }
                .listRowBackground(Color.slateCard)
        }
    }

    // MARK: Creator

    @ViewBuilder
    private func providerSection(phase: PaymentSummary.Phase) -> some View {
        let state = CardRules.chargeState(access: access, phase: phase)
        let client = clientName
        let brand = brandName
        let money = balanceText

        switch state {
        case .hidden:
            EmptyView()
        case .waiting:
            Section {
                Label {
                    Text("\(client) has allowed you to charge their saved \(brand) for the balance, once they've confirmed their files.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "creditcard.fill").foregroundStyle(Color.accentColor).frame(minWidth: Metrics.iconColumn)
                }
            } header: {
                Text("Saved card")
            }
                .listRowBackground(Color.slateCard)
        case .expired:
            Section {
                Label {
                    Text("\(client)'s saved card has expired. Ask them for another way to pay.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.slateWarning).frame(minWidth: Metrics.iconColumn)
                }
            } header: {
                Text("Saved card")
            }
                .listRowBackground(Color.slateCard)
        case .ready:
            Section {
                Label {
                    Text("\(client) has allowed you to charge their saved \(brand) for the balance.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "creditcard.fill").foregroundStyle(Color.accentColor).frame(minWidth: Metrics.iconColumn)
                }
                Button {
                    confirmCharge = true
                } label: {
                    Group {
                        if model.isPaying {
                            ProgressView().tint(Color.slateOnAccent)
                        } else {
                            Label("Charge \(money) to the saved card", systemImage: "creditcard")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slatePrimary)
                .controlSize(.large)
                .disabled(model.isPaying)
                .listRowSeparator(.hidden)
            } header: {
                Text("Saved card")
            } footer: {
                Text(model.paymentsAreSimulated
                     ? "Demo mode: no card is charged. \(client) is told straight away. If a card is declined, they pay in the app instead."
                     : "\(client) is told straight away. If the card is declined, they can pay the balance in the app instead.")
            }
                .listRowBackground(Color.slateCard)
        }
    }

    private func charge() async {
        message = await model.chargeSavedCard(for: booking).message
    }
}

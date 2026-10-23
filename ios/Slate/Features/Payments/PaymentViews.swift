import AuthenticationServices
import PassKit
import SwiftUI

// MARK: - Tone

extension PaymentSummary.Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: .slateSuccess
        case .warning: .slateWarning
        case .danger: .slateDanger
        }
    }
}

// MARK: - Status chip (lists)

/// A booking's money in a few words, for lists.
struct PaymentStatusChip: View {
    let summary: PaymentSummary

    var body: some View {
        Label(summary.headline, systemImage: summary.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(summary.tone.color)
            .labelStyle(.titleAndIcon)
            .lineLimit(2)
    }
}

// MARK: - Pay button

/// Apple's own button when Apple Pay is real; a plain, clearly labelled button for the pretend payments on-device.
struct PayButton: View {
    @Environment(AppModel.self) private var model

    let kind: PaymentKind
    let amountCents: Int
    let currencyCode: String
    let action: () -> Void

    private var noun: String { kind == .deposit ? "deposit" : "balance" }

    var body: some View {
        VStack(spacing: Space.xs) {
            if model.paymentsAreSimulated {
                Button(action: action) {
                    Group {
                        if model.isPaying {
                            ProgressView().tint(Color.slateOnAccent)
                        } else {
                            Label("Pay \(Money.format(amountCents, code: currencyCode)) \(noun)", systemImage: "creditcard")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                }
                .buttonStyle(.slatePrimary)
                .controlSize(.large)
                .disabled(model.isPaying)
                Text("Demo mode: no card is charged.").font(.footnote).foregroundStyle(.secondary)
            } else {
                PayWithApplePayButton(.plain, action: action) {
                    Label("Apple Pay isn't set up on this device", systemImage: "wallet.pass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                }
                .payWithApplePayButtonStyle(.automatic)
                .frame(minHeight: 50)
                .disabled(model.isPaying)
                .accessibilityLabel("Pay \(Money.format(amountCents, code: currencyCode)) \(noun) with Apple Pay")
            }
        }
    }
}

// MARK: - Payment card (booking detail)

/// What has been paid, what is owed now, and the button to pay it.
struct PaymentStatusCard: View {
    @Environment(AppModel.self) private var model

    let booking: Booking
    @State private var message: String?
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .alert("Payment", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func content(now: Date) -> some View {
        let summary = model.paymentSummary(for: booking, now: now)
        let kind = model.canPay(booking, now: now)

        return VStack(alignment: .leading, spacing: Space.m) {
            Label {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(summary.headline).font(.headline)
                    if let detail = summary.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: summary.symbol).foregroundStyle(summary.tone.color).frame(minWidth: Metrics.iconColumn)
            }
            .accessibilityElement(children: .combine)

            if let remaining = booking.holdRemaining(at: now) {
                Label("Your time is held for another \(Self.clock(remaining))", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(Color.slateWarning)
            }

            if let kind {
                PayButton(kind: kind, amountCents: summary.dueNowCents, currencyCode: booking.currencyCode) {
                    Task { await pay(kind) }
                }
            }
        }
        .sensoryFeedback(.success, trigger: summary.phase == .paidInFull)
        .sensoryFeedback(trigger: message) { _, new in new == nil ? nil : .warning }
    }

    private func pay(_ kind: PaymentKind) async {
        message = await model.pay(kind, for: booking).message
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - History

/// Every deposit, balance and refund on a booking, in order.
struct PaymentHistorySection: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    var body: some View {
        let history = model.payments(for: booking).filter { $0.status != .canceled }
        if !history.isEmpty {
            Section {
                ForEach(history) { payment in
                    AdaptiveStack(spacing: Space.s) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(payment.kind.title)
                            Text(subtitle(for: payment)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Space.m)
                        Text("\(payment.kind == .refund ? "−" : "")\(Money.format(payment.amountCents, code: payment.currencyCode))")
                            .monospacedDigit()
                            .foregroundStyle(payment.status == .failed ? Color.slateDanger : Color.primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Payment history")
            } footer: {
                if model.paymentsAreSimulated {
                    Text("Demo mode: these payments are pretend. No money moved.")
                }
            }
                .listRowBackground(Color.slateCard)
        }
    }

    private func subtitle(for payment: Payment) -> String {
        var parts = [payment.statusTitle]
        if let method = payment.method { parts.append(method.title) }
        if let when = payment.paidAt ?? (payment.status == .succeeded ? nil : payment.createdAt) {
            parts.append(when.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Cancel with the exact refund

private struct CancelFlow: ViewModifier {
    @Environment(AppModel.self) private var model

    @Binding var target: Booking?
    @State private var quote: RefundQuote?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: target?.id) { _, id in
                guard id != nil, let booking = target else {
                    quote = nil
                    return
                }
                Task {
                    if let found = await model.refundQuote(for: booking) {
                        quote = found
                    } else {
                        failure = "We couldn't work out the refund just now. Please try again."
                        target = nil
                    }
                }
            }
            .confirmationDialog(
                "Cancel this booking?",
                isPresented: Binding(get: { target != nil && quote != nil }, set: { if !$0 { target = nil; quote = nil } }),
                titleVisibility: .visible,
                presenting: quote
            ) { quote in
                Button(quote.refundCents > 0 ? "Cancel and refund \(Money.format(quote.refundCents, code: quote.currencyCode))" : "Cancel Booking", role: .destructive) {
                    guard let booking = target else { return }
                    target = nil
                    self.quote = nil
                    Task { await model.cancel(booking) }
                }
                Button("Keep Booking", role: .cancel) {}
            } message: { quote in
                Text(quote.explanation)
            }
            .alert("Couldn't cancel", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }
}

extension View {
    /// Set `booking` to start cancelling it: the person sees exactly what will be refunded before the final tap.
    func cancelFlow(_ booking: Binding<Booking?>) -> some View {
        modifier(CancelFlow(target: booking))
    }
}

// MARK: - A held booking, waiting for its deposit

struct HeldBookingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let booking: BookingModel
    let held: Booking

    private var formatter: SlotFormatter { SlotFormatter(timeZone: held.timeZone) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let remaining = held.holdRemaining(at: now)
        return ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.m) {
                    Image(systemName: remaining == nil ? "clock.badge.xmark" : "hourglass")
                        .heroSymbol(64, weight: .light)
                        .foregroundStyle(remaining == nil ? Color.secondary : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(remaining == nil ? "The hold ran out" : "Your time is held")
                        .font(SlateFont.display)
                        .multilineTextAlignment(.center)
                    if let remaining {
                        Text("Pay the deposit within \(PaymentStatusCard.clock(remaining)) to confirm your booking.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel("Pay the deposit within \(Int(remaining / 60)) minutes and \(Int(remaining) % 60) seconds to confirm your booking.")
                    } else {
                        Text("The deposit wasn't paid in time, so nothing was charged and the time was released.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, Space.xl)

                VStack(alignment: .leading, spacing: Space.m) {
                    Label(formatter.fullDay(held.startAt), systemImage: "calendar")
                    Label(formatter.timeRange(start: held.startAt, end: held.endAt), systemImage: "clock")
                    Label("\(held.packageName) with \(held.creatorName)", systemImage: "camera")
                    Label("\(Money.format(held.depositCents, code: held.currencyCode)) deposit now · \(Money.format(held.balanceCents, code: held.currencyCode)) after delivery", systemImage: "creditcard")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                if let notice = booking.payNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateWarning)
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.slateWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                }

                VStack(spacing: Space.m) {
                    if remaining != nil {
                        PayButton(kind: .deposit, amountCents: held.depositCents, currencyCode: held.currencyCode) {
                            Task { await booking.payDeposit(using: model) }
                        }
                        Button("Release this time", role: .destructive) {
                            Task { await booking.abandonHold(using: model) }
                        }
                        .disabled(booking.isSubmitting)
                    } else {
                        Button("Choose another time") { dismiss() }
                            .buttonStyle(.slatePrimary)
                            .controlSize(.large)
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
    }
}

// MARK: - Getting paid (creators)

/// A creator's Stripe account in one card, for the Services tab.
struct PaymentsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let account = model.paymentAccount ?? .notConnected
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "creditcard")
                .font(.title2)
                .foregroundStyle(account.canAcceptPayments ? Color.accentColor : Color.slateWarning)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Payments").font(.headline)
                Text(account.title).font(.subheadline).foregroundStyle(.secondary)
                if !account.canAcceptPayments, model.hasPackagesWithDeposit {
                    Text("Clients can't book packages with a deposit until this is done.")
                        .font(.footnote)
                        .foregroundStyle(Color.slateWarning)
                }
            }
            Spacer(minLength: Space.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens payment setup")
    }
}

struct PaymentSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var isWorking = false

    var body: some View {
        let account = model.paymentAccount ?? .notConnected
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label(account.title, systemImage: account.canAcceptPayments ? "checkmark.seal.fill" : "creditcard")
                            .font(.headline)
                            .foregroundStyle(account.canAcceptPayments ? Color.slateSuccess : Color.primary)
                        Text(account.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Space.xs)
                    .accessibilityElement(children: .combine)
                }
                    .listRowBackground(Color.slateCard)

                if !account.isSimulated {
                    Section {
                        Button {
                            Task { await start() }
                        } label: {
                            HStack {
                                Text(account.state == .notConnected ? "Set up with Stripe" : "Continue setup")
                                if isWorking { Spacer(); ProgressView() }
                            }
                            .frame(minHeight: Metrics.minTapTarget)
                        }
                        .disabled(isWorking)

                        Button("Check status") { Task { isWorking = true; await model.refreshPaymentAccount(); isWorking = false } }
                            .frame(minHeight: Metrics.minTapTarget)
                            .disabled(isWorking)
                    } footer: {
                        Text("Stripe collects your identity and bank details on its own pages. Slate never sees them. Stripe charges its normal processing fee on each payment; Slate adds no fee.")
                    }
                        .listRowBackground(Color.slateCard)
                }

                Section("How you get paid") {
                    Label("The deposit is paid when a client books, the balance after the client confirms they have your final files.", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline)
                    Label("Cancellations refund by the policy on each package, and always in full if you cancel.", systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Payments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.refreshPaymentAccount() }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() async {
        isWorking = true
        defer { isWorking = false }
        guard let url = await model.setUpPayments() else { return }
        do {
            _ = try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: AppConfig.urlScheme)
        } catch {
            // Closing the page early is fine; Stripe remembers how far they got.
        }
        await model.refreshPaymentAccount()
    }
}

import SwiftUI

// MARK: - Booking detail section

/// After the shoot: the creator shares a link to the final files, the client opens it and confirms they have
/// everything, and then the balance (if any) is paid. Shown on a booking once there is something to do or to see.
struct DeliverySection: View {
    @Environment(AppModel.self) private var model

    let booking: Booking
    /// Changes when the shoot starts, so this section appears without the person leaving the screen.
    var tick = 0

    @State private var showShare = false
    @State private var isConfirming = false
    @State private var sharedCount = 0
    @State private var confirmedCount = 0
    @State private var paymentMessage: String?

    var body: some View {
        if let summary = model.deliverySummary(for: booking, now: model.clock()) {
            Section {
                card(summary)
                    .padding(.vertical, Space.xs)
                if summary.canConfirm, model.canMessage(booking) {
                    NavigationLink {
                        ConversationView(bookingID: booking.id)
                    } label: {
                        Label("Something's wrong", systemImage: "exclamationmark.bubble")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .accessibilityHint("Opens your conversation with \(model.counterpartName(for: booking))")
                }
            } header: {
                Text("Final files")
            } footer: {
                if summary.canConfirm {
                    Text("Check that everything is there before you confirm. If something is missing or wrong, tell \(model.counterpartName(for: booking)) instead.")
                }
            }
        }
    }

    private func card(_ summary: DeliverySummary) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(summary.headline).font(.headline)
                    Text(summary.detail).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: summary.symbol)
                    .foregroundStyle(summary.tone.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            if let note = summary.note {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Note from \(booking.creatorName)").font(.footnote).foregroundStyle(.secondary)
                    Text(note).font(.subheadline).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            if let link = summary.link, let url = DeliveryRules.url(for: link) {
                Link(destination: url) {
                    HStack(spacing: Space.s) {
                        Label("Open final files", systemImage: "arrow.up.forward.app")
                        Spacer(minLength: Space.s)
                        // The address the link goes to, so a client can see where they're heading before they tap.
                        Text(url.host(percentEncoded: false) ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }
                .accessibilityHint("Opens in your browser")
            }

            if summary.canShare {
                shareButton(summary)
            }

            if summary.canConfirm {
                Button {
                    Task { await confirm() }
                } label: {
                    Group {
                        if isConfirming {
                            ProgressView().tint(.white)
                        } else {
                            Label(confirmTitle, systemImage: "checkmark.seal")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isConfirming)
            }
        }
        .motionSafe(.slateSmooth, value: summary.stage)
        .sheet(isPresented: $showShare) {
            ShareDeliverySheet(booking: booking) {
                sharedCount += 1
            }
        }
        .alert("Payment", isPresented: Binding(get: { paymentMessage != nil }, set: { if !$0 { paymentMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(paymentMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: sharedCount)
        .sensoryFeedback(.success, trigger: confirmedCount)
    }

    @ViewBuilder
    private func shareButton(_ summary: DeliverySummary) -> some View {
        let button = Button {
            showShare = true
        } label: {
            Label(summary.link == nil ? "Share final files" : "Replace link",
                  systemImage: summary.link == nil ? "square.and.arrow.up" : "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        if summary.link == nil {
            button.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            button.buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var confirmTitle: String {
        booking.balanceCents > 0 ? "Confirm receipt" : "Confirm I have everything"
    }

    /// Confirms, and when a balance is now owed asks for it straight away: the sheet is one tap from confirming.
    private func confirm() async {
        isConfirming = true
        let confirmed = await model.confirmReceipt(booking)
        isConfirming = false
        guard confirmed else { return }
        confirmedCount += 1
        if let updated = model.bookings.first(where: { $0.id == booking.id }), model.canPay(updated, now: model.clock()) == .balance {
            paymentMessage = await model.pay(.balance, for: updated).message
        }
    }
}

// MARK: - Sharing the files

/// The creator pastes a link (and maybe a password or a note) and shares it with the client.
struct ShareDeliverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let booking: Booking
    var onShared: () -> Void = {}

    @State private var link: String
    @State private var note: String
    @State private var isSharing = false
    @State private var linkTouched = false
    @FocusState private var linkFocused: Bool

    init(booking: Booking, onShared: @escaping () -> Void = {}) {
        self.booking = booking
        self.onShared = onShared
        _link = State(initialValue: booking.deliveryURL ?? "")
        _note = State(initialValue: booking.deliveryNote ?? "")
    }

    private var problem: DeliveryRules.LinkProblem? { DeliveryRules.linkProblem(in: link) }
    private var noteTooLong: Bool { DeliveryRules.noteIsTooLong(note) }
    private var canShare: Bool { problem == nil && !noteTooLong && !isSharing }
    private var isReplacing: Bool { booking.deliveryURL != nil }

    private var problemText: String? {
        guard linkTouched || !link.isEmpty else { return nil }
        switch problem {
        case nil, .empty: return nil
        case .notSecure: return "The link needs to start with https://"
        case .invalid: return "That doesn't look like a link that can be opened. Check it for spaces or typos."
        case .tooLong: return "That link is too long."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://", text: $link)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($linkFocused)
                        .submitLabel(.done)
                        .frame(minHeight: Metrics.minTapTarget)
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first { link = pasted }
                        linkTouched = true
                    }
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: Metrics.minTapTarget)
                } header: {
                    Text("Link to the final files")
                } footer: {
                    if let problemText {
                        Label(problemText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.slateDanger)
                    } else {
                        Text("A share link from Dropbox, Google Drive, WeTransfer, Frame.io or wherever you keep final files. Anyone with the link can open it, so use one that's private to \(clientName).")
                    }
                }

                Section {
                    TextField("Password, expiry date, where to start…", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Note (optional)")
                } footer: {
                    if noteTooLong {
                        Text("Notes can be up to \(DeliveryRules.noteMaxLength) characters.").foregroundStyle(Color.slateDanger)
                    }
                }

                Section {
                    Label(booking.balanceCents > 0
                          ? "Sharing doesn't ask for any money. When \(clientName) confirms they have the files, they pay the remaining \(Money.format(booking.balanceCents, code: booking.currencyCode))."
                          : "Everything is already paid. When \(clientName) confirms they have the files, the booking is complete.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isReplacing ? "Replace link" : "Share final files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSharing {
                        ProgressView()
                    } else {
                        Button(isReplacing ? "Replace" : "Share") { Task { await share() } }
                            .disabled(!canShare)
                    }
                }
            }
            .onChange(of: linkFocused) { _, focused in
                if !focused { linkTouched = true }
            }
            .interactiveDismissDisabled(isSharing)
        }
        .presentationDetents([.medium, .large])
    }

    private var clientName: String {
        let name = booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "your client" : name
    }

    private func share() async {
        isSharing = true
        let shared = await model.shareDelivery(booking, link: link, note: note)
        isSharing = false
        if shared {
            onShared()
            dismiss()
        }
    }
}

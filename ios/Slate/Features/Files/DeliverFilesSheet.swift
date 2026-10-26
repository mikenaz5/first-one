import SwiftUI

/// The last step before the client sees anything: what will happen, a note, and (for a revision) a title.
struct DeliverFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let booking: Booking
    let draft: FileDelivery
    var onDelivered: () -> Void = {}

    @State private var title = ""
    @State private var note = ""
    @State private var isDelivering = false

    private var isRevision: Bool { draft.kind == .revision }
    private var clientName: String {
        let name = booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your client" : name
    }
    private var noteTooLong: Bool { DeliveryRules.noteIsTooLong(note) }
    private var titleTooLong: Bool { MessageRules.length(of: MessageRules.clean(title)) > 80 }
    private var canDeliver: Bool { !noteTooLong && !titleTooLong && !isDelivering && draft.readyFiles.count > 0 }
    private var endsOn: Date { FileRules.expiresAt(deliveredAt: model.clock(), config: model.filesConfig) }
    private var owed: Int { model.files(for: booking.id)?.owedCents ?? booking.balanceCents }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(draft.countText, systemImage: "photo.on.rectangle")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                } header: {
                    Text(isRevision ? "Sending as a revision" : "Delivering")
                }
                .listRowBackground(Color.slateCard)

                if isRevision {
                    Section {
                        TextField(FileRules.revisionTitle(sequence: draft.sequence), text: $title)
                            .frame(minHeight: Metrics.minTapTarget)
                    } header: {
                        Text("Title (optional)")
                    } footer: {
                        if titleTooLong { Text("Keep the title under 80 characters.").foregroundStyle(Color.slateDanger) }
                    }
                    .listRowBackground(Color.slateCard)
                }

                Section {
                    TextField("Anything they should know", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Note (optional)")
                } footer: {
                    if noteTooLong {
                        Text("Notes can be up to \(DeliveryRules.noteMaxLength) characters.").foregroundStyle(Color.slateDanger)
                    }
                }
                .listRowBackground(Color.slateCard)

                Section {
                    Label(whatHappens, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("\(AppConfig.productName) isn't an archive. Keep your own copies of everything you deliver.", systemImage: "externaldrive")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle(isRevision ? "Send revision" : "Deliver files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDelivering {
                        ProgressView()
                    } else {
                        Button(isRevision ? "Send" : "Deliver") { Task { await deliver() } }
                            .disabled(!canDeliver)
                    }
                }
            }
            .interactiveDismissDisabled(isDelivering)
        }
        .presentationDetents([.large])
    }

    /// What delivering does, in the words the product description promises.
    private var whatHappens: String {
        let until = endsOn.formatted(date: .abbreviated, time: .omitted)
        if isRevision {
            return "\(clientName) can save these right away. They're available until \(until)."
        }
        if owed > 0 {
            return "\(clientName) can see previews now, and can save the originals once the \(Money.format(owed, code: booking.currencyCode)) balance is paid. They have until \(until)."
        }
        return "\(clientName) can see and save these right away. They have until \(until)."
    }

    private func deliver() async {
        isDelivering = true
        let delivered = await model.deliverFiles(for: booking, title: isRevision ? title : nil, note: note)
        isDelivering = false
        if delivered {
            onDelivered()
            dismiss()
        }
    }
}

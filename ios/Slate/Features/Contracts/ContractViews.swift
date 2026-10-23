import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The document

/// A contract laid out to be read: big title, numbered headings VoiceOver can jump between, and
/// body text that scales with Dynamic Type.
struct ContractDocumentView: View {
    let title: String
    let sections: [ContractSection]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("\(index + 1). \(section.title)")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(section.body)
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The full text in a sheet, so it can be read before signing.
struct ContractReaderSheet: View {
    let contract: RenderedContract
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ContractDocumentView(title: contract.title, sections: contract.sections)
                    .padding(Space.page)
                    .frame(maxWidth: Metrics.readableWidth)
                    .frame(maxWidth: .infinity)
            }
            .slatePageBackground()
            .navigationTitle("Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Key terms

/// The handful of facts people actually care about, ahead of the full text.
struct KeyTermsCard: View {
    let package: ServicePackage
    let summary: PriceSummary
    let when: String
    let timeRange: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Key terms").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Space.l) {
                row("camera", "Package", package.name, "\(DurationText.short(minutes: summary.durationMinutes))")
                row("calendar", "When", when, timeRange)
                row("creditcard", "Price", Money.format(summary.totalCents, code: summary.currencyCode),
                    "\(Money.format(summary.depositCents, code: summary.currencyCode)) deposit when you book, \(Money.format(summary.balanceCents, code: summary.currencyCode)) after delivery")
                row("shippingbox", "Delivery", "Within \(DurationText.turnaround(days: summary.turnaroundDays))", nil)
                row("arrow.uturn.backward.circle", "Cancellation", package.cancellationPolicy.title, package.cancellationPolicy.summary)
                row("photo.on.rectangle", "Usage rights", package.usageRights.title, package.usageRights.summary)
            }
        }
        .card()
    }

    private func row(_ symbol: String, _ label: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Review and sign (client)

struct ContractReviewView: View {
    @Environment(AppModel.self) private var model
    let booking: BookingModel

    @State private var showFullContract = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Review and sign").font(SlateFont.display).accessibilityAddTraits(.isHeader)
                    Text(booking.summary.depositCents > 0
                         ? "Read the key terms, then sign and pay the deposit to book. You'll both get a signed PDF once it's paid."
                         : "Read the key terms, then sign to book. You'll both get a signed PDF.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if let notice = booking.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateWarning)
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.slateWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                }

                content
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .slatePageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showFullContract) {
            if let preview = booking.contractPreview {
                ContractReaderSheet(contract: preview.contract)
            }
        }
        .task { if booking.contractPreview == nil { await booking.loadContract(using: model) } }
        .motionSafe(.slateSmooth, value: booking.contractPhase)
    }

    @ViewBuilder
    private var content: some View {
        switch booking.contractPhase {
        case .idle, .loading:
            HStack(spacing: Space.s) {
                ProgressView()
                Text("Preparing your contract…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
            .accessibilityElement(children: .combine)

        case .failed(let message):
            VStack(spacing: Space.m) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await booking.loadContract(using: model) } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)

        case .ready:
            let formatter = booking.formatter
            if let slot = booking.selectedSlot {
                KeyTermsCard(
                    package: booking.package,
                    summary: booking.summary,
                    when: formatter.fullDay(slot.start),
                    timeRange: formatter.timeRange(start: slot.start, end: slot.end)
                )
            }

            Button {
                showFullContract = true
            } label: {
                Label("Read the full contract", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slateOutline)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Sign")
                SignatureSection(capture: booking.capture, consent: SigningConsent.text)
            }
        }
    }

    private var signTitle: String {
        let deposit = booking.summary.depositCents
        guard deposit > 0 else { return "Sign & book" }
        return "Sign & pay \(Money.format(deposit, code: booking.summary.currencyCode)) deposit"
    }

    private var bottomBar: some View {
        VStack(spacing: Space.xs) {
            Button {
                Task { await booking.submit(using: model) }
            } label: {
                Group {
                    if booking.isSubmitting {
                        ProgressView().tint(Color.slateOnAccent)
                    } else {
                        Text(signTitle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.slatePrimary)
            .controlSize(.large)
            .disabled(booking.signBlocker != nil || booking.isSubmitting)

            if let blocker = booking.signBlocker {
                Text(blocker).font(.footnote).foregroundStyle(.secondary)
            } else if booking.summary.depositCents > 0 {
                Text(model.paymentsAreSimulated
                     ? "Demo mode: your time is held and the payment is pretend. No card is charged."
                     : "Your time is held for \(PaymentRules.holdMinutes) minutes while you pay with Apple Pay.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(.bar)
    }
}

// MARK: - A signed contract

/// Reads a booking's signed contract: who signed and how, the full text, and the PDF.
struct SignedContractView: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    @State private var contract: Contract?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let contract {
                    statusCard(contract)
                    signaturesCard(contract)
                    ContractDocumentView(title: contract.title, sections: contract.sections)
                        .card()
                } else if loaded {
                    ContentUnavailableView("No contract found", systemImage: "doc.questionmark",
                                           description: Text("This booking doesn't have a contract on file."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
        .navigationTitle("Contract")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let contract {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SignedPDFView(contract: contract, booking: booking)
                    } label: {
                        Label("Signed PDF", systemImage: "doc.richtext")
                    }
                }
            }
        }
        .task {
            contract = await model.contract(for: booking)
            loaded = true
        }
    }

    private func statusCard(_ contract: Contract) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: contract.status == .executed ? "checkmark.seal.fill" : "clock.badge.exclamationmark")
                .font(.title)
                .foregroundStyle(contract.status == .executed ? Color.slateSuccess : Color.slateWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(contract.status.title).font(.headline)
                if let executed = contract.executedAt {
                    Text("Completed \(executed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func signaturesCard(_ contract: Contract) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Signatures").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach([SignerRole.client, .creator], id: \.self) { role in
                if let signature = contract.signature(for: role) {
                    SignatureRow(signature: signature)
                }
            }
        }
        .card()
    }
}

struct SignatureRow: View {
    let signature: ContractSignature

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("\(signature.role.title): \(signature.signedName)").font(.subheadline.weight(.semibold))
            if let companyLine {
                Text(companyLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Group {
                if signature.method == .drawn, let data = signature.imagePNG, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: Metrics.signaturePreviewHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(signature.signedName)
                        .font(.custom("SnellRoundhand-Bold", size: 28, relativeTo: .title))
                        .foregroundStyle(Color.slateInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Ink is dark and drawn for a white page, so it sits on paper in Dark Mode too.
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Color.slatePaper, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .accessibilityHidden(true)
            Text("\(methodText) · \(signature.signedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "For Northlight Films LLC, Owner", when this was signed for a company.
    private var companyLine: String? {
        guard let company = signature.onBehalfOf else { return nil }
        guard let title = signature.signerTitle, !title.isEmpty else { return "For \(company)" }
        return "For \(company), \(title)"
    }

    private var methodText: String {
        switch signature.method {
        case .typed: "Typed"
        case .drawn: "Drawn"
        case .onFile: "Signature on file"
        }
    }
}

// MARK: - PDF

struct SignedPDFView: View {
    @Environment(AppModel.self) private var model
    let contract: Contract
    let booking: Booking

    @State private var data: Data?
    @State private var fileURL: URL?

    var body: some View {
        Group {
            if let data {
                PDFKitView(data: data)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView("Preparing PDF…")
            }
        }
        .navigationTitle("Signed PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            guard let pdf = await model.signedPDF(for: contract, booking: booking) else { return }
            data = pdf
            // A real file with a readable name, so sharing and saving give a sensible filename.
            let safeName = booking.packageName.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Contract - \(safeName).pdf")
            try? pdf.write(to: url, options: .atomic)
            fileURL = url
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

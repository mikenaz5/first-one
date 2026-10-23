import SwiftUI

/// The creator's contracts, their saved signature, and the starters to copy from.
struct ContractsListView: View {
    @Environment(AppModel.self) private var model

    @State private var editing: ContractTemplate?
    @State private var showSignature = false
    @State private var pendingDelete: ContractTemplate?
    @State private var isAdding = false

    /// A Creator or Viewer reads the company's contracts; an Owner or Admin writes them.
    private var canEditTemplates: Bool { model.can(.templatesManage) }

    var body: some View {
        List {
            if let organization = model.organization {
                Section {
                    NavigationLink {
                        SignerPickerView()
                    } label: {
                        CompanySignerRow(organization: organization)
                    }
                    .disabled(!model.can(.signerDesignate))
                } footer: {
                    Text("A contract is signed for the company by one named person, who counter-signs it as soon as the client has signed and paid. Contracts already signed keep the signer they were signed with.")
                }
                    .listRowBackground(Color.slateCard)
            }

            Section {
                Button { showSignature = true } label: { SignatureStatusRow() }
                    .buttonStyle(.plain)
            } footer: {
                Text(model.isCompanyActive
                     ? "If you're named as the company's signer, this is the signature that goes on its contracts. Each person keeps their own."
                     : "Clients sign when they book, and your saved signature is applied to the same contract so it's signed by both of you straight away. You can change it any time; contracts already signed keep the signature they were signed with.")
            }
                .listRowBackground(Color.slateCard)

            Section {
                if model.contractTemplates.isEmpty {
                    ContentUnavailableView {
                        Label("No contracts yet", systemImage: "doc.text")
                    } description: {
                        Text("Start from a ready-made contract and edit it, or write your own.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(model.contractTemplates) { template in
                    Button { editing = template } label: { TemplateRow(template: template) }
                        .buttonStyle(.plain)
                        .disabled(!canEditTemplates)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canEditTemplates {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = template }
                            }
                        }
                        .contextMenu {
                            if canEditTemplates {
                                Button("Edit", systemImage: "pencil") { editing = template }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = template }
                            }
                        }
                }
            } header: {
                Text("Your contracts")
            }
                .listRowBackground(Color.slateCard)

            if canEditTemplates {
            Section {
                Menu {
                    ForEach(StarterTemplates.kinds) { kind in
                        Button(kind.title, systemImage: kind.symbol) { Task { await add(kind) } }
                    }
                    Divider()
                    Button("Blank contract", systemImage: "doc") { Task { await add(.custom) } }
                } label: {
                    Label("New contract", systemImage: "plus.circle.fill")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                .disabled(isAdding)
            } footer: {
                Text(StarterTemplates.disclaimer)
            }
                .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Contracts")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $editing) { template in
            ContractTemplateEditor(template: template)
        }
        .sheet(isPresented: $showSignature) {
            CreatorSignatureSheet()
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { template in
            Button("Delete Contract", role: .destructive) { Task { await model.deleteTemplate(template) } }
        } message: { template in
            let used = model.packagesUsing(template).count
            Text(used == 0 ? "Signed contracts keep their own copy." : "\(used) package\(used == 1 ? " uses" : "s use") it, so it can't be deleted until you switch them to another contract.")
        }
        .sensoryFeedback(trigger: model.contractTemplates.count) { old, new in new > old ? .success : .warning }
    }

    private func add(_ kind: ContractKind) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let template = kind == .custom ? try await model.addBlankTemplate() : try await model.addStarterTemplate(kind)
            editing = template
        } catch {
            model.show(error, title: "Couldn't add the contract")
        }
    }
}

private struct TemplateRow: View {
    @Environment(AppModel.self) private var model
    let template: ContractTemplate

    var body: some View {
        let used = model.packagesUsing(template).count
        HStack(spacing: Space.m) {
            Image(systemName: template.kind.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(template.title).font(.headline)
                Text("\(template.clauses.count) sections · version \(template.version) · \(used == 0 ? "not used yet" : "\(used) package\(used == 1 ? "" : "s")")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Who signs for the company, in the list of contracts.
struct CompanySignerRow: View {
    @Environment(AppModel.self) private var model
    let organization: Organization

    var body: some View {
        let signer = model.teamMembers.first { $0.isSigner }
        HStack(spacing: Space.m) {
            Image(systemName: signer == nil ? "exclamationmark.triangle.fill" : "building.2.crop.circle")
                .font(.title3)
                .foregroundStyle(signer == nil ? Color.slateWarning : Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Signs for \(organization.name)").font(.headline)
                if let signer {
                    Text(organization.signerTitle.isEmpty ? signer.displayName : "\(signer.displayName) · \(organization.signerTitle)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not chosen yet. Clients can't book until someone is.")
                        .font(.footnote)
                        .foregroundStyle(Color.slateWarning)
                }
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
    }
}

struct SignatureStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.m) {
            // For a company this is the person's own signature, which only matters if they sign for it.
            let ready = model.creatorSignature != nil || model.isCompanyActive
            Image(systemName: model.creatorSignature != nil ? "signature" : (model.isCompanyActive ? "signature" : "exclamationmark.triangle.fill"))
                .font(.title3)
                .foregroundStyle(ready ? Color.accentColor : Color.slateWarning)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(model.isCompanyActive ? "My signature" : "Your signature").font(.headline)
                if let signature = model.creatorSignature {
                    Text("\(signature.signedName) · \(signature.method == .drawn ? "drawn" : "typed")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if model.isCompanyActive {
                    Text("Add yours if you'll sign for the company.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Add it so clients can sign and book you.")
                        .font(.footnote)
                        .foregroundStyle(Color.slateWarning)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Creator signature

struct CreatorSignatureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var capture = SignatureCapture()
    @State private var isSaving = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Your signature").font(SlateFont.display).accessibilityAddTraits(.isHeader)
                        Text("Clients sign when they book. Yours is applied to the same contract so it's signed by both of you immediately.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    if let current = model.creatorSignature {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Current signature").eyebrow()
                            SignatureRow(signature: ContractSignature(
                                id: UUID(), role: .creator, userID: nil, signedName: current.signedName,
                                method: current.method, imagePNG: current.imagePNG, signedAt: current.updatedAt,
                                consentVersion: SigningConsent.version, device: ""
                            ))
                            .card()
                        }
                    }

                    SignatureSection(capture: capture, consent: SigningConsent.creatorAuthorization)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!capture.isReady)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .onAppear {
                if capture.fullName.isEmpty {
                    capture.fullName = model.creatorSignature?.signedName ?? model.profile?.displayName ?? ""
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveCreatorSignature(capture.creatorSignature())
            saved = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't save your signature")
        }
    }
}

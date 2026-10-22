import SwiftUI

/// Edit a contract: its title and sections, with fields that fill themselves in at booking time.
struct ContractTemplateEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ContractTemplate
    @State private var showPreview = false
    @State private var isSaving = false
    @State private var saved = false

    private let original: ContractTemplate

    init(template: ContractTemplate) {
        original = template
        _draft = State(initialValue: template)
    }

    private var problems: [ContractRules.Problem] { ContractRules.problems(in: draft) }
    private var hasChanges: Bool { draft.title != original.title || draft.clauses != original.clauses }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Contract title", text: $draft.title)
                        .frame(minHeight: Metrics.minTapTarget)
                }

                Section {
                    ForEach($draft.clauses) { $clause in
                        ClauseEditor(clause: $clause)
                    }
                    .onDelete { draft.clauses.remove(atOffsets: $0) }
                    .onMove { draft.clauses.move(fromOffsets: $0, toOffset: $1) }

                    if draft.clauses.count < ContractRules.clauseLimit {
                        Button {
                            withAnimation(.slateSnappy) {
                                draft.clauses.append(ContractClause(title: "", body: ""))
                            }
                        } label: {
                            Label("Add a section", systemImage: "plus.circle.fill")
                                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        }
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Use Insert field to add details that fill in automatically for each booking, like the client's name, the date and the price. Tap Edit to reorder or delete sections.")
                }

                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.slateWarning)
                        }
                    } header: {
                        Text("To finish")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button("Preview", systemImage: "eye") { showPreview = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!problems.isEmpty || !hasChanges)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.dismissKeyboard() }
                }
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .sensoryFeedback(.success, trigger: saved)
            .sheet(isPresented: $showPreview) {
                ContractReaderSheet(
                    contract: ContractRenderer.render(template: draft, values: ContractContextBuilder.sample)
                )
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveTemplate(draft)
            saved = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't save the contract")
        }
    }
}

private struct ClauseEditor: View {
    @Binding var clause: ContractClause

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField("Heading", text: $clause.title)
                .font(.headline)
                .frame(minHeight: Metrics.minTapTarget)

            TextField("What this section says", text: $clause.body, axis: .vertical)
                .lineLimit(3...14)
                .font(.body)

            HStack {
                Menu {
                    ForEach(ContractField.allCases) { field in
                        Button(field.title) { insert(field) }
                    }
                } label: {
                    Label("Insert field", systemImage: "curlybraces")
                        .font(.subheadline)
                        .frame(minHeight: Metrics.minTapTarget)
                }
                Spacer()
                Text("\(clause.body.count)/\(ContractRules.clauseBodyLimit)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(clause.body.count > ContractRules.clauseBodyLimit ? Color.slateWarning : Color.secondary)
            }
        }
        .padding(.vertical, Space.xs)
    }

    /// Adds the field at the end of the section. (SwiftUI text fields don't expose the cursor position.)
    private func insert(_ field: ContractField) {
        let needsSpace = !(clause.body.isEmpty || clause.body.hasSuffix(" ") || clause.body.hasSuffix("\n"))
        clause.body += (needsSpace ? " " : "") + field.token
    }
}

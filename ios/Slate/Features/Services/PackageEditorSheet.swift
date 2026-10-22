import SwiftUI

struct PackageEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PackageDraft
    @State private var editingAddOn: AddOn?
    @State private var isSaving = false
    @State private var saved = false
    @State private var confirmDelete = false

    init(package: ServicePackage) {
        _draft = State(initialValue: PackageDraft(package: package))
    }

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                pricingSection
                timeSection
                deliverablesSection
                addOnsSection
                contractSection
                visibilitySection
                problemsSection

                if !draft.isNew {
                    Section {
                        Button("Delete package", role: .destructive) { confirmDelete = true }
                            .frame(minHeight: Metrics.minTapTarget)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.isNew ? "New Package" : "Edit Package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!draft.canSave || (!draft.isNew && !draft.hasChanges))
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.dismissKeyboard() }
                }
            }
            .interactiveDismissDisabled(draft.hasChanges || isSaving)
            .sensoryFeedback(.success, trigger: saved)
            .sheet(item: $editingAddOn) { addOn in
                AddOnEditorSheet(
                    addOn: addOn,
                    currencyCode: draft.currencyCode,
                    isNew: !draft.addOns.contains { $0.id == addOn.id }
                ) { draft.upsert($0) }
            }
            .confirmationDialog("Delete this package?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Package", role: .destructive) {
                    Task {
                        await model.deletePackage(draft.original)
                        dismiss()
                    }
                }
            } message: {
                Text("Bookings you've already received keep their details.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section {
            TextField("Package name", text: $draft.name)
                .textInputAutocapitalization(.words)
                .frame(minHeight: Metrics.minTapTarget)

            TextField("Describe what clients get", text: $draft.summary, axis: .vertical)
                .lineLimit(3...8)
                .onChange(of: draft.summary) { _, new in
                    if new.count > PackageRules.summaryLimit {
                        draft.summary = String(new.prefix(PackageRules.summaryLimit))
                    }
                }

            Picker("Category", selection: $draft.category) {
                Text("None").tag(Specialty?.none)
                ForEach(Specialty.allCases) { specialty in
                    Label(specialty.title, systemImage: specialty.symbol).tag(Specialty?.some(specialty))
                }
            }
        } header: {
            Text("Basics")
        } footer: {
            Text("\(draft.summary.count)/\(PackageRules.summaryLimit)")
        }
    }

    private var pricingSection: some View {
        Section {
            LabeledContent("Price") {
                TextField("Price", value: $draft.price, format: .currency(code: draft.currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: Metrics.minTapTarget)

            LabeledContent("Deposit") {
                TextField("None", value: $draft.deposit, format: .currency(code: draft.currencyCode))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Deposit as a share of the price", selection: depositShare) {
                ForEach(PackageDraft.depositPercentOptions, id: \.self) { percent in
                    Text(percent == 0 ? "None" : percent == 100 ? "Full" : "\(percent)%").tag(Int?.some(percent))
                }
            }
            .pickerStyle(.segmented)
            .disabled(draft.priceCents <= 0)
        } header: {
            Text("Pricing")
        } footer: {
            Text(depositFooter)
        }
    }

    private var timeSection: some View {
        Section {
            Stepper(
                value: $draft.durationMinutes,
                in: PackageRules.durationRange,
                step: PackageRules.durationStep
            ) {
                LabeledContent("Duration", value: DurationText.short(minutes: draft.durationMinutes))
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Quick set", selection: durationPreset) {
                ForEach(PackageDraft.durationPresets, id: \.self) { minutes in
                    Text(DurationText.short(minutes: minutes)).tag(Int?.some(minutes))
                }
            }
            .pickerStyle(.segmented)

            Picker("Delivered within", selection: $draft.turnaroundDays) {
                ForEach(turnaroundOptions, id: \.self) { days in
                    Text(DurationText.turnaround(days: days)).tag(days)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)
        } header: {
            Text("Time")
        } footer: {
            Text("Duration is the shoot itself. Clients can only book times when you have that long free.")
        }
    }

    private var deliverablesSection: some View {
        Section {
            ForEach($draft.deliverables) { $row in
                TextField("e.g. 30 edited photos", text: $row.text)
                    .frame(minHeight: Metrics.minTapTarget)
            }
            .onDelete { draft.removeDeliverables(at: $0) }

            if draft.canAddDeliverable {
                Button {
                    withAnimation(.slateSnappy) { draft.addDeliverable() }
                } label: {
                    Label("Add deliverable", systemImage: "plus.circle.fill")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            }
        } header: {
            Text("What's included")
        } footer: {
            Text("Up to \(PackageRules.deliverableLimit). Swipe to delete.")
        }
    }

    private var addOnsSection: some View {
        Section {
            ForEach(draft.addOns) { addOn in
                Button {
                    editingAddOn = addOn
                } label: {
                    AddOnRow(addOn: addOn, currencyCode: draft.currencyCode)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { draft.removeAddOns(at: $0) }

            if draft.canAddAddOn {
                Menu {
                    ForEach(AddOnKind.allCases) { kind in
                        Button(kind.title, systemImage: kind.symbol) {
                            editingAddOn = AddOn(kind: kind)
                        }
                    }
                } label: {
                    Label("Add an add-on", systemImage: "plus.circle.fill")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            }
        } header: {
            Text("Optional add-ons")
        } footer: {
            Text("Clients can add these when they book. Extra time lengthens the booking.")
        }
    }

    private var contractSection: some View {
        Section {
            Picker("Contract", selection: $draft.contractTemplateID) {
                Text("None").tag(UUID?.none)
                ForEach(model.contractTemplates) { template in
                    Text(template.title).tag(UUID?.some(template.id))
                }
            }
            .frame(minHeight: Metrics.minTapTarget)

            Menu {
                ForEach(StarterTemplates.kinds) { kind in
                    Button(kind.title, systemImage: kind.symbol) { Task { await addStarter(kind) } }
                }
            } label: {
                Label("Add a starter contract", systemImage: "doc.badge.plus")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }

            Picker("Cancellation policy", selection: $draft.cancellationPolicy) {
                ForEach(CancellationPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Usage rights", selection: $draft.usageRights) {
                ForEach(UsageRights.allCases) { rights in
                    Text(rights.title).tag(rights)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)
        } header: {
            Text("Contract")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Clients sign this contract when they book. Cancellation: \(draft.cancellationPolicy.summary). Usage: \(draft.usageRights.summary).")
                if !model.hasCreatorSignature {
                    Text("Add your signature under Services > Contracts so clients can sign and book.")
                        .foregroundStyle(Color.slateWarning)
                }
            }
        }
    }

    private func addStarter(_ kind: ContractKind) async {
        do {
            let template = try await model.addStarterTemplate(kind)
            draft.contractTemplateID = template.id
        } catch {
            model.show(error, title: "Couldn't add the contract")
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle("Visible to clients", isOn: $draft.isPublished)
                .frame(minHeight: Metrics.minTapTarget)
        } footer: {
            Text("Turn this off to keep a draft only you can see.")
        }
    }

    @ViewBuilder
    private var problemsSection: some View {
        if draft.hasContent, !draft.problems.isEmpty {
            Section {
                ForEach(draft.problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.slateWarning)
                }
            } header: {
                Text("To finish")
            }
        }
    }

    // MARK: Bindings and text

    private var depositShare: Binding<Int?> {
        Binding(
            get: {
                guard let percent = draft.depositPercent, PackageDraft.depositPercentOptions.contains(percent) else { return nil }
                return percent
            },
            set: { if let percent = $0 { draft.setDeposit(percent: percent) } }
        )
    }

    private var durationPreset: Binding<Int?> {
        Binding(
            get: { PackageDraft.durationPresets.contains(draft.durationMinutes) ? draft.durationMinutes : nil },
            set: { if let minutes = $0 { draft.durationMinutes = minutes } }
        )
    }

    private var turnaroundOptions: [Int] {
        var options = PackageDraft.turnaroundPresets
        if !options.contains(draft.turnaroundDays) {
            options.append(draft.turnaroundDays)
            options.sort()
        }
        return options
    }

    private var depositFooter: String {
        guard draft.priceCents > 0 else { return "Enter a price, then choose a deposit." }
        if draft.depositCents > draft.priceCents { return "The deposit can't be more than the price." }
        if draft.depositCents == 0 { return "No deposit. The full price is due later." }
        let percent = draft.depositPercent ?? 0
        return "\(percent)% of the price is due when a client books. The rest, plus any add-ons, is due later."
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.savePackage(draft.makePackage())
            saved = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't save the package")
        }
    }
}

// MARK: - Add-on row

struct AddOnRow: View {
    let addOn: AddOn
    let currencyCode: String

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: addOn.kind.symbol)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(addOn.name.isEmpty ? addOn.kind.title : addOn.name)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.s)
            Text(Money.format(addOn.priceCents, code: currencyCode))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        var parts: [String] = []
        if addOn.extraMinutes > 0 { parts.append("+\(DurationText.short(minutes: addOn.extraMinutes))") }
        if addOn.turnaroundDeltaDays < 0 { parts.append("\(DurationText.turnaround(days: -addOn.turnaroundDeltaDays)) sooner") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Add-on editor

struct AddOnEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var addOn: AddOn
    @State private var price: Decimal?
    let currencyCode: String
    let isNew: Bool
    let onSave: (AddOn) -> Void

    init(addOn: AddOn, currencyCode: String, isNew: Bool, onSave: @escaping (AddOn) -> Void) {
        _addOn = State(initialValue: addOn)
        _price = State(initialValue: addOn.priceCents > 0 ? Money.decimal(cents: addOn.priceCents) : nil)
        self.currencyCode = currencyCode
        self.isNew = isNew
        self.onSave = onSave
    }

    private var candidate: AddOn {
        var copy = addOn
        copy.name = addOn.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.priceCents = price.map(Money.cents(from:)) ?? 0
        return copy
    }

    private var fasterDays: Binding<Int> {
        Binding(get: { -addOn.turnaroundDeltaDays }, set: { addOn.turnaroundDeltaDays = -$0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $addOn.name)
                        .textInputAutocapitalization(.sentences)
                        .frame(minHeight: Metrics.minTapTarget)
                    LabeledContent("Price") {
                        TextField("Price", value: $price, format: .currency(code: currencyCode))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }

                if addOn.kind == .extraTime || addOn.kind == .custom {
                    Section {
                        Stepper(value: $addOn.extraMinutes, in: 0...PackageRules.maxAddOnMinutes, step: 15) {
                            LabeledContent(
                                "Adds",
                                value: addOn.extraMinutes == 0 ? "No extra time" : DurationText.short(minutes: addOn.extraMinutes)
                            )
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    } header: {
                        Text("Extra time")
                    } footer: {
                        Text("Lengthens the booking, so it blocks more of your calendar.")
                    }
                }

                if addOn.kind == .rush || addOn.kind == .custom {
                    Section {
                        Stepper(value: fasterDays, in: 0...30) {
                            LabeledContent(
                                "Delivered sooner by",
                                value: fasterDays.wrappedValue == 0 ? "No change" : DurationText.turnaround(days: fasterDays.wrappedValue)
                            )
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    } header: {
                        Text("Faster delivery")
                    } footer: {
                        Text("Shortens the package's turnaround. It never goes below one day.")
                    }
                }
            }
            .navigationTitle(isNew ? "New Add-on" : "Edit Add-on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(candidate)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!PackageRules.problems(in: candidate).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.dismissKeyboard() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

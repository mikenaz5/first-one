import SwiftUI

/// How the company runs: the name on contracts, who gets bookings, who signs, how payouts work, and ending it.
struct CompanySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var legalName = ""
    @State private var legalAddress = ""
    @State private var loaded = false
    @State private var isSaving = false
    @State private var showPayments = false
    @State private var confirmDowngrade = false
    @State private var confirmClose = false

    private var organization: Organization? { model.organization }
    private var isOwner: Bool { organization?.myRole == .owner }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var legalProblem: String? {
        if !TeamRules.legalNameLength.contains(trimmed(legalName).count) {
            return "Use between \(TeamRules.legalNameLength.lowerBound) and \(TeamRules.legalNameLength.upperBound) characters."
        }
        if legalAddress.count > TeamRules.legalAddressLimit { return "Keep the address under \(TeamRules.legalAddressLimit) characters." }
        return nil
    }

    private var legalChanged: Bool {
        guard let organization else { return false }
        return trimmed(legalName) != organization.legalName || trimmed(legalAddress) != organization.legalAddress
    }

    var body: some View {
        Form {
            if let organization {
                legalSection
                assignmentSection(organization)
                signerSection(organization)
                payoutSection(organization)
                endingSection(organization)
            }
        }
        .navigationTitle("Company settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if legalChanged {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await saveLegal() } }
                            .fontWeight(.semibold)
                            .disabled(legalProblem != nil)
                    }
                }
            }
        }
        .onAppear {
            guard !loaded, let organization else { return }
            loaded = true
            legalName = organization.legalName
            legalAddress = organization.legalAddress
        }
        .sheet(isPresented: $showPayments) { PaymentSetupSheet() }
        .confirmationDialog("Go back to an individual account?", isPresented: $confirmDowngrade, titleVisibility: .visible) {
            Button("Go Back to Individual", role: .destructive) { Task { await downgrade() } }
        } message: {
            Text("Your services and contracts return to your own account. The company page closes, and contracts already signed keep its name.")
        }
        .confirmationDialog("Close \(organization?.name ?? "the company")?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Company", role: .destructive) { Task { await close() } }
        } message: {
            Text("The company page and its services go away for good. Signed contracts and past bookings are kept. This can't be undone.")
        }
    }

    // MARK: Sections

    private var legalSection: some View {
        Section {
            TextField("Legal name", text: $legalName)
                .disabled(!model.can(.companyEdit))
                .frame(minHeight: Metrics.minTapTarget)
            TextField("Address", text: $legalAddress, axis: .vertical)
                .lineLimit(2...4)
                .textContentType(.fullStreetAddress)
                .disabled(!model.can(.companyEdit))
                .frame(minHeight: Metrics.minTapTarget, alignment: .topLeading)
        } header: {
            Text("On contracts")
        } footer: {
            if let legalProblem, legalChanged {
                Text(legalProblem).foregroundStyle(Color.slateDanger)
            } else {
                Text("Every new contract is made in this name. Contracts already signed keep the name they were signed under.")
            }
        }
    }

    private func signerLine(_ signer: TeamMember?, _ organization: Organization) -> String {
        guard let signer else { return "Not chosen yet. Clients can't book until someone is." }
        return organization.signerTitle.isEmpty ? signer.displayName : "\(signer.displayName) · \(organization.signerTitle)"
    }

    private func assignmentSection(_ organization: Organization) -> some View {
        Section {
            ForEach(AssignmentMode.allCases) { mode in
                Button {
                    Task { await setMode(mode) }
                } label: {
                    HStack(alignment: .top, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(mode.title).font(.body.weight(.medium))
                            Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Space.s)
                        if organization.assignmentMode == mode {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(organization.assignmentMode == mode ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Text("New bookings go to people")
        } footer: {
            Text("A client can always book a named person directly. This is for bookings made with the company.")
        }
        .disabled(!model.can(.companyEdit))
        .sensoryFeedback(.selection, trigger: organization.assignmentMode)
    }

    private func signerSection(_ organization: Organization) -> some View {
        Section {
            let signer = model.teamMembers.first { $0.isSigner }
            NavigationLink {
                SignerPickerView()
            } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: signer == nil ? "exclamationmark.triangle.fill" : "signature")
                        .font(.title3)
                        .foregroundStyle(signer == nil ? Color.slateWarning : Color.accentColor)
                        .frame(minWidth: Metrics.iconColumn)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("Signs for the company").font(.body.weight(.medium))
                        Text(signerLine(signer, organization))
                            .font(.footnote)
                            .foregroundStyle(signer == nil ? Color.slateWarning : Color.secondary)
                    }
                }
                .frame(minHeight: Metrics.minTapTarget)
                .accessibilityElement(children: .combine)
            }
            .disabled(!model.can(.signerDesignate))

            if isOwner {
                ForEach([OrgRole.admin, .manager], id: \.self) { role in
                    Toggle(isOn: Binding(
                        get: { organization.signerRoles.contains(role) },
                        set: { allowed in Task { await setSignerRole(role, allowed: allowed) } }
                    )) {
                        Text("\(role.title)s may sign")
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }
            }
        } header: {
            Text("Contract signer")
        } footer: {
            Text(isOwner
                 ? "A contract is signed for the company by one named person, who counter-signs it as soon as the client has signed and paid. Owners can always sign; choose which other roles can be named."
                 : "A contract is signed for the company by one named person, who counter-signs it as soon as the client has signed and paid.")
        }
    }

    @ViewBuilder
    private func payoutSection(_ organization: Organization) -> some View {
        if model.can(.paymentsConnect) || model.can(.payoutsSplit) {
            Section {
                if model.can(.paymentsConnect) {
                    Button {
                        showPayments = true
                    } label: {
                        HStack(spacing: Space.m) {
                            Image(systemName: "creditcard")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(minWidth: Metrics.iconColumn)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text("Company payments").font(.body.weight(.medium))
                                Text((model.paymentAccount ?? .notConnected).title).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.can(.payoutsSplit) {
                    Toggle(isOn: Binding(
                        get: { organization.splitEnabled },
                        set: { enabled in Task { await setSplit(enabled) } }
                    )) {
                        Text("Split payouts between members")
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }
            } header: {
                Text("Payments")
            } footer: {
                Text("Clients pay the company's own Stripe account. With splitting on, you set each person's share and Slate keeps a ledger of what each is owed; the company pays them out itself.")
            }
        }
    }

    @ViewBuilder
    private func endingSection(_ organization: Organization) -> some View {
        if isOwner {
            Section {
                if organization.seats.used <= 1 {
                    Button("Go back to an individual account…", role: .destructive) { confirmDowngrade = true }
                        .frame(minHeight: Metrics.minTapTarget)
                }
                Button("Close company…", role: .destructive) { confirmClose = true }
                    .frame(minHeight: Metrics.minTapTarget)
            } footer: {
                Text(organization.seats.used <= 1
                     ? "Going back to an individual account needs nothing upcoming on the calendar."
                     : "To go back to an individual account, remove everyone else from the team first.")
            }
        }
    }

    // MARK: Actions

    private func saveLegal() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.updateCompany(OrganizationUpdate(legalName: trimmed(legalName), legalAddress: trimmed(legalAddress)))
        } catch {
            model.show(error, title: "Couldn't save")
        }
    }

    private func setMode(_ mode: AssignmentMode) async {
        guard organization?.assignmentMode != mode else { return }
        do {
            try await model.updateCompany(OrganizationUpdate(assignmentMode: mode))
        } catch {
            model.show(error, title: "Couldn't change how bookings are assigned")
        }
    }

    private func setSignerRole(_ role: OrgRole, allowed: Bool) async {
        guard let organization else { return }
        var roles = Set(organization.signerRoles)
        if allowed { roles.insert(role) } else { roles.remove(role) }
        roles.insert(.owner)
        do {
            try await model.updateCompany(OrganizationUpdate(signerRoles: OrgRole.allCases.filter { roles.contains($0) }))
        } catch {
            model.show(error, title: "Couldn't change who may sign")
        }
    }

    private func setSplit(_ enabled: Bool) async {
        do {
            try await model.setSplit(enabled: enabled)
        } catch {
            model.show(error, title: "Couldn't change payout splitting")
        }
    }

    private func downgrade() async {
        do {
            try await model.downgradeToIndividual()
            dismiss()
        } catch {
            model.show(error, title: "Couldn't go back to an individual account")
        }
    }

    private func close() async {
        do {
            try await model.closeCompany()
            dismiss()
        } catch {
            model.show(error, title: "Couldn't close the company")
        }
    }
}

// MARK: - Signer

/// Who countersigns the company's contracts. Anyone in an allowed role who has saved a signature.
struct SignerPickerView: View {
    @Environment(AppModel.self) private var model

    @State private var title = ""
    @State private var showSignature = false
    @State private var working: UUID?

    private var organization: Organization? { model.organization }
    private var eligible: [TeamMember] {
        guard let organization else { return [] }
        return model.teamMembers.filter { organization.signerRoles.contains($0.role) }
    }

    var body: some View {
        List {
            Section {
                TextField("Owner", text: $title)
                    .frame(minHeight: Metrics.minTapTarget)
            } header: {
                Text("Title on contracts")
            } footer: {
                Text("Shown under their name when they sign for the company, for example \"Owner\" or \"Managing Director\".")
            }

            Section {
                ForEach(eligible) { member in
                    Button {
                        Task { await choose(member) }
                    } label: {
                        HStack(spacing: Space.m) {
                            AvatarView(name: member.displayName, url: member.avatarURL, size: Metrics.avatarS)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(member.displayName).font(.headline)
                                Text(member.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Space.s)
                            if working == member.userID {
                                ProgressView()
                            } else if member.isSigner {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(member.isSigner ? [.isButton, .isSelected] : .isButton)
                }
            } header: {
                Text("Who signs")
            } footer: {
                Text("They need a signature saved in Slate. Each person adds their own, under Services ▸ Contracts.")
            }

            if model.creatorSignature == nil {
                Section {
                    Button {
                        showSignature = true
                    } label: {
                        Label("Add my signature", systemImage: "signature")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                }
            }
        }
        .navigationTitle("Contract signer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if title.isEmpty { title = organization?.signerTitle ?? "" }
        }
        .sheet(isPresented: $showSignature) { CreatorSignatureSheet() }
        .sensoryFeedback(.success, trigger: organization?.signerUserID)
    }

    private func choose(_ member: TeamMember) async {
        working = member.userID
        defer { working = nil }
        let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await model.designateSigner(member.userID, title: given.isEmpty ? member.role.title : given)
        } catch {
            model.show(error, title: "Couldn't choose the signer")
        }
    }
}

// MARK: - A member's own hours

/// A person's own working hours at the company. They can only narrow the company's, never widen them.
struct MyHoursView: View {
    @Environment(AppModel.self) private var model

    @State private var useCompanyHours = true
    @State private var days: [DayHours] = []
    @State private var loaded = false
    @State private var isSaving = false

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var changed: Bool {
        let current = model.organization?.myHours
        return useCompanyHours ? current != nil : current.map { Set($0) != Set(days) } ?? true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use the company's hours", isOn: $useCompanyHours)
                    .frame(minHeight: Metrics.minTapTarget)
            } footer: {
                Text("Your own hours can be shorter than the company's, never longer: you can't be booked when the company is closed.")
            }

            if !useCompanyHours {
                Section("My hours") {
                    ForEach(orderedWeekdays, id: \.self) { weekday in
                        MyDayRow(weekday: weekday, days: $days)
                    }
                }
            }
        }
        .navigationTitle("My hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if changed {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let mine = model.organization?.myHours {
                useCompanyHours = false
                days = mine
            } else {
                days = model.availability?.weekly ?? []
            }
        }
        .motionSafe(.slateSmooth, value: useCompanyHours)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveMyHours(useCompanyHours ? nil : days)
        } catch {
            model.show(error, title: "Couldn't save your hours")
        }
    }
}

private struct MyDayRow: View {
    let weekday: Int
    @Binding var days: [DayHours]

    private var name: String { Calendar.current.weekdaySymbols[weekday - 1] }
    private var window: TimeWindow? { days.first { $0.weekday == weekday }?.window }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Toggle(name, isOn: Binding(
                get: { window != nil },
                set: { open in
                    days.removeAll { $0.weekday == weekday }
                    if open {
                        let template = days.first?.window ?? TimeWindow(startMinute: 9 * 60, endMinute: 17 * 60)
                        days.append(DayHours(weekday: weekday, window: template))
                    }
                }
            ))
            .frame(minHeight: Metrics.minTapTarget)

            if let window {
                HStack(spacing: Space.m) {
                    DatePicker("Opens", selection: opens(window), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("\(name) from")
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("Closes", selection: closes(window), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("\(name) until")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func set(_ window: TimeWindow) {
        guard let index = days.firstIndex(where: { $0.weekday == weekday }) else { return }
        days[index].window = window
    }

    private func opens(_ window: TimeWindow) -> Binding<Date> {
        Binding(
            get: { AvailabilityLabels.date(forMinute: window.startMinute) },
            set: { date in
                var next = window
                next.startMinute = min(AvailabilityLabels.minute(of: date), 1425)
                if next.endMinute <= next.startMinute { next.endMinute = min(1440, next.startMinute + 60) }
                set(next)
            }
        )
    }

    private func closes(_ window: TimeWindow) -> Binding<Date> {
        Binding(
            get: { AvailabilityLabels.date(forMinute: window.endMinute % 1440) },
            set: { date in
                var next = window
                let minute = AvailabilityLabels.minute(of: date)
                next.endMinute = minute == 0 ? 1440 : minute
                if next.endMinute <= next.startMinute { next.startMinute = max(0, next.endMinute - 60) }
                set(next)
            }
        )
    }
}

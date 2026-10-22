import SwiftUI

/// The people on the team, and the invitations still out. Swipe a person to change their role or remove them.
struct MembersView: View {
    @Environment(AppModel.self) private var model

    @State private var showInvite = false
    @State private var detail: TeamMember?
    @State private var roleTarget: TeamMember?
    @State private var removeTarget: TeamMember?
    @State private var removalPlan: SeatPlan?
    @State private var resent: CreatedInvite?

    private var myRole: OrgRole { model.organization?.myRole ?? .viewer }
    private var me: UUID? { model.session?.userID }

    private func canManage(_ member: TeamMember) -> Bool {
        member.userID != me && model.can(.teamManage) && RoleRules.canManage(actor: myRole, target: member.role)
    }

    var body: some View {
        List {
            if let organization = model.organization {
                Section {
                    SeatsSummary(organization: organization, config: model.teamConfig)
                        .listRowInsets(EdgeInsets(top: Space.m, leading: Space.l, bottom: Space.m, trailing: Space.l))
                }
            }

            Section {
                ForEach(model.teamMembers) { member in
                    Button { detail = member } label: {
                        MemberRow(member: member, isMe: member.userID == me)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if canManage(member) {
                            Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                                Task { await askToRemove(member) }
                            }
                            if !RoleRules.assignableRoles(by: myRole, to: member.role).isEmpty {
                                Button("Role", systemImage: "person.badge.key") { roleTarget = member }
                                    .tint(.indigo)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Details", systemImage: "info.circle") { detail = member }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Details", systemImage: "info.circle") { detail = member }
                        if canManage(member), !RoleRules.assignableRoles(by: myRole, to: member.role).isEmpty {
                            Button("Change role…", systemImage: "person.badge.key") { roleTarget = member }
                        }
                        if canManage(member) {
                            Divider()
                            Button("Remove from team…", systemImage: "person.badge.minus", role: .destructive) {
                                Task { await askToRemove(member) }
                            }
                        }
                    }
                }
            } header: {
                Text("People")
            }

            if !model.teamInvites.isEmpty {
                Section {
                    ForEach(model.teamInvites) { invite in
                        InviteRow(invite: invite)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if model.can(.teamInvite) {
                                    Button("Revoke", systemImage: "xmark.circle", role: .destructive) {
                                        Task { await revoke(invite) }
                                    }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if model.can(.teamInvite) {
                                    Button("New link", systemImage: "link") { Task { await resend(invite) } }
                                        .tint(.indigo)
                                }
                            }
                    }
                } header: {
                    Text("Invited")
                } footer: {
                    Text("Each link works once. If one is lost, swipe right on the invite to replace it with a new link.")
                }
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.can(.teamInvite) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Invite", systemImage: "person.badge.plus") { showInvite = true }
                }
            }
        }
        .refreshable { await model.reloadCompany() }
        .sheet(isPresented: $showInvite) { InviteSheet() }
        .sheet(item: $detail) { member in
            MemberDetailSheet(member: member)
        }
        .sheet(item: $resent) { created in
            InviteLinkSheet(created: created)
        }
        .confirmationDialog(
            "Change role",
            isPresented: Binding(get: { roleTarget != nil }, set: { if !$0 { roleTarget = nil } }),
            titleVisibility: .visible,
            presenting: roleTarget
        ) { member in
            ForEach(RoleRules.assignableRoles(by: myRole, to: member.role).filter { $0 != member.role }) { role in
                Button(role.title) { Task { await change(member, to: role) } }
            }
        } message: { member in
            Text("\(member.displayName) is \(member.role.title) now.")
        }
        .confirmationDialog(
            "Remove \(removeTarget?.displayName ?? "this person")?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil; removalPlan = nil } }),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { member in
            Button("Remove from Team", role: .destructive) { Task { await remove(member) } }
        } message: { member in
            Text(removalMessage(for: member))
        }
        .sensoryFeedback(.success, trigger: model.teamMembers.count)
    }

    private func removalMessage(for member: TeamMember) -> String {
        var parts = ["\(member.displayName) loses access to the company. Their upcoming bookings go back to the queue to be given to someone else."]
        if let removalPlan {
            parts.append(removalPlan.billingSentence(periodEnd: model.organization?.plan.periodEnd))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    private func askToRemove(_ member: TeamMember) async {
        removalPlan = try? await model.previewSeatChange(delta: -1)
        removeTarget = member
    }

    private func remove(_ member: TeamMember) async {
        do { try await model.removeMember(member) } catch { model.show(error, title: "Couldn't remove \(member.displayName)") }
    }

    private func change(_ member: TeamMember, to role: OrgRole) async {
        do { try await model.setRole(role, for: member) } catch { model.show(error, title: "Couldn't change the role") }
    }

    private func revoke(_ invite: OrgInvite) async {
        do { try await model.revokeInvite(invite) } catch { model.show(error, title: "Couldn't revoke the invite") }
    }

    private func resend(_ invite: OrgInvite) async {
        do { resent = try await model.resendInvite(invite) } catch { model.show(error, title: "Couldn't make a new link") }
    }
}

extension CreatedInvite: Identifiable {
    var id: UUID { invite.id }
}

// MARK: - Rows

private struct SeatsSummary: View {
    let organization: Organization
    let config: TeamConfig

    var body: some View {
        let seats = organization.seats
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(seats.used)").font(.title.bold().monospacedDigit())
                Text(seats.used == 1 ? "person" : "people").font(.headline)
                Spacer()
                if seats.pending > 0 {
                    Text("+\(seats.pending) invited").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(seats.used + seats.pending), total: Double(max(seats.maximum, 1)))
                .tint(Color.accentColor)
            Text(billedLine(seats))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func billedLine(_ seats: SeatCounts) -> String {
        if seats.billed > seats.used {
            return "Billed for \(seats.billed) seats: the plan starts at \(seats.minimum). Room for \(seats.remaining) more, up to \(seats.maximum)."
        }
        return "Billed for \(seats.billed) seats. Room for \(seats.remaining) more, up to \(seats.maximum)."
    }
}

struct MemberRow: View {
    let member: TeamMember
    let isMe: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: member.displayName, url: member.avatarURL, size: Metrics.avatarS)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(member.displayName).font(.headline)
                    if isMe { Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(member.title.isEmpty ? member.role.title : "\(member.title) · \(member.role.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            if member.isSigner {
                Image(systemName: "signature")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Signs contracts for the company")
            }
            if !member.bookable && member.role.canTakeBookings {
                Image(systemName: "calendar.badge.minus")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Doesn't take bookings")
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens their team profile")
    }
}

private struct InviteRow: View {
    let invite: OrgInvite

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: invite.status == .expired ? "clock.badge.exclamationmark" : "envelope")
                .font(.title3)
                .foregroundStyle(invite.status == .expired ? Color.slateWarning : Color.accentColor)
                .frame(minWidth: Metrics.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(invite.email ?? "Invite link").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if invite.status == .expired { return "\(invite.role.title) · expired. Swipe right for a new link." }
        return "\(invite.role.title) · expires \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Invite

/// Choose a role (and, if you like, who it is for), then share a link that works once.
struct InviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var role: OrgRole = .creator
    @State private var email = ""
    @State private var plan: SeatPlan?
    @State private var created: CreatedInvite?
    @State private var isWorking = false

    private var roles: [OrgRole] { RoleRules.invitableRoles(by: model.organization?.myRole ?? .viewer) }
    private var cleanedEmail: String? { TeamRules.cleanInviteEmail(email) }
    private var emailIsFine: Bool { email.trimmingCharacters(in: .whitespaces).isEmpty || cleanedEmail != nil }
    private var planProblem: String? {
        guard let organization = model.organization else { return nil }
        if !organization.plan.isOK { return organization.plan.banner ?? "Choose a plan to invite your team." }
        if let plan, !plan.allowed { return "The team is at its limit of \(model.teamConfig.seatMaximum) seats." }
        return nil
    }

    var body: some View {
        NavigationStack {
            if let created {
                InviteLinkView(created: created, onDone: { dismiss() })
            } else {
                form
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
        .task {
            if !roles.contains(role), let first = roles.first { role = first }
            plan = try? await model.previewSeatChange(delta: 1)
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Role", selection: $role) {
                    ForEach(roles) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: Metrics.minTapTarget)
            } header: {
                Text("They'll be")
            } footer: {
                Text(role.summary)
            }

            Section {
                TextField("name@example.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: Metrics.minTapTarget)
            } header: {
                Text("Who it's for (optional)")
            } footer: {
                if !emailIsFine {
                    Text("That doesn't look like an email address.").foregroundStyle(Color.slateDanger)
                } else {
                    Text("Only a label, so you remember who it's for. The link works for whoever opens it, once. They join with their own Apple ID.")
                }
            }

            Section {
                if let planProblem {
                    Label(planProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.slateWarning)
                } else if let plan {
                    Text(plan.billingSentence(periodEnd: model.organization?.plan.periodEnd))
                        .font(.subheadline)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Seats")
            }
        }
        .navigationTitle("Invite someone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isWorking) }
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button("Create link") { Task { await create() } }
                        .fontWeight(.semibold)
                        .disabled(!emailIsFine || planProblem != nil)
                }
            }
        }
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            created = try await model.createInvite(role: role, email: cleanedEmail)
        } catch {
            model.show(error, title: "Couldn't create the invite")
        }
    }
}

/// A new link, with ways to send it. Shown after creating an invite, and after replacing a lost one.
struct InviteLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let created: CreatedInvite

    var body: some View {
        NavigationStack {
            InviteLinkView(created: created, onDone: { dismiss() })
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct InviteLinkView: View {
    @Environment(AppModel.self) private var model

    let created: CreatedInvite
    let onDone: () -> Void

    @State private var copied = false
    @State private var pretendName = ""
    @State private var addedPretend = false
    @State private var isAdding = false

    private var companyName: String { model.organization?.name ?? "the company" }

    private var message: String {
        let inviter = model.personalProfile?.displayName ?? "Someone"
        return "\(inviter) invited you to join \(companyName) on Slate as \(created.invite.role.title). Open this link on your iPhone: "
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Invite ready").font(SlateFont.display).accessibilityAddTraits(.isHeader)
                    Text("Send this link to your \(created.invite.role.title). It works once and expires on \(created.invite.expiresAt.formatted(date: .abbreviated, time: .omitted)). It isn't shown again.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if let link = created.link {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text(link.absoluteString)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()

                        ShareLink(
                            item: link,
                            subject: Text("Join \(companyName) on Slate"),
                            message: Text(message)
                        ) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        HStack(spacing: Space.m) {
                            Button {
                                UIPasteboard.general.url = link
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            if let mail = mailURL(link) {
                                Link(destination: mail) {
                                    Label("Email", systemImage: "envelope")
                                        .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                        }
                    }
                }

                if model.canAddPretendTeammate {
                    pretendTeammate
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone() }.fontWeight(.semibold) }
        }
        .sensoryFeedback(.success, trigger: copied)
        .sensoryFeedback(.success, trigger: addedPretend)
    }

    /// On a device with no server there is no second phone to open the link, so a teammate can be added by name to
    /// try the team features alone.
    private var pretendTeammate: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Try it on this device").eyebrow()
            Text("There's no server here, so you can add a pretend teammate to see how teams work.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Their name", text: $pretendName)
                .textContentType(.name)
                .frame(minHeight: Metrics.minTapTarget)
                .padding(.horizontal, Space.l)
                .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            Button {
                Task { await addPretend() }
            } label: {
                Group {
                    if isAdding { ProgressView() } else { Text(addedPretend ? "Added" : "Add pretend teammate") }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(pretendName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding || addedPretend)
        }
    }

    private func mailURL(_ link: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = created.invite.email ?? ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Join \(companyName) on Slate"),
            URLQueryItem(name: "body", value: message + link.absoluteString),
        ]
        return components.url
    }

    private func addPretend() async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await model.addPretendTeammate(accepting: created.invite, named: pretendName.trimmingCharacters(in: .whitespacesAndNewlines))
            addedPretend = true
        } catch {
            model.show(error, title: "Couldn't add them")
        }
    }
}

// MARK: - A person's team profile

struct MemberDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let member: TeamMember

    @State private var title: String
    @State private var listed: Bool
    @State private var bookable: Bool
    @State private var sharePercent: Double
    @State private var isSaving = false
    @State private var confirmTransfer = false

    init(member: TeamMember) {
        self.member = member
        _title = State(initialValue: member.title)
        _listed = State(initialValue: member.listed)
        _bookable = State(initialValue: member.bookable)
        _sharePercent = State(initialValue: Double(member.shareBps) / 100)
    }

    private var organization: Organization? { model.organization }
    private var myRole: OrgRole { organization?.myRole ?? .viewer }
    private var isMe: Bool { member.userID == model.session?.userID }
    /// Editing a team profile takes the right to manage the team, over this person (or over yourself).
    private var canEdit: Bool {
        model.can(.teamManage) && (isMe || RoleRules.canManage(actor: myRole, target: member.role))
    }
    private var showsShare: Bool { organization?.splitEnabled == true && model.can(.payoutsSplit) }
    private var canSign: Bool {
        guard let organization, model.can(.signerDesignate) else { return false }
        return organization.signerRoles.contains(member.role) && !member.isSigner
    }
    private var canTransfer: Bool { myRole == .owner && member.role != .owner && !isMe }
    private var shareBps: Int { Int((sharePercent * 100).rounded()) }

    private var hasChanges: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != member.title
            || listed != member.listed
            || bookable != member.bookable
            || (showsShare && shareBps != member.shareBps)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Space.m) {
                        AvatarView(name: member.displayName, url: member.avatarURL, size: Metrics.avatarM)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(member.displayName).font(.title3.weight(.semibold))
                            Text(member.role.title).font(.subheadline).foregroundStyle(.secondary)
                            Text("Joined \(member.joinedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Lead videographer", text: $title)
                        .disabled(!canEdit)
                        .frame(minHeight: Metrics.minTapTarget)
                    Toggle("Show on the company page", isOn: $listed)
                        .disabled(!canEdit)
                        .frame(minHeight: Metrics.minTapTarget)
                    if member.role.canTakeBookings {
                        Toggle("Takes bookings", isOn: $bookable)
                            .disabled(!canEdit)
                            .frame(minHeight: Metrics.minTapTarget)
                    }
                } header: {
                    Text("On the team")
                } footer: {
                    Text(member.role.canTakeBookings
                         ? "A person who takes bookings can be given them, and booked directly when they're shown on the page."
                         : "Viewers see the company's work but don't take bookings.")
                }

                if showsShare {
                    Section {
                        Stepper(value: $sharePercent, in: 0...100, step: 5) {
                            LabeledContent("Their share", value: "\(Int(sharePercent))%")
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    } header: {
                        Text("Payout share")
                    } footer: {
                        Text("Their share of each booking assigned to them. The company is paid first; Slate records the split and doesn't move the money.")
                    }
                }

                if canSign || member.isSigner {
                    Section {
                        if member.isSigner {
                            Label("Signs contracts for the company", systemImage: "signature")
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Button {
                                Task { await makeSigner() }
                            } label: {
                                Label("Make them the signer", systemImage: "signature")
                                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                            }
                        }
                    } header: {
                        Text("Contracts")
                    } footer: {
                        Text("The signer countersigns every contract the company makes. They need a signature saved in Slate first.")
                    }
                }

                if canTransfer {
                    Section {
                        Button("Make them the Owner…", role: .destructive) { confirmTransfer = true }
                            .frame(minHeight: Metrics.minTapTarget)
                    } footer: {
                        Text("The Owner handles billing and can close the company. You become an Admin.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(member.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(canEdit ? "Cancel" : "Done") { dismiss() }.disabled(isSaving) }
                if canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }.fontWeight(.semibold).disabled(!hasChanges)
                        }
                    }
                }
            }
            .confirmationDialog("Make \(member.displayName) the Owner?", isPresented: $confirmTransfer, titleVisibility: .visible) {
                Button("Transfer Ownership", role: .destructive) { Task { await transfer() } }
            } message: {
                Text("They take over billing and can close the company. You become an Admin, and only they can undo this.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var update = MemberUpdate()
            if cleanTitle != member.title { update.title = cleanTitle }
            if listed != member.listed { update.listed = listed }
            if bookable != member.bookable { update.bookable = bookable }
            if update != MemberUpdate() {
                try await model.updateMember(update, for: member)
            }
            if showsShare, shareBps != member.shareBps {
                try await model.setShare(bps: shareBps, for: member)
            }
            dismiss()
        } catch {
            model.show(error, title: "Couldn't save")
        }
    }

    private func makeSigner() async {
        do {
            try await model.designateSigner(member.userID, title: member.title.isEmpty ? member.role.title : member.title)
            dismiss()
        } catch {
            model.show(error, title: "Couldn't choose the signer")
        }
    }

    private func transfer() async {
        do {
            try await model.transferOwnership(to: member)
            dismiss()
        } catch {
            model.show(error, title: "Couldn't transfer ownership")
        }
    }
}

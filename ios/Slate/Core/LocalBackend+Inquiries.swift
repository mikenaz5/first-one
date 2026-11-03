import Foundation

/// Messaging before a booking, for the on-device backend. It follows `…_inquiries.sql` rule for rule.
///
/// An inquiry is the conversation between a client and a creator (or company) that starts from the Message button on the
/// creator's page. It lives in the same message list as booking conversations, keyed by its own id, so the screens treat
/// both alike. It holds typed text only: no system lines, because nothing has happened to a booking yet.
extension LocalBackend {
    // MARK: - Storage

    private var inquiriesURL: URL { root.appendingPathComponent("inquiries.json") }

    func readInquiries() -> [Inquiry] {
        read([Inquiry].self, from: inquiriesURL) ?? []
    }

    /// Stored dates are whole seconds, so use whole seconds: what this returns then equals what is read back later.
    private var inquiryNow: Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - Who is on which side

    /// The client, the person who sells alone, or (at a company) a member whose role covers every booking: the Owner,
    /// Admins and Managers can answer, Viewers can read. A member who only works the jobs assigned to them sees none,
    /// because an inquiry has nobody assigned. `public.provider_access(..., null, level)` is the same.
    func inquiryAccess(_ userID: UUID, _ inquiry: Inquiry, _ level: ProviderLevel, in orgs: [StoredOrganization]? = nil) -> Bool {
        if inquiry.clientID == userID || inquiry.creatorID == userID { return true }
        let all = orgs ?? readOrganizations()
        guard let org = all.first(where: { $0.id == inquiry.creatorID }), let member = activeMember(org, userID) else { return false }
        switch level {
        case .manage: return RoleRules.allows(.bookingsManage, role: member.role, state: org.state)
        case .view: return RoleRules.allows(.bookingsViewAll, role: member.role, state: org.state)
        }
    }

    func partyInquiry(_ id: UUID, for userID: UUID, level: ProviderLevel = .view) -> Inquiry? {
        readInquiries().first { $0.id == id && inquiryAccess(userID, $0, level) }
    }

    // MARK: - Starting one

    func startInquiry(with creator: CreatorProfile, clientName: String, by userID: UUID) async throws -> Inquiry {
        guard let stored = read(StoredProfile.self, from: profileURL(creator.id)) else { throw SlateError.notFound }
        // Nobody messages themselves, and nobody at a company messages their own company.
        let isMember = readOrganizations().first(where: { $0.id == creator.id }).flatMap { activeMember($0, userID) } != nil
        if creator.id == userID || isMember { throw SlateError.cannotMessageYourself }

        let name = InquiryRules.cleanName(clientName)
        var all = readInquiries()
        if let index = all.firstIndex(where: { $0.clientID == userID && $0.creatorID == creator.id }) {
            if !name.isEmpty, all[index].clientName != name {
                all[index].clientName = name
                try write(all, to: inquiriesURL)
            }
            return all[index]
        }

        let now = inquiryNow
        let today = all.filter { $0.clientID == userID && $0.createdAt > now.addingTimeInterval(-24 * 3600) }.count
        if today >= InquiryRules.perDay { throw SlateError.tooManyInquiries }

        let inquiry = Inquiry(
            id: UUID(), clientID: userID, creatorID: creator.id, clientName: name,
            creatorName: stored.displayName, createdAt: now
        )
        all.append(inquiry)
        try write(all, to: inquiriesURL)
        return inquiry
    }

    // MARK: - Writing

    /// A message to an inquiry. The same checks as a booking's (length, per-minute rate, sending again returns the stored
    /// one), plus the unanswered limit for the client.
    func sendInquiryMessage(_ body: String, inquiry: Inquiry, clientMessageID: UUID, from userID: UUID) throws -> Message {
        var messages = readMessages()
        if let existing = messages.first(where: { $0.bookingID == inquiry.id && $0.senderID == userID && $0.clientMessageID == clientMessageID }) {
            return existing
        }

        let cleaned = MessageRules.clean(body)
        if cleaned.isEmpty { throw SlateError.invalidMessage }
        if MessageRules.length(of: cleaned) > MessageRules.maxLength { throw SlateError.messageTooLong }

        let now = inquiryNow
        let recent = messages.filter { $0.kind == .text && $0.senderID == userID && $0.createdAt > now.addingTimeInterval(-60) }.count
        if recent >= MessageRules.sendsPerMinute { throw SlateError.rateLimited }

        if userID == inquiry.clientID {
            // A client who keeps writing with no answer stops at the limit. Any reply from the creator's side lifts it.
            let thread = messages.filter { $0.bookingID == inquiry.id && $0.kind == .text }
            let sinceReply = thread.lastIndex(where: { $0.senderID != inquiry.clientID }).map { Array(thread[($0 + 1)...]) } ?? thread
            if sinceReply.count >= InquiryRules.unansweredLimit { throw SlateError.awaitingReply }
        }

        let message = Message(
            id: UUID(), bookingID: inquiry.id, senderID: userID, kind: .text, body: cleaned, event: nil,
            data: MessageEventData(), clientMessageID: clientMessageID, createdAt: now
        )
        messages.append(message)
        try write(messages, to: messagesURL)
        try setReadMark(bookingID: inquiry.id, userID: userID, lastMessageID: message.id)
        return message
    }

    // MARK: - Deleting an account

    /// A deleted person's inquiries go with them, whichever side they were on, and so do their messages and read marks.
    func removeInquiries(involving userID: UUID) throws {
        let all = readInquiries()
        let gone = Set(all.filter { $0.clientID == userID || $0.creatorID == userID }.map(\.id))
        guard !gone.isEmpty else { return }
        try write(all.filter { !gone.contains($0.id) }, to: inquiriesURL)
        try dropConversations(gone)
    }
}

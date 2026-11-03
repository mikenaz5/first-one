import XCTest
@testable import Slate

/// Messaging before a booking: the numbers shared with the database, the on-device backend (which follows
/// `…_inquiries.sql` rule for rule), the app's side of the Message button, and what the Supabase backend decodes.
/// The same rules are tested in Postgres by `supabase/tests/inquiry_rules.py`.

// MARK: - Shared numbers

final class InquiryRulesTests: XCTestCase {
    func testTheNumbersAreTheOnesTheDatabaseIsTestedAgainst() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "inquiry_rules", withExtension: "json"),
            "inquiry_rules.json is missing from the test bundle"
        )
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(rules["inquiriesPerDay"] as? Int, InquiryRules.perDay)
        XCTAssertEqual(rules["unansweredLimit"] as? Int, InquiryRules.unansweredLimit)
        XCTAssertEqual(rules["maxMessageLength"] as? Int, MessageRules.maxLength)
    }

    func testANameIsTrimmedAndCutLikeTheDatabase() {
        XCTAssertEqual(InquiryRules.cleanName("  Alice A  "), "Alice A")
        XCTAssertEqual(InquiryRules.cleanName("   "), "")
        XCTAssertEqual(InquiryRules.cleanName(String(repeating: "B", count: 200)).count, InquiryRules.nameMaxLength)
    }

    func testTheNewErrorsSpeakPlainly() {
        for error in [SlateError.cannotMessageYourself, .tooManyInquiries, .awaitingReply] {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("_"), "No database words: \(text)")
        }
    }
}

// MARK: - The on-device backend

final class InquiryBackendTests: TeamTestCase {
    private let alice = UUID()
    private let bea = UUID()

    private func profile(_ id: UUID) async throws -> CreatorProfile {
        let found = try await backend.loadProfile(for: id)
        return try XCTUnwrap(found)
    }

    private func ask(_ text: String, in inquiry: Inquiry, as user: UUID? = nil, token: UUID = UUID()) async throws -> Message {
        try await backend.sendMessage(text, bookingID: inquiry.id, clientMessageID: token, from: user ?? alice)
    }

    private func start(with creator: UUID, as user: UUID? = nil, name: String = "Alice A") async throws -> Inquiry {
        try await backend.startInquiry(with: profile(creator), clientName: name, by: user ?? alice)
    }

    private func texts(_ inquiry: Inquiry, as user: UUID) async throws -> [String] {
        try await backend.loadMessages(bookingID: inquiry.id, since: nil, for: user).map(\.body)
    }

    // MARK: Starting

    func testStartingGivesTheSameConversationEachTime() async throws {
        let carol = try await person("Carol")
        let first = try await start(with: carol)
        let again = try await start(with: carol)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(first.creatorName, "Carol")
        XCTAssertEqual(first.clientName, "Alice A")
        let other = try await start(with: carol, as: bea, name: "Bea")
        XCTAssertNotEqual(other.id, first.id, "Each client has their own")
    }

    func testANewNameReplacesTheOldAndAnEmptyOneKeepsIt() async throws {
        let carol = try await person("Carol")
        let first = try await start(with: carol, name: "  Alice A  ")
        XCTAssertEqual(first.clientName, "Alice A")
        let renamed = try await start(with: carol, name: "Alice Adams")
        XCTAssertEqual(renamed.clientName, "Alice Adams")
        let kept = try await start(with: carol, name: "")
        XCTAssertEqual(kept.clientName, "Alice Adams")
    }

    func testNobodyMessagesThemselvesOrTheirOwnCompany() async throws {
        let carol = try await person("Carol")
        await expectError(.cannotMessageYourself) { try await start(with: carol, as: carol) }

        let company = try await makeCompany()
        for member in [company.owner, company.admin, company.manager, company.theo, company.viewer] {
            await expectError(.cannotMessageYourself) { try await start(with: company.org.id, as: member) }
        }
    }

    func testAnUnknownCreatorIsNotFound() async throws {
        let ghost = CreatorProfile(
            id: UUID(), handle: "ghost", displayName: "Ghost", bio: "", specialties: [], location: nil, avatarURL: nil,
            createdAt: Date(), updatedAt: Date()
        )
        await expectError(.notFound) { try await backend.startInquiry(with: ghost, clientName: "A", by: alice) }
    }

    func testOnlyTenNewConversationsAreAllowedInADay() async throws {
        var creators: [UUID] = []
        for index in 0...InquiryRules.perDay { creators.append(try await person("Creator\(index)")) }
        for creator in creators.prefix(InquiryRules.perDay) { _ = try await start(with: creator) }
        await expectError(.tooManyInquiries) { try await start(with: creators[InquiryRules.perDay]) }
        let again = try await start(with: creators[0])
        XCTAssertNotNil(again.id, "Going back to one already started is fine")
        clock.advance(by: 25 * 3600)
        _ = try await start(with: creators[InquiryRules.perDay])
    }

    func testNothingShowsInAnyListUntilSomeoneWrites() async throws {
        let carol = try await person("Carol")
        _ = try await start(with: carol)
        let clientList = try await backend.loadConversations(for: alice)
        let creatorList = try await backend.loadConversations(for: carol)
        XCTAssertTrue(clientList.isEmpty)
        XCTAssertTrue(creatorList.isEmpty)
    }

    // MARK: Writing and reading

    func testAQuestionReachesTheCreatorAndTheAnswerComesBack() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)

        let question = try await ask("Are you free on the 14th?", in: inquiry)
        XCTAssertEqual(question.bookingID, inquiry.id)
        XCTAssertEqual(question.kind, .text)

        let creatorList = try await backend.loadConversations(for: carol)
        let row = try XCTUnwrap(creatorList.first)
        XCTAssertTrue(row.isInquiry)
        XCTAssertEqual(row.counterpartName, "Alice A")
        XCTAssertEqual(row.unreadCount, 1)
        XCTAssertFalse(row.iAmClient)
        XCTAssertEqual(row.creatorID, carol)

        let clientRows = try await backend.loadConversations(for: alice)
        let clientRow = try XCTUnwrap(clientRows.first)
        XCTAssertEqual(clientRow.counterpartName, "Carol")
        XCTAssertEqual(clientRow.unreadCount, 0, "Writing back counts as having read")
        XCTAssertTrue(clientRow.iAmClient)

        _ = try await backend.sendMessage("Yes, the 14th is open.", bookingID: inquiry.id, clientMessageID: UUID(), from: carol)
        let unreadForClient = try await backend.loadConversations(for: alice).first?.unreadCount
        XCTAssertEqual(unreadForClient, 1)
        try await backend.markConversationRead(bookingID: inquiry.id, for: alice)
        let readForClient = try await backend.loadConversations(for: alice).first?.unreadCount
        XCTAssertEqual(readForClient, 0)
        let seen = try await texts(inquiry, as: carol)
        XCTAssertEqual(seen, ["Are you free on the 14th?", "Yes, the 14th is open."])
    }

    func testSendingAgainAfterADroppedConnectionStoresItOnce() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)
        let token = UUID()
        let first = try await ask("Hello", in: inquiry, token: token)
        let again = try await ask("Hello", in: inquiry, token: token)
        XCTAssertEqual(first.id, again.id)
        let stored = try await texts(inquiry, as: alice)
        XCTAssertEqual(stored, ["Hello"])
    }

    func testStrangersSeeNothingAndCannotWrite() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)
        _ = try await ask("Private question", in: inquiry)

        let seenByBea = try await texts(inquiry, as: bea)
        XCTAssertTrue(seenByBea.isEmpty)
        let beaList = try await backend.loadConversations(for: bea)
        XCTAssertTrue(beaList.isEmpty)
        await expectError(.bookingNotFound) { try await ask("hello?", in: inquiry, as: bea) }
        await expectError(.bookingNotFound) { try await backend.markConversationRead(bookingID: inquiry.id, for: bea) }
    }

    func testTheSameRulesAsABookingsMessages() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)
        await expectError(.invalidMessage) { try await ask("   \n ", in: inquiry) }
        await expectError(.messageTooLong) { try await ask(String(repeating: "x", count: MessageRules.maxLength + 1), in: inquiry) }
        let cleaned = try await ask("  hi\u{07} there \r\n", in: inquiry)
        XCTAssertEqual(cleaned.body, "hi there")
    }

    func testAClientCannotWriteForeverWithoutAnAnswer() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)
        for index in 0..<InquiryRules.unansweredLimit { _ = try await ask("message \(index)", in: inquiry) }
        await expectError(.awaitingReply) { try await ask("hello??", in: inquiry) }

        // A reply lifts it, and the creator is never held back.
        for index in 0..<3 { _ = try await backend.sendMessage("reply \(index)", bookingID: inquiry.id, clientMessageID: UUID(), from: carol) }
        _ = try await ask("thanks!", in: inquiry)
    }

    func testResendingTheLastAllowedMessageReturnsItInsteadOfFailing() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol)
        for index in 0..<(InquiryRules.unansweredLimit - 1) { _ = try await ask("m\(index)", in: inquiry) }
        let token = UUID()
        let last = try await ask("the last allowed", in: inquiry, token: token)
        let again = try await ask("the last allowed", in: inquiry, token: token)
        XCTAssertEqual(last.id, again.id)
    }

    // MARK: A company's inquiries

    func testAtACompanyTheLeadersAnswerTheViewerReadsAndACreatorSeesNothing() async throws {
        let company = try await makeCompany()
        let inquiry = try await start(with: company.org.id)
        _ = try await ask("Do you do corporate events?", in: inquiry)

        let clientRows = try await backend.loadConversations(for: alice)
        let clientRow = try XCTUnwrap(clientRows.first)
        XCTAssertEqual(clientRow.counterpartName, "Northlight Films")

        for (name, member, reads, answers) in [
            ("Owner", company.owner, true, true), ("Admin", company.admin, true, true), ("Manager", company.manager, true, true),
            ("Viewer", company.viewer, true, false), ("Creator", company.theo, false, false),
        ] {
            let seen = try await texts(inquiry, as: member)
            XCTAssertEqual(!seen.isEmpty, reads, "\(name) reading")
            let listed = try await backend.loadConversations(for: member).contains { $0.bookingID == inquiry.id }
            XCTAssertEqual(listed, reads, "\(name) has it in their list")
            if answers {
                _ = try await backend.sendMessage("\(name) here", bookingID: inquiry.id, clientMessageID: UUID(), from: member)
            } else {
                await expectError(.bookingNotFound) {
                    try await backend.sendMessage("\(name) here", bookingID: inquiry.id, clientMessageID: UUID(), from: member)
                }
            }
        }
    }

    func testAMemberWhoLeavesLosesTheConversation() async throws {
        let company = try await makeCompany()
        let inquiry = try await start(with: company.org.id)
        _ = try await ask("Hello", in: inquiry)
        let before = try await texts(inquiry, as: company.manager)
        XCTAssertFalse(before.isEmpty)
        try await backend.removeMember(memberID: company.manager, organizationID: company.org.id, by: company.owner)
        let after = try await texts(inquiry, as: company.manager)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Alongside bookings

    func testTheInquiryAndABookingAreTwoConversations() async throws {
        let company = try await makeCompany()
        let inquiry = try await start(with: company.org.id)
        _ = try await ask("Can you do the 6th?", in: inquiry)

        let signed = try await book(company, at: wednesday(10), client: alice)
        let list = try await backend.loadConversations(for: alice)
        XCTAssertEqual(Set(list.map(\.bookingID)), [inquiry.id, signed.booking.id])
        XCTAssertEqual(list.first { $0.bookingID == inquiry.id }?.isInquiry, true)
        XCTAssertEqual(list.first { $0.bookingID == signed.booking.id }?.isInquiry, false)
        let inquiryLines = try await backend.loadMessages(bookingID: inquiry.id, since: nil, for: alice)
        XCTAssertEqual(inquiryLines.map(\.body), ["Can you do the 6th?"], "The booking's lines are not in the inquiry")
    }

    // MARK: Deleting an account

    func testDeletingTheClientTakesTheirInquiriesWithThem() async throws {
        let carol = try await person("Carol")
        let inquiry = try await start(with: carol, as: bea, name: "Bea")
        _ = try await ask("Hello", in: inquiry, as: bea)
        try await backend.removeInquiries(involving: bea)
        let creatorList = try await backend.loadConversations(for: carol)
        XCTAssertTrue(creatorList.isEmpty)
        let lines = try await backend.loadMessages(bookingID: inquiry.id, since: nil, for: carol)
        XCTAssertTrue(lines.isEmpty)
    }
}

// MARK: - The app

@MainActor
final class InquiryAppModelTests: XCTestCase {
    private var world: NotificationWorld!

    override func tearDown() async throws {
        world?.tearDown()
        try await super.tearDown()
    }

    private func creatorProfile() async throws -> CreatorProfile {
        let found = try await world.backend.loadProfile(for: world.creatorID)
        return try XCTUnwrap(found)
    }

    func testTheMessageButtonOpensTheConversationBeforeAnyoneHasWritten() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        let profile = try await creatorProfile()
        await model.messageCreator(profile)

        let id = try XCTUnwrap(model.messagesPath.first)
        XCTAssertEqual(model.selectedTab, .messages)
        XCTAssertTrue(model.isInquiry(id))
        XCTAssertEqual(model.inquiryTitle(for: id), "Dana Lens")
        XCTAssertEqual(model.inquiryCreatorID(for: id), world.creatorID, "The person asking can get to the page to book")
        XCTAssertTrue(model.conversations.isEmpty, "Nothing shows in the list until a first message")
        XCTAssertNil(model.alert)
    }

    func testPressingItTwiceOpensTheSameConversation() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        let profile = try await creatorProfile()
        await model.messageCreator(profile)
        let first = model.messagesPath
        await model.messageCreator(profile)
        XCTAssertEqual(model.messagesPath, first)
        XCTAssertEqual(model.startedInquiries.count, 1)
    }

    func testAnOpenedPageClosesWhenTheConversationOpens() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        let profile = try await creatorProfile()
        model.presentedPage = PublicCreatorPage(profile: profile, portfolio: [], packages: [], team: [])
        await model.messageCreator(profile)
        XCTAssertNil(model.presentedPage)
    }

    func testTheWholeThingFromAQuestionToAnAnswer() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        let profile = try await creatorProfile()
        await model.messageCreator(profile)
        let id = try XCTUnwrap(model.messagesPath.first)

        let conversation = ConversationModel(bookingID: id, app: model)
        await conversation.load()
        XCTAssertTrue(conversation.hasLoaded)
        XCTAssertTrue(conversation.messages.isEmpty)

        let sent = await conversation.send("Are you free on the 14th?")
        XCTAssertTrue(sent)
        XCTAssertEqual(conversation.messages.map(\.body), ["Are you free on the 14th?"])
        XCTAssertTrue(conversation.pending.isEmpty)
        XCTAssertEqual(model.conversations.map(\.bookingID), [id], "Once someone writes it is in the list")
        XCTAssertEqual(model.unreadMessageCount, 0)

        _ = try await world.backend.sendMessage("Yes!", bookingID: id, clientMessageID: UUID(), from: world.creatorID)
        await model.refreshConversations()
        let row = try XCTUnwrap(model.conversation(for: id))
        XCTAssertTrue(row.isInquiry)
        XCTAssertEqual(row.counterpartName, "Dana Lens")
        XCTAssertEqual(model.unreadMessageCount, 1)
        XCTAssertEqual(model.inquiryTitle(for: id), "Dana Lens")

        await conversation.refresh()
        XCTAssertEqual(conversation.messages.map(\.body), ["Are you free on the 14th?", "Yes!"])
        XCTAssertEqual(model.unreadMessageCount, 0, "Seeing it on screen reads it")
    }

    func testMessagingYourselfIsExplainedNotHidden() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        // The signed-in person looks at a page that is theirs.
        let mine = CreatorProfile(
            id: model.session!.userID, handle: "me", displayName: "Me", bio: "", specialties: [], location: nil, avatarURL: nil,
            createdAt: Date(), updatedAt: Date()
        )
        await model.messageCreator(mine)
        XCTAssertFalse(model.alert?.message.isEmpty ?? true, "It says why instead of doing nothing")
        XCTAssertTrue(model.messagesPath.isEmpty)
    }

    func testSigningOutForgetsStartedConversations() async throws {
        world = try await NotificationWorld.make()
        let model = world.model
        let profile = try await creatorProfile()
        await model.messageCreator(profile)
        XCTAssertFalse(model.startedInquiries.isEmpty)
        await model.resetNotifications()
        XCTAssertTrue(model.startedInquiries.isEmpty)
    }
}

// MARK: - The server's answers

/// The Supabase backend against what the database really returns. `Fixtures/inquiry_rows.json` is written by
/// `supabase/tests/inquiry_rules.py --dump`, and that script fails if the database stops matching it.
final class InquiryRowDecodingTests: XCTestCase {
    private var rows: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "inquiry_rows", withExtension: "json"), "inquiry_rows.json is missing from the test bundle")
        rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Postgres writes microseconds; Foundation's ISO 8601 parser is only promised milliseconds, so trim them.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) { return date }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }

    private func load<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        let value = try XCTUnwrap(rows[key], "\(key) is missing from inquiry_rows.json")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder().decode(type, from: data)
    }

    func testAnInquiryInTheList() throws {
        let row: SupabaseBackend.ConversationRow = try load("conversationInquiry")
        let summary = try XCTUnwrap(row.summary)
        XCTAssertTrue(summary.isInquiry)
        XCTAssertTrue(summary.iAmClient)
        XCTAssertEqual(summary.counterpartName, "Carol Chen")
        XCTAssertNotNil(summary.creatorID)
        XCTAssertEqual(summary.last.kind, .text)
        XCTAssertEqual(summary.last.bookingID, summary.bookingID)
    }

    func testABookingInTheListIsStillABooking() throws {
        let row: SupabaseBackend.ConversationRow = try load("conversationBooking")
        let summary = try XCTUnwrap(row.summary)
        XCTAssertFalse(summary.isInquiry)
        XCTAssertNil(summary.creatorID, "The app works a booking's out from the booking")
    }

    func testAnOldRowWithoutTheNewColumnsStillDecodes() throws {
        var old = try XCTUnwrap(rows["conversationBooking"] as? [String: Any])
        for key in ["is_inquiry", "counterpart_name", "creator_id", "i_am_client"] { old[key] = nil }
        let data = try JSONSerialization.data(withJSONObject: old)
        let row = try decoder().decode(SupabaseBackend.ConversationRow.self, from: data)
        XCTAssertNotNil(row.summary)
        XCTAssertEqual(row.summary?.isInquiry, false)
    }

    func testAnInquirysMessageHasNoBooking() throws {
        let row: SupabaseBackend.MessageRow = try load("message")
        XCTAssertNil(row.bookingId)
        XCTAssertNotNil(row.inquiryId)
        let message = try XCTUnwrap(row.message)
        XCTAssertEqual(message.bookingID.uuidString.lowercased(), row.inquiryId)
        XCTAssertEqual(message.kind, .text)
        XCTAssertNotNil(message.senderID)
    }

    func testTheThreadDecodes() throws {
        let thread: [SupabaseBackend.MessageRow] = try load("messages")
        let messages = thread.compactMap(\.message)
        XCTAssertEqual(messages.count, thread.count, "Nothing is dropped")
        XCTAssertTrue(messages.allSatisfy { $0.kind == .text })
    }

    func testABookingsMessageStillHasItsBooking() throws {
        let row: SupabaseBackend.MessageRow = try load("messageOfBooking")
        XCTAssertNotNil(row.bookingId)
        XCTAssertNil(row.inquiryId)
        XCTAssertNotNil(row.message)
    }
}

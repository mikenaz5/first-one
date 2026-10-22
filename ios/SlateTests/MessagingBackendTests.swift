import XCTest
@testable import Slate

/// Conversations and notification settings against the on-device backend, on a clock the tests move by hand.
/// The same rules are tested in Postgres by `supabase/tests/booking_rules.py`.
final class MessagingBackendTests: XCTestCase {
    private var roots: [URL] = []
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var creator: Creator!

    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot below is Friday 22 Jan at 10:00.
    private let start = TestClock.date(2027, 1, 4, 8, 0)
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let client = UUID()
    private let stranger = UUID()

    private struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-messaging-\(UUID().uuidString)")
        roots.append(root)
        let clock = ManualClock(start)
        self.clock = clock
        backend = LocalBackend(root: root, clock: { clock.now })
        creator = try await makeCreator()
    }

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeCreator(handle: String = "dana-lens", deposit: Int = 50_000, on backend: LocalBackend? = nil) async throws -> Creator {
        let backend = backend ?? self.backend!
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: deposit, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .moderate
        ))
        return Creator(id: session.userID, package: saved[0])
    }

    @discardableResult
    private func book(
        _ creator: Creator? = nil, at date: Date? = nil, client: UUID? = nil, pay: Bool = true, on backend: LocalBackend? = nil
    ) async throws -> SignedBooking {
        let creator = creator ?? self.creator!
        let request = BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: date ?? friday, notes: "")
        return try await ContractFixtures.signedBooking(backend ?? self.backend!, request, clientID: client ?? self.client, pay: pay)
    }

    private func lines(_ bookingID: UUID, as user: UUID? = nil) async throws -> [Message] {
        try await backend.loadMessages(bookingID: bookingID, since: nil, for: user ?? client)
    }

    private func events(_ bookingID: UUID) async throws -> [Message.Event] {
        try await lines(bookingID).compactMap(\.event)
    }

    private func say(_ text: String, in bookingID: UUID, as user: UUID? = nil, token: UUID = UUID()) async throws -> Message {
        try await backend.sendMessage(text, bookingID: bookingID, clientMessageID: token, from: user ?? client)
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    private func unread(for user: UUID) async throws -> [Int] {
        try await backend.loadConversations(for: user).map(\.unreadCount)
    }

    // MARK: A booking's life in the conversation

    func testABookingStartsAConversationForBothPeople() async throws {
        let signed = try await book(pay: false)

        for user in [creator.id, client] {
            let list = try await backend.loadConversations(for: user)
            XCTAssertEqual(list.map(\.bookingID), [signed.booking.id])
            XCTAssertEqual(list.first?.last.event, .booked)
            XCTAssertEqual(list.first?.unreadCount, 0, "System lines are never unread")
        }
        let opening = try await lines(signed.booking.id)
        let first = try XCTUnwrap(opening.first)
        XCTAssertEqual(first.kind, .system)
        XCTAssertNil(first.senderID)
        XCTAssertEqual(first.data.packageName, "Portrait session")
        XCTAssertEqual(first.data.startAt, friday)
        XCTAssertEqual(first.data.timeZone, "America/Chicago")
    }

    func testPayingTheDepositAddsItsLineThenTheContractLine() async throws {
        let signed = try await book()
        let all = try await events(signed.booking.id)
        XCTAssertEqual(all, [.booked, .depositPaid, .contractSigned])
        let deposit = try await lines(signed.booking.id).first { $0.event == .depositPaid }
        XCTAssertEqual(deposit?.data.amountCents, 50_000)
        XCTAssertEqual(deposit?.data.currency, "USD")
    }

    func testWithoutADepositTheContractIsSignedAtOnce() async throws {
        let free = try await makeCreator(handle: "free-dana", deposit: 0)
        let signed = try await book(free)
        let all = try await events(signed.booking.id)
        XCTAssertEqual(all, [.booked, .contractSigned])
    }

    func testReportingTheSamePaymentAgainAddsNothing() async throws {
        let signed = try await book()
        let before = try await events(signed.booking.id)
        let payments = try await backend.loadPayments(for: client)
        let deposit = try XCTUnwrap(payments.first { $0.kind == .deposit })
        try await backend.completeSimulatedPayment(deposit.id)
        let after = try await events(signed.booking.id)
        XCTAssertEqual(before, after)
    }

    func testCancellingAddsALineWithWhoAndWhatComesBack() async throws {
        let signed = try await book()
        _ = try await backend.cancelBooking(signed.booking.id, by: client)

        let history = try await lines(signed.booking.id)
        let last = try XCTUnwrap(history.last)
        XCTAssertEqual(last.event, .cancelled)
        XCTAssertEqual(last.data.byCreator, false)
        XCTAssertEqual(last.data.refundCents, 50_000, "Eighteen days out, the moderate policy returns the whole deposit")
        XCTAssertEqual(last.data.currency, "USD")
    }

    func testACreatorCancellingIsRecordedAsTheCreator() async throws {
        let signed = try await book()
        _ = try await backend.cancelBooking(signed.booking.id, by: creator.id)
        let history = try await lines(signed.booking.id)
        let last = try XCTUnwrap(history.last)
        XCTAssertEqual(last.data.byCreator, true)
    }

    func testDeliveryAndTheBalanceAddTheirLines() async throws {
        let signed = try await book()
        clock.set(friday.addingTimeInterval(3 * 3600))
        _ = try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id)

        let afterDelivery = try await lines(signed.booking.id)
        let delivered = try XCTUnwrap(afterDelivery.last)
        XCTAssertEqual(delivered.event, .delivered)
        XCTAssertEqual(delivered.data.balanceCents, 150_000)

        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
        let afterPayment = try await lines(signed.booking.id)
        let paid = try XCTUnwrap(afterPayment.last)
        XCTAssertEqual(paid.event, .balancePaid)
        XCTAssertEqual(paid.data.amountCents, 150_000)

        let done = try await say("Thank you, the photos are great!", in: signed.booking.id)
        XCTAssertEqual(done.kind, .text, "A finished booking's conversation stays open")
    }

    func testAPaymentThatCameToNothingAddsNoLine() async throws {
        let signed = try await book(pay: false)
        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .deposit, by: client)
        _ = try await backend.cancelBooking(signed.booking.id, by: client)
        let linesBefore = try await events(signed.booking.id)
        try await backend.completeSimulatedPayment(info.paymentID)
        let linesAfter = try await events(signed.booking.id)
        XCTAssertEqual(linesBefore, linesAfter, "Money that was handed straight back isn't announced")
        XCTAssertFalse(linesAfter.contains(.depositPaid))
    }

    // MARK: Talking

    func testPeopleCanTalkAndSeeEachOthersMessages() async throws {
        let signed = try await book()
        let id = signed.booking.id
        let hello = try await say("Hi Dana, could we shoot outdoors?", in: id)
        XCTAssertEqual(hello.kind, .text)
        XCTAssertEqual(hello.senderID, client)
        XCTAssertEqual(hello.body, "Hi Dana, could we shoot outdoors?")
        XCTAssertNotNil(hello.clientMessageID)

        let reply = try await say("Yes, the park is lovely at golden hour.", in: id, as: creator.id)
        XCTAssertEqual(reply.senderID, creator.id)

        let theirView = try await lines(id, as: creator.id)
        let myView = try await lines(id, as: client)
        XCTAssertEqual(theirView, myView)
        XCTAssertEqual(myView.suffix(2).map(\.body), [hello.body, reply.body])
    }

    func testStrangersSeeAndSayNothing() async throws {
        let id = try await book().booking.id
        await expectError(.bookingNotFound) { try await say("hello?", in: id, as: stranger) }
        await expectError(.bookingNotFound) { try await backend.markConversationRead(bookingID: id, for: stranger) }
        let readable = try await lines(id, as: stranger)
        let list = try await backend.loadConversations(for: stranger)
        XCTAssertTrue(readable.isEmpty)
        XCTAssertTrue(list.isEmpty)
    }

    func testMessagesAreTidiedBeforeTheyAreStored() async throws {
        let id = try await book().booking.id
        let sent = try await say("  hello\r\nthere\u{7}  ", in: id)
        XCTAssertEqual(sent.body, "hello\nthere")
    }

    func testEmptyAndOverlongMessagesAreRefused() async throws {
        let id = try await book().booking.id
        await expectError(.invalidMessage) { try await say("", in: id) }
        await expectError(.invalidMessage) { try await say("  \n\t ", in: id) }
        await expectError(.messageTooLong) { try await say(String(repeating: "x", count: 2001), in: id) }
        let longest = try await say(String(repeating: "y", count: 2000), in: id)
        XCTAssertEqual(longest.body.count, 2000)
    }

    func testSendingTheSameMessageAgainReturnsTheFirstCopy() async throws {
        let id = try await book().booking.id
        let token = UUID()
        let first = try await say("Once only", in: id, token: token)
        let second = try await say("Once only", in: id, token: token)
        XCTAssertEqual(first, second)
        let texts = try await lines(id).filter { $0.kind == .text }
        XCTAssertEqual(texts.count, 1)

        let theirs = try await say("Same token, different person", in: id, as: creator.id, token: token)
        XCTAssertNotEqual(theirs.id, first.id)
    }

    func testTwentyMessagesAMinuteThenAPause() async throws {
        let id = try await book().booking.id
        for number in 1...20 { _ = try await say("message \(number)", in: id) }
        await expectError(.rateLimited) { try await say("one too many", in: id) }
        let reply = try await say("But the other person can still reply", in: id, as: creator.id)
        XCTAssertEqual(reply.kind, .text)

        let token = UUID()
        clock.advance(by: 61)
        let again = try await say("Back after a minute", in: id, token: token)
        XCTAssertEqual(again.body, "Back after a minute")
    }

    func testAMessageAlreadySavedIsAnsweredEvenOverTheLimit() async throws {
        let id = try await book().booking.id
        let token = UUID()
        let saved = try await say("the first", in: id, token: token)
        for number in 1..<20 { _ = try await say("filler \(number)", in: id) }
        await expectError(.rateLimited) { try await say("over", in: id) }
        let retried = try await say("the first", in: id, token: token)
        XCTAssertEqual(retried, saved)
    }

    // MARK: Unread

    func testEachMessageFromTheOtherPersonIsUnreadUntilTheyReadIt() async throws {
        let id = try await book().booking.id
        for text in ["one", "two", "three"] { _ = try await say(text, in: id) }

        let creatorsUnread = try await unread(for: creator.id)
        let clientsUnread = try await unread(for: client)
        XCTAssertEqual(creatorsUnread, [3])
        XCTAssertEqual(clientsUnread, [0], "Your own messages aren't unread to you")

        try await backend.markConversationRead(bookingID: id, for: creator.id)
        let cleared = try await unread(for: creator.id)
        XCTAssertEqual(cleared, [0])

        _ = try await say("got them", in: id, as: creator.id)
        let nowClient = try await unread(for: client)
        XCTAssertEqual(nowClient, [1])
    }

    func testWritingBackCountsAsReading() async throws {
        let id = try await book().booking.id
        _ = try await say("question", in: id, as: creator.id)
        let waiting = try await unread(for: client)
        XCTAssertEqual(waiting, [1])
        _ = try await say("answer", in: id)
        let answered = try await unread(for: client)
        XCTAssertEqual(answered, [0])
    }

    func testTwoMessagesInTheSameSecondAreNotMixedUp() async throws {
        // The clock never moves, so everything here has the same timestamp.
        let id = try await book().booking.id
        _ = try await say("first", in: id)
        try await backend.markConversationRead(bookingID: id, for: creator.id)
        _ = try await say("second", in: id)
        let waiting = try await unread(for: creator.id)
        XCTAssertEqual(waiting, [1], "Only the one after the read marker is new")
    }

    func testMarkingReadTwiceChangesNothing() async throws {
        let id = try await book().booking.id
        _ = try await say("hi", in: id)
        try await backend.markConversationRead(bookingID: id, for: creator.id)
        try await backend.markConversationRead(bookingID: id, for: creator.id)
        let result = try await unread(for: creator.id)
        XCTAssertEqual(result, [0])
    }

    func testReadMarkersSurviveARestart() async throws {
        let id = try await book().booking.id
        _ = try await say("hi", in: id)
        try await backend.markConversationRead(bookingID: id, for: creator.id)
        _ = try await say("again", in: id)

        let clock = self.clock!
        let root = await backend.root
        let reopened = LocalBackend(root: root, clock: { clock.now })
        let list = try await reopened.loadConversations(for: creator.id)
        XCTAssertEqual(list.map(\.unreadCount), [1])
        XCTAssertEqual(list.first?.last.body, "again")
    }

    // MARK: The list

    func testConversationsAreNewestFirst() async throws {
        let morning = try await book(at: friday)
        let afternoon = try await book(at: friday.addingTimeInterval(4 * 3600), client: UUID())
        let initial = try await backend.loadConversations(for: creator.id)
        XCTAssertEqual(initial.map(\.bookingID), [afternoon.booking.id, morning.booking.id], "The later booking has the later line")

        _ = try await say("about the morning", in: morning.booking.id)
        let bumped = try await backend.loadConversations(for: creator.id)
        XCTAssertEqual(bumped.map(\.bookingID), [morning.booking.id, afternoon.booking.id])
        XCTAssertEqual(bumped.first?.last.body, "about the morning")
    }

    func testEachPersonOnlySeesTheirOwnConversations() async throws {
        let mine = try await book()
        let other = try await book(at: friday.addingTimeInterval(4 * 3600), client: UUID())
        let list = try await backend.loadConversations(for: client)
        XCTAssertEqual(list.map(\.bookingID), [mine.booking.id])
        XCTAssertFalse(list.contains { $0.bookingID == other.booking.id })
    }

    func testLoadingOnlyWhatIsNew() async throws {
        let id = try await book().booking.id
        let early = try await say("early", in: id)
        clock.advance(by: 60)
        _ = try await say("later", in: id)
        let after = try await backend.loadMessages(bookingID: id, since: early.createdAt, for: client)
        XCTAssertEqual(after.map(\.body), ["later"])
    }

    // MARK: Closed conversations

    func testAHoldThatRanOutHasNoConversationAndAcceptsNoMessages() async throws {
        let held = try await book(pay: false)
        _ = try await say("Before it lapsed", in: held.booking.id)

        clock.advance(by: 16 * 60)
        let creatorList = try await backend.loadConversations(for: creator.id)
        let clientList = try await backend.loadConversations(for: client)
        XCTAssertTrue(creatorList.isEmpty)
        XCTAssertTrue(clientList.isEmpty)
        await expectError(.conversationClosed) { try await say("Anyone there?", in: held.booking.id) }
    }

    func testACancelledBookingsConversationStaysOpenForRefundQuestions() async throws {
        let signed = try await book()
        _ = try await backend.cancelBooking(signed.booking.id, by: client)
        let question = try await say("When will the refund arrive?", in: signed.booking.id)
        XCTAssertEqual(question.kind, .text)
        let list = try await backend.loadConversations(for: creator.id)
        XCTAssertEqual(list.map(\.bookingID), [signed.booking.id])
    }

    func testTestingYourOwnPackageGivesAConversationWithYourself() async throws {
        let signed = try await book(client: creator.id)
        let note = try await say("A note to myself", in: signed.booking.id, as: creator.id)
        XCTAssertTrue(note.isFrom(creator.id))
        let counts = try await unread(for: creator.id)
        XCTAssertEqual(counts, [0], "You haven't missed what you wrote")
    }

    // MARK: Settings and devices

    func testNotificationSettingsStartOnAndAreKeptPerPerson() async throws {
        let before = try await backend.loadNotificationPreferences(for: client)
        XCTAssertEqual(before, NotificationPreferences())

        var changed = NotificationPreferences()
        changed.messages = false
        changed.reminders = false
        let saved = try await backend.saveNotificationPreferences(changed, for: client)
        XCTAssertEqual(saved, changed)

        let again = try await backend.loadNotificationPreferences(for: client)
        let theirs = try await backend.loadNotificationPreferences(for: creator.id)
        XCTAssertEqual(again, changed)
        XCTAssertEqual(theirs, NotificationPreferences(), "Settings belong to the person who set them")

        let clock = self.clock!
        let root = await backend.root
        let reopened = LocalBackend(root: root, clock: { clock.now })
        let afterRestart = try await reopened.loadNotificationPreferences(for: client)
        XCTAssertEqual(afterRestart, changed)
    }

    func testOnDeviceNothingSendsPushFromAServer() async {
        let sends = await backend.sendsPushFromServer
        XCTAssertFalse(sends)
    }

    func testADeviceBelongsToWhoeverRegisteredItLast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-devices-\(UUID().uuidString)")
        roots.append(root)
        let server = LocalBackend(root: root, sendsPushFromServer: true)
        let sends = await server.sendsPushFromServer
        XCTAssertTrue(sends)

        let first = UUID(), second = UUID()
        try await server.registerDevice(token: "abc123", environment: .sandbox, for: first)
        try await server.registerDevice(token: "abc123", environment: .production, for: second)
        let devices = await server.registeredDevices()
        XCTAssertEqual(devices, [LocalBackend.RegisteredDevice(token: "abc123", environment: .production, userID: second)])

        try await server.unregisterDevice(token: "abc123")
        let none = await server.registeredDevices()
        XCTAssertTrue(none.isEmpty)
    }
}

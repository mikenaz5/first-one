import XCTest
@testable import Slate

/// The rules the database and the app must agree on, from the shared fixture `notification_rules.json`.
final class SharedNotificationRulesTests: XCTestCase {
    private struct Rules: Decodable {
        struct Cleaning: Decodable {
            var input: String
            var expected: String
        }

        var reminderLeadMinutes: [Int]
        var maxMessageLength: Int
        var messageCleaning: [Cleaning]
    }

    private func load() throws -> Rules {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "notification_rules", withExtension: "json"),
            "notification_rules.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
    }

    func testTidyingMatchesTheDatabaseOnEverySharedCase() throws {
        let rules = try load()
        XCTAssertGreaterThanOrEqual(rules.messageCleaning.count, 20)
        for example in rules.messageCleaning {
            XCTAssertEqual(MessageRules.clean(example.input), example.expected, "for \(example.input.debugDescription)")
        }
    }

    func testTidyingIsStable() throws {
        for example in try load().messageCleaning {
            XCTAssertEqual(MessageRules.clean(example.expected), example.expected, "for \(example.expected.debugDescription)")
        }
    }

    func testTheLimitsMatchTheDatabase() throws {
        let rules = try load()
        XCTAssertEqual(MessageRules.maxLength, rules.maxMessageLength)
        XCTAssertEqual(ReminderRules.leadMinutes, rules.reminderLeadMinutes)
    }
}

final class MessageRulesTests: XCTestCase {
    func testWhitespaceAndControlCharactersAreTidiedAway() {
        XCTAssertEqual(MessageRules.clean("  hello  "), "hello")
        XCTAssertEqual(MessageRules.clean("a\r\nb"), "a\nb")
        XCTAssertEqual(MessageRules.clean("a\rb"), "a\nb")
        XCTAssertEqual(MessageRules.clean("bell\u{7} ring"), "bell ring")
        XCTAssertEqual(MessageRules.clean("tab\there"), "tab\there")
        XCTAssertEqual(MessageRules.clean("\n\n hi \n\n"), "hi")
    }

    func testSwiftTreatsCRLFAsOneCharacterButTheRuleDoesNot() {
        // "\r\n" is a single Character in Swift. Cleaning works on scalars so a lone CR and CRLF both become one LF.
        XCTAssertEqual(MessageRules.clean("x\r\n\r\ny"), "x\n\ny")
        XCTAssertEqual(MessageRules.clean("x\r\r\ny"), "x\n\ny")
        XCTAssertEqual(MessageRules.clean("end\r"), "end")
    }

    func testOnlyRealSpacesAreTrimmed() {
        XCTAssertEqual(MessageRules.clean("\u{00A0}x\u{00A0}"), "\u{00A0}x\u{00A0}", "A no-break space is content")
        XCTAssertEqual(MessageRules.clean("a\u{2028}b"), "a\u{2028}b", "A Unicode line separator is not a line break here")
    }

    func testLengthCountsCodePointsLikeTheDatabase() {
        XCTAssertEqual(MessageRules.length(of: "abc"), 3)
        XCTAssertEqual(MessageRules.length(of: "📸"), 1)
        XCTAssertEqual(MessageRules.length(of: "e\u{301}"), 2, "A letter plus an accent is two code points, as in SQL")
    }

    func testWhatCanBeSent() {
        XCTAssertEqual(MessageRules.problem(with: ""), .empty)
        XCTAssertEqual(MessageRules.problem(with: "  \n\t "), .empty)
        XCTAssertEqual(MessageRules.problem(with: "\u{1}\u{7}"), .empty)
        XCTAssertNil(MessageRules.problem(with: "hi"))
        XCTAssertNil(MessageRules.problem(with: String(repeating: "x", count: 2000)))
        XCTAssertEqual(MessageRules.problem(with: String(repeating: "x", count: 2001)), .tooLong)
        XCTAssertNil(MessageRules.problem(with: String(repeating: "📸", count: 2000)))
        XCTAssertEqual(MessageRules.problem(with: String(repeating: "📸", count: 2001)), .tooLong)
    }

    func testPaddingDoesNotCountTowardTheLimit() {
        XCTAssertNil(MessageRules.problem(with: "   " + String(repeating: "x", count: 2000) + "   "))
    }

    func testRemainingCharacters() {
        XCTAssertEqual(MessageRules.remaining(in: ""), 2000)
        XCTAssertEqual(MessageRules.remaining(in: "  hello "), 1995)
        XCTAssertEqual(MessageRules.remaining(in: String(repeating: "x", count: 2003)), -3)
    }
}

final class ConversationMergeTests: XCTestCase {
    private let booking = UUID()
    private let t0 = TestClock.date(2027, 1, 4, 9, 0)

    private func message(_ text: String, at seconds: TimeInterval, id: UUID = UUID(), clientID: UUID? = nil) -> Message {
        Message(
            id: id, bookingID: booking, senderID: UUID(), kind: .text, body: text, event: nil, data: MessageEventData(),
            clientMessageID: clientID, createdAt: t0.addingTimeInterval(seconds)
        )
    }

    func testLinesComeOutInTimeOrder() {
        let a = message("a", at: 10), b = message("b", at: 5), c = message("c", at: 20)
        XCTAssertEqual(ConversationMerge.merge([a], [c, b]).map(\.body), ["b", "a", "c"])
    }

    func testEachMessageAppearsOnceAndTheNewerCopyWins() {
        let id = UUID()
        let first = message("old", at: 10, id: id)
        var second = first
        second.body = "new"
        let merged = ConversationMerge.merge([first], [second, second])
        XCTAssertEqual(merged.map(\.body), ["new"])
    }

    func testLinesWithTheSameTimeKeepTheOrderTheyArrivedIn() {
        // Stored times can be whole seconds, so several lines can share one.
        let a = message("a", at: 10), b = message("b", at: 10), c = message("c", at: 10)
        XCTAssertEqual(ConversationMerge.merge([a, b], [c]).map(\.body), ["a", "b", "c"])
        XCTAssertEqual(ConversationMerge.merge([], [c, a, b]).map(\.body), ["c", "a", "b"])
    }

    func testAnEarlierLineThatArrivesLateSlotsIntoPlace() {
        let a = message("a", at: 10), late = message("late", at: 5), z = message("z", at: 30)
        XCTAssertEqual(ConversationMerge.merge([a, z], [late]).map(\.body), ["late", "a", "z"])
    }

    func testPendingMessagesAreDoneOnceTheServerReturnsThem() {
        let clientID = UUID()
        let pending = [
            PendingMessage(id: clientID, body: "sent", createdAt: t0, state: .sending),
            PendingMessage(id: UUID(), body: "still going", createdAt: t0, state: .sending),
        ]
        let stored = message("sent", at: 1, clientID: clientID)
        let settled = ConversationMerge.settle(pending, against: [stored])
        XCTAssertEqual(settled.map(\.body), ["still going"])
    }

    func testAskingForWhatIsNewLooksBackAFewSeconds() {
        XCTAssertNil(ConversationMerge.cursor(for: []))
        let cursor = ConversationMerge.cursor(for: [message("a", at: 100), message("b", at: 50)])
        XCTAssertEqual(cursor, t0.addingTimeInterval(95))
    }
}

final class ConversationTextTests: XCTestCase {
    private let creatorID = UUID()
    private let clientID = UUID()
    private let friday = TestClock.date(2027, 1, 22, 10, 0)

    private var booking: Booking {
        Booking(
            id: UUID(), creatorID: creatorID, clientID: clientID, creatorName: "Dana Lens", clientName: "Sam Client",
            packageID: nil, packageName: "Portrait session", addOns: [], startAt: friday, endAt: friday.addingTimeInterval(3600),
            blockedUntil: friday.addingTimeInterval(5400), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: 200_000, depositCents: 50_000, status: .confirmed, notes: "", createdAt: friday.addingTimeInterval(-86_400 * 18)
        )
    }

    private func line(_ event: Message.Event, _ data: MessageEventData = MessageEventData(), in booking: Booking) -> Message {
        Message(id: UUID(), bookingID: booking.id, senderID: nil, kind: .system, body: "", event: event, data: data, clientMessageID: nil, createdAt: friday)
    }

    private func text(_ event: Message.Event, _ data: MessageEventData = MessageEventData(), as viewer: UUID?) -> String {
        let booking = self.booking
        return ConversationText.systemLine(line(event, data, in: booking), booking: booking, viewerID: viewer)
    }

    func testBookedReadsFromEachSide() {
        let data = MessageEventData(packageName: "Portrait session", startAt: friday, timeZone: "America/Chicago")
        XCTAssertEqual(text(.booked, data, as: clientID), "You booked Portrait session for Fri, Jan 22 at 10:00 AM.")
        XCTAssertEqual(text(.booked, data, as: creatorID), "Sam Client booked Portrait session for Fri, Jan 22 at 10:00 AM.")
    }

    func testPaymentsNameTheAmount() {
        let deposit = MessageEventData(amountCents: 50_000, currency: "USD")
        XCTAssertEqual(text(.depositPaid, deposit, as: clientID), "You paid the $500 deposit.")
        XCTAssertEqual(text(.depositPaid, deposit, as: creatorID), "Sam Client paid the $500 deposit.")
        let balance = MessageEventData(amountCents: 150_050, currency: "USD")
        XCTAssertEqual(text(.balancePaid, balance, as: clientID), "You paid the $1,500.50 balance. All done.")
    }

    func testContractSigned() {
        XCTAssertEqual(text(.contractSigned, as: clientID), "The contract is signed by both of you.")
    }

    func testDeliveryTellsEachSideWhatIsDue() {
        let owed = MessageEventData(balanceCents: 150_000, currency: "USD")
        XCTAssertEqual(text(.delivered, owed, as: creatorID), "You marked the work as delivered. Sam Client owes $1,500.")
        XCTAssertEqual(text(.delivered, owed, as: clientID), "Dana Lens marked the work as delivered. The balance of $1,500 is due.")
        let settled = MessageEventData(balanceCents: 0, currency: "USD")
        XCTAssertEqual(text(.delivered, settled, as: creatorID), "You marked the work as delivered.")
        XCTAssertEqual(text(.delivered, settled, as: clientID), "Dana Lens marked the work as delivered. Nothing more is due.")
    }

    func testCancellationSaysWhoAndWhatComesBack() {
        let byClient = MessageEventData(refundCents: 25_000, currency: "USD", byCreator: false)
        XCTAssertEqual(text(.cancelled, byClient, as: clientID), "You cancelled this booking. $250 is on its way back to you.")
        XCTAssertEqual(text(.cancelled, byClient, as: creatorID), "Sam Client cancelled this booking. $250 is being refunded to them.")
        let byCreator = MessageEventData(refundCents: 50_000, currency: "USD", byCreator: true)
        XCTAssertEqual(text(.cancelled, byCreator, as: creatorID), "You cancelled this booking. Sam Client is being refunded $500.")
        XCTAssertEqual(text(.cancelled, byCreator, as: clientID), "Dana Lens cancelled this booking. You'll be refunded $500.")
        let nothing = MessageEventData(refundCents: 0, currency: "USD", byCreator: false)
        XCTAssertEqual(text(.cancelled, nothing, as: clientID), "You cancelled this booking.")
        XCTAssertEqual(text(.cancelled, nothing, as: creatorID), "Sam Client cancelled this booking.")
    }

    func testWithoutTheBookingTheWordingStaysNeutral() {
        let message = line(.depositPaid, MessageEventData(amountCents: 50_000, currency: "USD"), in: booking)
        XCTAssertEqual(ConversationText.systemLine(message, booking: nil, viewerID: clientID), "The client paid the $500 deposit.")
    }

    func testPreviewsShowWhoSaidWhat() {
        let booking = self.booking
        let mine = Message(id: UUID(), bookingID: booking.id, senderID: clientID, kind: .text, body: "See you\nthen", event: nil,
                           data: MessageEventData(), clientMessageID: nil, createdAt: friday)
        XCTAssertEqual(ConversationText.preview(of: mine, booking: booking, viewerID: clientID), "You: See you then")
        XCTAssertEqual(ConversationText.preview(of: mine, booking: booking, viewerID: creatorID), "See you then")
        XCTAssertEqual(
            ConversationText.preview(of: line(.contractSigned, in: booking), booking: booking, viewerID: clientID),
            "The contract is signed by both of you."
        )
    }

    func testSystemLinesAreNeverFromAPerson() {
        let booking = self.booking
        XCTAssertFalse(line(.booked, in: booking).isFrom(clientID))
        XCTAssertFalse(line(.booked, in: booking).isFrom(nil))
    }

    func testMessagesRoundTripThroughJSONAsTheDatabaseWritesThem() throws {
        let json = """
        {"id":"\(UUID().uuidString)","bookingID":"\(UUID().uuidString)","kind":"system","body":"","event":"deposit_paid",
         "data":{"amountCents":50000,"currency":"USD"},"createdAt":"2027-01-04T15:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.event, .depositPaid)
        XCTAssertEqual(message.data.amountCents, 50_000)
        XCTAssertNil(message.senderID)
    }
}

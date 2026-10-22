import XCTest
@testable import Slate

/// Delivering files, confirming them and reviewing, against the on-device backend, on a clock the tests move by hand.
/// The same rules are tested in Postgres by `supabase/tests/booking_rules.py`.
final class DeliveryBackendTests: XCTestCase {
    private var roots: [URL] = []
    private var root: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var creator: Creator!

    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot below is Friday 22 Jan at 10:00.
    private let start = TestClock.date(2027, 1, 4, 8, 0)
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let client = UUID()
    private let stranger = UUID()
    private static let files = "https://files.example.com/final"

    private struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-delivery-\(UUID().uuidString)")
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

    private func makeCreator(handle: String = "dana-lens", deposit: Int = 50_000) async throws -> Creator {
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
    private func book(_ creator: Creator? = nil, at date: Date? = nil, client: UUID? = nil, name: String = "Sam Client") async throws -> SignedBooking {
        let creator = creator ?? self.creator!
        let request = BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: date ?? friday, notes: "")
        return try await ContractFixtures.signedBooking(backend, request, clientID: client ?? self.client, name: name)
    }

    private func booking(_ id: UUID) async throws -> Booking {
        let all = try await backend.loadBookings(for: client)
        return try XCTUnwrap(all.first { $0.id == id })
    }

    /// The shoot is over and the files have been shared.
    private func afterTheShoot(_ signed: SignedBooking, creator: Creator? = nil) async throws {
        let creator = creator ?? self.creator!
        clock.set(signed.booking.endAt.addingTimeInterval(3600))
        _ = try await backend.shareDelivery(bookingID: signed.booking.id, link: Self.files, note: "", by: creator.id)
    }

    /// Delivered, confirmed and paid: a finished booking, ready for a review.
    private func complete(_ signed: SignedBooking, creator: Creator? = nil) async throws {
        try await afterTheShoot(signed, creator: creator)
        _ = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    // MARK: Sharing

    func testOnlyTheCreatorOfAConfirmedBookingWhoseShootHasStartedCanShare() async throws {
        let signed = try await book()
        let id = signed.booking.id
        await expectError(.notDeliverable) { try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: creator.id) }
        clock.set(friday.addingTimeInterval(1800))
        await expectError(.bookingNotFound) { try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: client) }
        await expectError(.bookingNotFound) { try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: stranger) }
        let shared = try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: creator.id)
        XCTAssertEqual(shared.deliveryURL, Self.files)
        XCTAssertEqual(shared.deliveredAt, clock.now)
        XCTAssertEqual(shared.status, .confirmed)
    }

    func testAHeldBookingCannotBeDelivered() async throws {
        let held = try await ContractFixtures.signedBooking(
            backend,
            BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: friday, notes: ""),
            clientID: client, pay: false
        )
        XCTAssertEqual(held.booking.status, .held)
        clock.set(friday.addingTimeInterval(60))
        await expectError(.notDeliverable) { try await backend.shareDelivery(bookingID: held.booking.id, link: Self.files, note: "", by: creator.id) }
    }

    func testALinkThatIsNotAPlainHTTPSAddressIsRefusedAndNothingChanges() async throws {
        let signed = try await book()
        clock.set(friday.addingTimeInterval(1800))
        for link in ["", "http://files.example.com/x", "files.example.com/x", "https://localhost/x", "https://user:pw@files.example.com/x", "https://files.example.com/a b"] {
            await expectError(.invalidDeliveryLink) { try await backend.shareDelivery(bookingID: signed.booking.id, link: link, note: "", by: creator.id) }
        }
        let after = try await booking(signed.booking.id)
        XCTAssertNil(after.deliveryURL)
        XCTAssertNil(after.deliveredAt)
        let events = try await backend.loadMessages(bookingID: signed.booking.id, since: nil, for: client).compactMap(\.event)
        XCTAssertFalse(events.contains(.deliveryShared))
    }

    func testANoteIsTidiedAndLimited() async throws {
        let signed = try await book()
        clock.set(friday.addingTimeInterval(1800))
        await expectError(.deliveryNoteTooLong) {
            try await backend.shareDelivery(bookingID: signed.booking.id, link: Self.files, note: String(repeating: "n", count: DeliveryRules.noteMaxLength + 1), by: creator.id)
        }
        let tidy = try await backend.shareDelivery(bookingID: signed.booking.id, link: "  \(Self.files)  ", note: "  Password:\r\nlake  ", by: creator.id)
        XCTAssertEqual(tidy.deliveryURL, Self.files)
        XCTAssertEqual(tidy.deliveryNote, "Password:\nlake")
        let blank = try await backend.shareDelivery(bookingID: signed.booking.id, link: Self.files, note: " \n ", by: creator.id)
        XCTAssertNil(blank.deliveryNote, "A blank note is no note")
    }

    func testTheLinkCanBeReplacedUntilTheClientConfirms() async throws {
        let signed = try await book()
        try await afterTheShoot(signed)
        let firstShared = clock.now
        clock.set(firstShared.addingTimeInterval(600))
        let replaced = try await backend.shareDelivery(bookingID: signed.booking.id, link: "https://files.example.com/corrected", note: "Fixed", by: creator.id)
        XCTAssertEqual(replaced.deliveryURL, "https://files.example.com/corrected")
        XCTAssertEqual(replaced.deliveredAt, firstShared, "When it was first shared doesn't move")

        _ = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        await expectError(.notDeliverable) { try await backend.shareDelivery(bookingID: signed.booking.id, link: Self.files, note: "", by: creator.id) }
    }

    // MARK: Confirming

    func testConfirmingNeedsSharedFilesAndTheClient() async throws {
        let signed = try await book()
        let id = signed.booking.id
        clock.set(friday.addingTimeInterval(1800))
        await expectError(.notDelivered) { try await backend.confirmReceipt(bookingID: id, by: client) }
        _ = try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: creator.id)
        await expectError(.bookingNotFound) { try await backend.confirmReceipt(bookingID: id, by: creator.id) }
        await expectError(.bookingNotFound) { try await backend.confirmReceipt(bookingID: id, by: stranger) }
        let confirmed = try await backend.confirmReceipt(bookingID: id, by: client)
        XCTAssertEqual(confirmed.receiptConfirmedAt, clock.now)
        XCTAssertEqual(confirmed.status, .confirmed, "A balance is still owed")
    }

    func testConfirmingTwiceChangesNothing() async throws {
        let signed = try await book()
        try await afterTheShoot(signed)
        let first = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        clock.set(clock.now.addingTimeInterval(3600))
        let second = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        XCTAssertEqual(second.receiptConfirmedAt, first.receiptConfirmedAt)
        let events = try await backend.loadMessages(bookingID: signed.booking.id, since: nil, for: client).compactMap(\.event)
        XCTAssertEqual(events.filter { $0 == .receiptConfirmed }.count, 1)
    }

    func testTheBalanceIsOnlyPayableAfterConfirming() async throws {
        let signed = try await book()
        try await afterTheShoot(signed)
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client) }
        _ = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client)
        XCTAssertEqual(info.amountCents, 150_000)
    }

    func testNothingOwedMeansConfirmingCompletesTheBookingAndItCanBeReviewed() async throws {
        let paidUp = try await makeCreator(handle: "paid-up", deposit: 200_000)
        let signed = try await book(paidUp)
        try await afterTheShoot(signed, creator: paidUp)
        let confirmed = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
        XCTAssertEqual(confirmed.status, .completed)
        let review = try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "Perfect", by: client)
        XCTAssertEqual(review.rating, 5)
    }

    // MARK: Reviewing

    func testAReviewNeedsAFinishedBooking() async throws {
        let signed = try await book()
        let id = signed.booking.id
        await expectError(.notReviewable) { try await backend.submitReview(bookingID: id, rating: 5, body: "", by: client) }
        try await afterTheShoot(signed)
        await expectError(.notReviewable) { try await backend.submitReview(bookingID: id, rating: 5, body: "", by: client) }
        _ = try await backend.confirmReceipt(bookingID: id, by: client)
        await expectError(.notReviewable) { try await backend.submitReview(bookingID: id, rating: 5, body: "", by: client) }
        let info = try await backend.preparePayment(bookingID: id, kind: .balance, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
        let review = try await backend.submitReview(bookingID: id, rating: 5, body: "", by: client)
        XCTAssertEqual(review.rating, 5)
    }

    func testOnlyTheClientCanReview() async throws {
        let signed = try await book()
        try await complete(signed)
        await expectError(.bookingNotFound) { try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "I am great", by: creator.id) }
        await expectError(.bookingNotFound) { try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "x", by: stranger) }
    }

    func testRatingsAndLengthAreChecked() async throws {
        let signed = try await book()
        try await complete(signed)
        let id = signed.booking.id
        for rating in [0, 6, -3] {
            await expectError(.invalidRating) { try await backend.submitReview(bookingID: id, rating: rating, body: "x", by: client) }
        }
        await expectError(.reviewTooLong) {
            try await backend.submitReview(bookingID: id, rating: 4, body: String(repeating: "é", count: ReviewRules.maxLength + 1), by: client)
        }
        let none = try await backend.loadReview(bookingID: id, for: client)
        XCTAssertNil(none, "Refused attempts leave nothing behind")
    }

    func testOneReviewPerBookingAndTheFirstStands() async throws {
        let signed = try await book()
        try await complete(signed)
        let first = try await backend.submitReview(bookingID: signed.booking.id, rating: 4, body: "  Great work,\r\nfast turnaround.  ", by: client)
        XCTAssertEqual(first.body, "Great work,\nfast turnaround.")
        XCTAssertEqual(first.reviewerName, "Sam C.")
        XCTAssertEqual(first.packageName, "Portrait session")
        XCTAssertEqual(first.creatorID, creator.id)
        XCTAssertEqual(first.createdAt, clock.now)
        await expectError(.alreadyReviewed) { try await backend.submitReview(bookingID: signed.booking.id, rating: 1, body: "Changed my mind", by: client) }
        let kept = try await backend.loadReview(bookingID: signed.booking.id, for: client)
        XCTAssertEqual(kept, first)
    }

    func testOnlyThePeopleOnABookingCanReadItsReview() async throws {
        let signed = try await book()
        try await complete(signed)
        let review = try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "Lovely", by: client)
        let forCreator = try await backend.loadReview(bookingID: signed.booking.id, for: creator.id)
        XCTAssertEqual(forCreator, review)
        let forStranger = try await backend.loadReview(bookingID: signed.booking.id, for: stranger)
        XCTAssertNil(forStranger)
    }

    // MARK: A creator's page

    func testAPublicListCarriesNoBookingAndComesNewestFirst() async throws {
        // Book them all now (a day's notice is needed), then finish them one after another as the clock moves on.
        var bookings: [SignedBooking] = []
        for index in 0..<3 {
            bookings.append(try await book(at: TestClock.date(2027, 1, 25 + index, 10, 0)))
        }
        for (index, rating) in [5, 3, 4].enumerated() {
            try await complete(bookings[index])
            _ = try await backend.submitReview(bookingID: bookings[index].booking.id, rating: rating, body: "Review \(index)", by: client)
        }
        let list = try await backend.loadReviews(creatorID: creator.id, limit: 20, before: nil)
        XCTAssertEqual(list.map(\.rating), [4, 3, 5], "Newest first")
        XCTAssertTrue(list.allSatisfy { $0.bookingID == nil }, "A public page doesn't say which booking")
        XCTAssertEqual(list.map(\.reviewerName), ["Sam C.", "Sam C.", "Sam C."])

        let page = try await backend.loadReviews(creatorID: creator.id, limit: 1, before: nil)
        XCTAssertEqual(page.map(\.rating), [4])
        let older = try await backend.loadReviews(creatorID: creator.id, limit: 20, before: try XCTUnwrap(page.first).createdAt)
        XCTAssertEqual(older.map(\.rating), [3, 5])
        let clamped = try await backend.loadReviews(creatorID: creator.id, limit: 0, before: nil)
        XCTAssertEqual(clamped.count, 1, "A limit below one still returns one")

        let summary = try await backend.loadReviewSummary(creatorID: creator.id)
        XCTAssertEqual(summary, ReviewSummary(count: 3, ratingSum: 12))
        XCTAssertEqual(try XCTUnwrap(summary.average), 4.0, accuracy: 0.0001)
    }

    func testEachCreatorHasTheirOwnReviews() async throws {
        let other = try await makeCreator(handle: "someone-else")
        let signed = try await book()
        try await complete(signed)
        _ = try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "Yes", by: client)
        let none = try await backend.loadReviews(creatorID: other.id, limit: 20, before: nil)
        XCTAssertTrue(none.isEmpty)
        let summary = try await backend.loadReviewSummary(creatorID: other.id)
        XCTAssertEqual(summary, .empty)
    }

    func testAfterRestartingTheAppTheDeliveryAndReviewAreStillThere() async throws {
        let signed = try await book(name: "Alex Rivera")
        try await complete(signed)
        _ = try await backend.submitReview(bookingID: signed.booking.id, rating: 5, body: "Great", by: client)

        let clock = self.clock!
        let reopened = LocalBackend(root: root, clock: { clock.now })
        let bookings = try await reopened.loadBookings(for: client)
        let found = try XCTUnwrap(bookings.first { $0.id == signed.booking.id })
        XCTAssertEqual(found.deliveryURL, Self.files)
        XCTAssertNotNil(found.receiptConfirmedAt)
        XCTAssertEqual(found.status, .completed)
        let review = try await reopened.loadReview(bookingID: signed.booking.id, for: client)
        XCTAssertEqual(review?.reviewerName, "Alex R.")
    }
}

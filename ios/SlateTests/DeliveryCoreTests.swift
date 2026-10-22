import XCTest
@testable import Slate

/// The rules the database and the app must agree on, from the shared fixture `delivery_rules.json`.
final class SharedDeliveryRulesTests: XCTestCase {
    private struct Rules: Decodable {
        struct LinkCase: Decodable {
            var input: String
            var clean: String?
        }

        struct NameCase: Decodable {
            var input: String
            var display: String
        }

        var urlMaxLength: Int
        var noteMaxLength: Int
        var reviewMaxLength: Int
        var urls: [LinkCase]
        var names: [NameCase]
    }

    private func load() throws -> Rules {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "delivery_rules", withExtension: "json"),
            "delivery_rules.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
    }

    func testTheLimitsMatchTheDatabase() throws {
        let rules = try load()
        XCTAssertEqual(DeliveryRules.linkMaxLength, rules.urlMaxLength)
        XCTAssertEqual(DeliveryRules.noteMaxLength, rules.noteMaxLength)
        XCTAssertEqual(ReviewRules.maxLength, rules.reviewMaxLength)
    }

    func testLinkCleaningMatchesTheDatabaseOnEverySharedCase() throws {
        let rules = try load()
        XCTAssertGreaterThanOrEqual(rules.urls.count, 60)
        for example in rules.urls {
            XCTAssertEqual(DeliveryRules.cleanLink(example.input), example.clean, "for \(example.input.debugDescription)")
        }
    }

    func testCleaningALinkTwiceChangesNothing() throws {
        for example in try load().urls {
            guard let clean = example.clean else { continue }
            XCTAssertEqual(DeliveryRules.cleanLink(clean), clean, "for \(clean.debugDescription)")
        }
    }

    func testReviewerNamesReadTheSameAsInTheDatabase() throws {
        let rules = try load()
        XCTAssertGreaterThanOrEqual(rules.names.count, 10)
        for example in rules.names {
            XCTAssertEqual(ReviewRules.displayName(for: example.input), example.display, "for \(example.input.debugDescription)")
        }
    }

    func testTheLengthLimitIsExactlyTheDatabases() {
        let stem = "https://example.com/"
        let longest = stem + String(repeating: "a", count: DeliveryRules.linkMaxLength - stem.count)
        XCTAssertEqual(DeliveryRules.cleanLink(longest), longest)
        XCTAssertNil(DeliveryRules.cleanLink(longest + "a"))
        XCTAssertEqual(DeliveryRules.cleanLink("  \(longest)  "), longest, "Trimming happens before counting")
        XCTAssertEqual(DeliveryRules.linkProblem(in: longest + "a"), .tooLong)
    }
}

final class DeliveryRulesTests: XCTestCase {
    func testWhatAPersonPastesIsTidiedAndKept() {
        XCTAssertEqual(DeliveryRules.cleanLink("  https://www.dropbox.com/scl/fo/abc?rlkey=k&dl=0\n"), "https://www.dropbox.com/scl/fo/abc?rlkey=k&dl=0")
        XCTAssertEqual(DeliveryRules.url(for: "https://we.tl/t-AbC123")?.host(), "we.tl")
        XCTAssertNil(DeliveryRules.url(for: "http://we.tl/t-AbC123"))
    }

    func testEachProblemIsNamedSoTheCreatorKnowsWhatToFix() {
        XCTAssertEqual(DeliveryRules.linkProblem(in: ""), .empty)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "   "), .empty)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "http://example.com/x"), .notSecure)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "example.com/x"), .notSecure)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "https://example.com/a b"), .invalid)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "https://user:pw@example.com/x"), .invalid)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "https://localhost/x"), .invalid)
        XCTAssertEqual(DeliveryRules.linkProblem(in: "https://192.168.0.1/x"), .invalid)
        XCTAssertNil(DeliveryRules.linkProblem(in: "https://example.com/x"))
    }

    func testANoteIsTidiedLikeAMessage() {
        XCTAssertEqual(DeliveryRules.cleanNote("  Password:\r\nlake  "), "Password:\nlake")
        XCTAssertNil(DeliveryRules.cleanNote("  \n "), "Nothing left means no note")
        XCTAssertFalse(DeliveryRules.noteIsTooLong(String(repeating: "n", count: DeliveryRules.noteMaxLength)))
        XCTAssertTrue(DeliveryRules.noteIsTooLong(String(repeating: "n", count: DeliveryRules.noteMaxLength + 1)))
        XCTAssertFalse(DeliveryRules.noteIsTooLong("  " + String(repeating: "n", count: DeliveryRules.noteMaxLength) + "  "), "Counted after tidying")
    }
}

// MARK: - What to show on a booking

final class DeliverySummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func booking(
        _ status: BookingStatus = .confirmed, deposit: Int = 50_000, total: Int = 200_000,
        shared: Bool = false, received: Bool = false, startsIn hours: Double = -2, note: String? = nil
    ) -> Booking {
        Booking(
            id: UUID(), creatorID: UUID(), clientID: UUID(), creatorName: "Dana Lens", clientName: "Sam Client",
            packageID: nil, packageName: "Portrait session", addOns: [],
            startAt: now.addingTimeInterval(hours * 3600), endAt: now.addingTimeInterval(hours * 3600 + 3600),
            blockedUntil: now.addingTimeInterval(hours * 3600 + 5400), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: total, depositCents: deposit, status: status, notes: "", createdAt: now.addingTimeInterval(-86_400 * 30),
            deliveredAt: shared ? now.addingTimeInterval(-60) : nil,
            deliveryURL: shared ? "https://files.example.com/final" : nil, deliveryNote: shared ? note : nil,
            receiptConfirmedAt: received ? now.addingTimeInterval(-30) : nil
        )
    }

    private func summary(_ booking: Booking, as viewer: PaymentSummary.Viewer) -> DeliverySummary? {
        DeliverySummary.make(booking: booking, viewer: viewer, now: now)
    }

    func testNothingShowsBeforeTheShootStarts() {
        XCTAssertNil(summary(booking(startsIn: 5), as: .creator))
        XCTAssertNil(summary(booking(startsIn: 5), as: .client))
    }

    func testNothingShowsForBookingsThatNeverHappened() {
        for status in [BookingStatus.held, .cancelled, .expired] {
            XCTAssertNil(summary(booking(status), as: .creator), "\(status)")
            XCTAssertNil(summary(booking(status, shared: true), as: .client), "\(status)")
        }
    }

    func testAfterTheShootTheCreatorIsInvitedToShare() throws {
        let result = try XCTUnwrap(summary(booking(), as: .creator))
        XCTAssertEqual(result.stage, .readyToShare)
        XCTAssertTrue(result.canShare)
        XCTAssertFalse(result.canConfirm)
        XCTAssertNil(result.link)
        XCTAssertEqual(result.tone, .warning)
        XCTAssertTrue(result.detail.contains("then pays the remaining $1,500"), result.detail)
    }

    func testWhenNothingIsOwedTheCreatorIsToldTheBookingCompletes() throws {
        let result = try XCTUnwrap(summary(booking(deposit: 200_000), as: .creator))
        XCTAssertTrue(result.detail.contains("and the booking is complete"), result.detail)
    }

    func testTheClientWaitsForTheFiles() throws {
        let result = try XCTUnwrap(summary(booking(), as: .client))
        XCTAssertEqual(result.stage, .readyToShare)
        XCTAssertFalse(result.canShare)
        XCTAssertFalse(result.canConfirm)
        XCTAssertEqual(result.headline, "Waiting for your files")
        XCTAssertTrue(result.detail.hasPrefix("Dana Lens will share"), result.detail)
    }

    func testOnceSharedTheClientCanConfirmAndTheCreatorCanReplaceTheLink() throws {
        let shared = booking(shared: true, note: "Password: lake")
        let client = try XCTUnwrap(summary(shared, as: .client))
        XCTAssertEqual(client.stage, .awaitingConfirmation)
        XCTAssertTrue(client.canConfirm)
        XCTAssertFalse(client.canShare)
        XCTAssertEqual(client.link, "https://files.example.com/final")
        XCTAssertEqual(client.note, "Password: lake")
        XCTAssertTrue(client.detail.contains("The remaining $1,500 is due after you confirm."), client.detail)

        let creator = try XCTUnwrap(summary(shared, as: .creator))
        XCTAssertEqual(creator.stage, .awaitingConfirmation)
        XCTAssertTrue(creator.canShare, "Until the client confirms, a wrong link can be fixed")
        XCTAssertFalse(creator.canConfirm)
        XCTAssertTrue(creator.detail.contains("Waiting for Sam Client to confirm"), creator.detail)
    }

    func testAClientWithNothingToPayIsToldSo() throws {
        let result = try XCTUnwrap(summary(booking(deposit: 200_000, shared: true), as: .client))
        XCTAssertTrue(result.detail.contains("Nothing more is due."), result.detail)
    }

    func testOnceConfirmedNeitherSideCanDoAnythingMore() throws {
        let received = booking(shared: true, received: true)
        for viewer in [PaymentSummary.Viewer.client, .creator] {
            let result = try XCTUnwrap(summary(received, as: viewer))
            XCTAssertEqual(result.stage, .received)
            XCTAssertFalse(result.canShare)
            XCTAssertFalse(result.canConfirm)
            XCTAssertEqual(result.tone, .success)
            XCTAssertNotNil(result.receivedAt)
        }
        let creator = try XCTUnwrap(summary(received, as: .creator))
        XCTAssertTrue(creator.detail.contains("They can now pay the remaining $1,500."), creator.detail)
    }

    func testACompletedBookingStillShowsItsDelivery() throws {
        let done = try XCTUnwrap(summary(booking(.completed, shared: true, received: true), as: .creator))
        XCTAssertEqual(done.stage, .received)
        XCTAssertFalse(done.detail.contains("They can now pay"), "Already paid")
    }

    func testAMissingNameFallsBackToPlainWords() throws {
        var unnamed = booking(shared: true)
        unnamed.clientName = "  "
        unnamed.creatorName = ""
        XCTAssertTrue(try XCTUnwrap(summary(unnamed, as: .creator)).detail.contains("Waiting for the client"))
        unnamed.deliveredAt = nil
        unnamed.deliveryURL = nil
        XCTAssertTrue(try XCTUnwrap(summary(unnamed, as: .client)).detail.hasPrefix("Your creator will share"))
    }
}

// MARK: - Reviews

final class ReviewRulesTests: XCTestCase {
    func testRatingsAreOneToFive() {
        for rating in 1...5 { XCTAssertNil(ReviewRules.problem(rating: rating, body: "")) }
        for rating in [0, 6, -1, 100] { XCTAssertEqual(ReviewRules.problem(rating: rating, body: ""), .invalidRating) }
    }

    func testAReviewMayBeEmptyButNotTooLong() {
        XCTAssertNil(ReviewRules.problem(rating: 5, body: "   "))
        XCTAssertNil(ReviewRules.problem(rating: 5, body: String(repeating: "é", count: ReviewRules.maxLength)))
        XCTAssertEqual(ReviewRules.problem(rating: 5, body: String(repeating: "é", count: ReviewRules.maxLength + 1)), .tooLong)
        XCTAssertNil(ReviewRules.problem(rating: 5, body: "  " + String(repeating: "x", count: ReviewRules.maxLength) + "  "), "Counted after tidying")
        XCTAssertEqual(ReviewRules.remaining(in: "  abc  "), ReviewRules.maxLength - 3)
    }

    func testTheBodyIsTidiedLikeAMessage() {
        XCTAssertEqual(ReviewRules.cleanBody("  Great\r\nwork  "), "Great\nwork")
    }

    func testTheSummaryAddsUpAndAverages() {
        XCTAssertNil(ReviewSummary.empty.average)
        XCTAssertEqual(ReviewSummary.empty.accessibilityText, "No reviews yet")
        var summary = ReviewSummary.empty
        for rating in [5, 4, 2] {
            summary = summary.adding(Review(
                id: UUID(), bookingID: nil, creatorID: UUID(), rating: rating, body: "", reviewerName: "A.", packageName: "", createdAt: Date()
            ))
        }
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.ratingSum, 11)
        XCTAssertEqual(try XCTUnwrap(summary.average), 11.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(summary.accessibilityText.hasSuffix("out of 5, from 3 reviews"), summary.accessibilityText)
        XCTAssertTrue(ReviewSummary(count: 1, ratingSum: 5).accessibilityText.hasSuffix("from 1 review"))
    }

    func testAReviewSurvivesSavingAndLoading() throws {
        let review = Review(
            id: UUID(), bookingID: UUID(), creatorID: UUID(), rating: 4, body: "Lovely", reviewerName: "Sam C.",
            packageName: "Portrait session", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Review.self, from: encoder.encode(review)), review)
    }
}

import Foundation

/// Delivering the final files, confirming them, and reviews, for the on-device backend. It follows the SQL in
/// `…_delivery_reviews.sql` rule for rule (same checks, in the same order, with the same errors), and writes the same
/// lines into the conversation that the database's triggers write.
extension LocalBackend {
    // MARK: - Storage

    /// A review with the person who wrote it, which the public shape leaves out.
    struct StoredReview: Codable, Equatable {
        var review: Review
        var reviewerID: UUID?
    }

    private var reviewsURL: URL { root.appendingPathComponent("reviews.json") }

    private func readReviews() -> [StoredReview] {
        read([StoredReview].self, from: reviewsURL) ?? []
    }

    /// Stored dates are whole seconds, so use whole seconds: what this returns then equals what is read back later.
    private var wholeSecondNow: Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    // MARK: - Delivery

    func shareDelivery(bookingID: UUID, link: String, note: String, by creatorID: UUID) async throws -> Booking {
        let now = wholeSecondNow
        var bookings = readBookings()
        guard let index = bookings.firstIndex(where: { $0.id == bookingID }), providerAccess(creatorID, bookings[index], .manage) else {
            throw SlateError.bookingNotFound
        }
        guard bookings[index].canShareDelivery(at: now) else { throw SlateError.notDeliverable }
        guard let cleanLink = DeliveryRules.cleanLink(link) else { throw SlateError.invalidDeliveryLink }
        if DeliveryRules.noteIsTooLong(note) { throw SlateError.deliveryNoteTooLong }

        let revised = bookings[index].deliveryURL != nil
        let linkChanged = bookings[index].deliveryURL != cleanLink
        bookings[index].deliveryURL = cleanLink
        bookings[index].deliveryNote = DeliveryRules.cleanNote(note)
        if bookings[index].deliveredAt == nil { bookings[index].deliveredAt = now }
        try write(bookings, to: bookingsURL)
        // Like the database, say nothing when the same link is shared again.
        if linkChanged {
            try? appendSystemMessage(.deliveryShared, bookingID: bookingID, data: MessageEventData(revised: revised), at: now)
            let client = bookings[index].clientName.isEmpty ? "a client" : bookings[index].clientName
            recordForCompany(bookings[index].creatorID, actor: creatorID, "booking.delivered",
                             "Shared the final files for \(bookings[index].packageName) (\(client))")
        }
        return bookings[index]
    }

    func confirmReceipt(bookingID: UUID, by clientID: UUID) async throws -> Booking {
        let now = wholeSecondNow
        var bookings = readBookings()
        guard let index = bookings.firstIndex(where: { $0.id == bookingID }), bookings[index].clientID == clientID else {
            throw SlateError.bookingNotFound
        }
        // Confirming twice changes nothing.
        if bookings[index].receiptConfirmedAt != nil { return bookings[index] }
        guard bookings[index].status == .confirmed, bookings[index].deliveredAt != nil else { throw SlateError.notDelivered }

        bookings[index].receiptConfirmedAt = now
        // With nothing left to pay, confirming finishes the booking.
        if bookings[index].balanceCents == 0 {
            bookings[index].status = .completed
            recordBookingEvent(bookings[index], "booking.completed", "Completed", actor: nil)
        }
        try write(bookings, to: bookingsURL)
        try? appendSystemMessage(
            .receiptConfirmed, bookingID: bookingID,
            data: MessageEventData(balanceCents: bookings[index].balanceCents, currency: bookings[index].currencyCode), at: now
        )
        return bookings[index]
    }

    // MARK: - Reviews

    func submitReview(bookingID: UUID, rating: Int, body: String, by clientID: UUID) async throws -> Review {
        let now = wholeSecondNow
        guard let booking = readBookings().first(where: { $0.id == bookingID }), booking.clientID == clientID else {
            throw SlateError.bookingNotFound
        }
        guard booking.canReview else { throw SlateError.notReviewable }
        var stored = readReviews()
        if stored.contains(where: { $0.review.bookingID == bookingID }) { throw SlateError.alreadyReviewed }
        guard ReviewRules.ratings.contains(rating) else { throw SlateError.invalidRating }
        let cleaned = ReviewRules.cleanBody(body)
        if MessageRules.length(of: cleaned) > ReviewRules.maxLength { throw SlateError.reviewTooLong }

        let review = Review(
            id: UUID(), bookingID: bookingID, creatorID: booking.creatorID, rating: rating, body: cleaned,
            reviewerName: ReviewRules.displayName(for: booking.clientName), packageName: booking.packageName, createdAt: now
        )
        stored.append(StoredReview(review: review, reviewerID: clientID))
        try write(stored, to: reviewsURL)
        try? appendSystemMessage(.reviewed, bookingID: bookingID, data: MessageEventData(rating: rating), at: now)
        return review
    }

    func loadReview(bookingID: UUID, for userID: UUID) async throws -> Review? {
        // Like the database, a stranger just sees nothing.
        let orgs = readOrganizations()
        guard readBookings().contains(where: { $0.id == bookingID && isParty(userID, $0, .view, in: orgs) }) else { return nil }
        return readReviews().first { $0.review.bookingID == bookingID }?.review
    }

    func loadReviews(creatorID: UUID, limit: Int, before: Date?) async throws -> [Review] {
        // Newest first; reviews written in the same second keep the order they were written in, newest first.
        var mine: [(order: Int, review: Review)] = []
        for (order, stored) in readReviews().enumerated() where stored.review.creatorID == creatorID {
            if let before, stored.review.createdAt >= before { continue }
            mine.append((order, stored.review))
        }
        mine.sort { ($0.review.createdAt, $0.order) > ($1.review.createdAt, $1.order) }
        return mine.prefix(max(1, min(limit, 50))).map { entry in
            // The public list carries no booking.
            var review = entry.review
            review.bookingID = nil
            return review
        }
    }

    func loadReviewSummary(creatorID: UUID) async throws -> ReviewSummary {
        let mine = readReviews().map(\.review).filter { $0.creatorID == creatorID }
        return ReviewSummary(count: mine.count, ratingSum: mine.reduce(0) { $0 + $1.rating })
    }
}

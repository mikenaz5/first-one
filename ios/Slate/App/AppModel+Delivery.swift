import Foundation

/// Delivering the final files, confirming them, and reviews.
extension AppModel {
    // MARK: - What to show

    /// A booking's delivery as the signed-in person should see it. Whoever booked is the client, even when they are
    /// testing their own package on-device.
    func deliverySummary(for booking: Booking, now: Date) -> DeliverySummary? {
        DeliverySummary.make(booking: booking, viewer: booking.clientID == session?.userID ? .client : .creator, now: now)
    }

    /// What the signed-in person has to do about their bookings right now.
    var attentionItems: [AttentionItem] {
        guard let session else { return [] }
        return AttentionList.make(bookings: visibleBookings, userID: session.userID, now: clock())
    }

    func review(for booking: Booking) -> Review? { reviewsByBooking[booking.id] }

    /// Whether the signed-in person can still leave a review on this booking.
    func canReview(_ booking: Booking) -> Bool {
        booking.clientID == session?.userID && booking.canReview && reviewsByBooking[booking.id] == nil
    }

    func reviews(for creatorID: UUID) -> [Review] { reviewsByCreator[creatorID] ?? [] }

    func reviewSummary(for creatorID: UUID) -> ReviewSummary { reviewSummaryByCreator[creatorID] ?? .empty }

    // MARK: - Delivering

    /// Shares (or replaces) the link to the final files. Returns whether it worked; if not, the reason is shown.
    @discardableResult
    func shareDelivery(_ booking: Booking, link: String, note: String) async -> Bool {
        guard let session else { return false }
        do {
            let updated = try await backend.shareDelivery(bookingID: booking.id, link: link, note: note, by: session.userID)
            apply(updated)
            return true
        } catch {
            show(error, title: "Couldn't share the files")
            return false
        }
    }

    /// The client says they have the files. Returns whether it worked; if not, the reason is shown.
    @discardableResult
    func confirmReceipt(_ booking: Booking) async -> Bool {
        guard let session else { return false }
        do {
            let updated = try await backend.confirmReceipt(bookingID: booking.id, by: session.userID)
            apply(updated)
            return true
        } catch {
            show(error, title: "Couldn't confirm")
            return false
        }
    }

    private func apply(_ updated: Booking) {
        if let index = bookings.firstIndex(where: { $0.id == updated.id }) { bookings[index] = updated }
        bookingsChanged()
    }

    // MARK: - Reviews

    /// Fetches the review on a booking, if there is one.
    func loadReview(for booking: Booking) async {
        guard let session, booking.status == .completed else { return }
        if let review = try? await backend.loadReview(bookingID: booking.id, for: session.userID) {
            reviewsByBooking[booking.id] = review
        }
    }

    /// Leaves the review. Returns whether it worked; if not, the reason is shown.
    @discardableResult
    func submitReview(for booking: Booking, rating: Int, body: String) async -> Bool {
        guard let session else { return false }
        do {
            let review = try await backend.submitReview(bookingID: booking.id, rating: rating, body: body, by: session.userID)
            reviewsByBooking[booking.id] = review
            reviewsByCreator[booking.creatorID] = nil
            reviewSummaryByCreator[booking.creatorID] = nil
            return true
        } catch {
            show(error, title: "Couldn't post your review")
            // Someone may already have left one (another device): show it rather than asking again.
            if let slateError = error as? SlateError, slateError == SlateError.alreadyReviewed { await loadReview(for: booking) }
            return false
        }
    }

    /// Fetches a creator's newest reviews and their summary, for a page.
    func loadReviews(for creatorID: UUID) async {
        if let list = try? await backend.loadReviews(creatorID: creatorID, limit: AppConfig.reviewsPageSize, before: nil) {
            reviewsByCreator[creatorID] = list
        }
        if let summary = try? await backend.loadReviewSummary(creatorID: creatorID) {
            reviewSummaryByCreator[creatorID] = summary
        }
    }

    /// The next page of a creator's reviews, older than those already shown.
    func loadMoreReviews(for creatorID: UUID) async {
        guard let last = reviewsByCreator[creatorID]?.last else { return }
        guard let older = try? await backend.loadReviews(creatorID: creatorID, limit: AppConfig.reviewsPageSize, before: last.createdAt) else { return }
        let known = Set((reviewsByCreator[creatorID] ?? []).map(\.id))
        reviewsByCreator[creatorID, default: []] += older.filter { !known.contains($0.id) }
    }
}

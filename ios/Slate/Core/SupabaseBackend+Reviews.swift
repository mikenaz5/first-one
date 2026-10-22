import Foundation
import Supabase

/// Reviews on Supabase.
///
/// The `reviews` table is closed to the API; everything goes through the functions in `…_delivery_reviews.sql`:
/// `submit_review` (the client of a completed booking, once), `get_booking_review` (the two people on the booking), and
/// the public `list_reviews` and `creator_review_summary` for creator pages. Sharing the files and confirming receipt are
/// in `SupabaseBackend+Scheduling.swift`, because they return the booking.
extension SupabaseBackend {
    private struct ReviewRow: Decodable {
        var id: String
        var bookingId: String?
        var creatorId: String
        var rating: Int
        var body: String
        var reviewerName: String
        var packageName: String
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, rating, body
            case bookingId = "booking_id"
            case creatorId = "creator_id"
            case reviewerName = "reviewer_name"
            case packageName = "package_name"
            case createdAt = "created_at"
        }

        func review() throws -> Review {
            guard let id = UUID(uuidString: id), let creatorID = UUID(uuidString: creatorId) else {
                throw SlateError.backend("Malformed review id.")
            }
            return Review(
                id: id, bookingID: bookingId.flatMap(UUID.init(uuidString:)), creatorID: creatorID, rating: rating, body: body,
                reviewerName: reviewerName, packageName: packageName, createdAt: createdAt
            )
        }
    }

    private struct SummaryRow: Decodable {
        var reviewCount: Int
        var ratingSum: Int

        enum CodingKeys: String, CodingKey {
            case reviewCount = "review_count"
            case ratingSum = "rating_sum"
        }
    }

    private struct SubmitReviewParams: Encodable {
        var pBookingId: String
        var pRating: Int
        var pBody: String

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pRating = "p_rating"
            case pBody = "p_body"
        }
    }

    private struct BookingReviewParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct ListReviewsParams: Encodable {
        var pCreatorId: String
        var pLimit: Int
        var pBefore: Date?

        enum CodingKeys: String, CodingKey {
            case pCreatorId = "p_creator_id"
            case pLimit = "p_limit"
            case pBefore = "p_before"
        }
    }

    private struct SummaryParams: Encodable {
        var pCreatorId: String

        enum CodingKeys: String, CodingKey { case pCreatorId = "p_creator_id" }
    }

    func submitReview(bookingID: UUID, rating: Int, body: String, by clientID: UUID) async throws -> Review {
        do {
            let row: ReviewRow = try await client
                .rpc("submit_review", params: SubmitReviewParams(pBookingId: Self.key(bookingID), pRating: rating, pBody: body))
                .execute()
                .value
            return try row.review()
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func loadReview(bookingID: UUID, for userID: UUID) async throws -> Review? {
        let rows: [ReviewRow] = try await client
            .rpc("get_booking_review", params: BookingReviewParams(pBookingId: Self.key(bookingID)))
            .execute()
            .value
        return try rows.first?.review()
    }

    func loadReviews(creatorID: UUID, limit: Int, before: Date?) async throws -> [Review] {
        let rows: [ReviewRow] = try await client
            .rpc("list_reviews", params: ListReviewsParams(pCreatorId: Self.key(creatorID), pLimit: limit, pBefore: before))
            .execute()
            .value
        return try rows.map { try $0.review() }
    }

    func loadReviewSummary(creatorID: UUID) async throws -> ReviewSummary {
        let rows: [SummaryRow] = try await client
            .rpc("creator_review_summary", params: SummaryParams(pCreatorId: Self.key(creatorID)))
            .execute()
            .value
        return rows.first.map { ReviewSummary(count: $0.reviewCount, ratingSum: $0.ratingSum) } ?? .empty
    }
}

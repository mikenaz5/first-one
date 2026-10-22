import Foundation

// MARK: - Reviews

/// What a client wrote about a finished booking. One per booking, left once the work is delivered, confirmed and paid.
struct Review: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// Nil in a creator's public list, which carries no booking details.
    var bookingID: UUID?
    var creatorID: UUID
    /// 1 to 5.
    var rating: Int
    var body: String
    /// "Alex R.": worked out when the review is written, so a public page never shows a full name.
    var reviewerName: String
    var packageName: String
    var createdAt: Date
}

/// How a creator's reviews add up.
struct ReviewSummary: Equatable, Codable {
    var count: Int
    var ratingSum: Int

    static let empty = ReviewSummary(count: 0, ratingSum: 0)

    /// Nil until there is a review to average.
    var average: Double? { count > 0 ? Double(ratingSum) / Double(count) : nil }

    func adding(_ review: Review) -> ReviewSummary {
        ReviewSummary(count: count + 1, ratingSum: ratingSum + review.rating)
    }

    /// "4.8 out of 5, from 12 reviews", for VoiceOver.
    var accessibilityText: String {
        guard let average else { return "No reviews yet" }
        let rounded = average.formatted(.number.precision(.fractionLength(1)))
        return "\(rounded) out of 5, from \(count) \(count == 1 ? "review" : "reviews")"
    }
}

// MARK: - Rules

/// What a review may be. Mirrors `submit_review()` and `review_display_name()` in SQL; `delivery_rules.json` is
/// checked by both test suites.
enum ReviewRules {
    static let maxLength = 1000
    static let ratings = 1...5

    enum Problem: Equatable {
        case invalidRating, tooLong
    }

    private static let separators: Set<Unicode.Scalar> = [" ", "\n", "\t", "\r"]

    /// The text as it will be stored: tidied like a message, and possibly empty (a rating alone is a review).
    static func cleanBody(_ text: String) -> String { MessageRules.clean(text) }

    static func problem(rating: Int, body: String) -> Problem? {
        guard ratings.contains(rating) else { return .invalidRating }
        return MessageRules.length(of: cleanBody(body)) > maxLength ? .tooLong : nil
    }

    /// Characters left before the limit, once the text is tidied.
    static func remaining(in text: String) -> Int {
        maxLength - MessageRules.length(of: cleanBody(text))
    }

    /// How a reviewer is named on a public page: "Alex Rivera" shows as "Alex R.". Words are split on spaces, tabs
    /// and line breaks; the initial is the first Unicode scalar of the last word (as in SQL).
    static func displayName(for fullName: String) -> String {
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in fullName.unicodeScalars {
            if separators.contains(scalar) {
                if !current.isEmpty { words.append(current) }
                current = []
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }

        guard let first = words.first else { return "Client" }
        guard words.count > 1, let last = words.last, let initial = last.first else { return text(first) }
        return "\(text(first)) \(text([initial]))."
    }

    private static func text(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

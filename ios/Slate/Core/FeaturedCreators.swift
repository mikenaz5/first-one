import Foundation

/// One tile of the explore grid on a client's Home: a creator a client could book, with something to look at.
struct FeaturedCreator: Identifiable, Equatable {
    var profile: CreatorProfile
    /// The first piece of their portfolio (a photo, or a video's poster frame). Nil when they haven't added any.
    var coverURL: URL?
    /// The lowest price among their published packages.
    var startingPriceCents: Int
    var currencyCode: String
    var reviews: ReviewSummary
    /// How far they are from the client's place, when the client has chosen one and the creator has a city.
    var distanceKm: Double? = nil

    var id: UUID { profile.id }
}

extension FeaturedCreator {
    /// "From $350".
    var priceText: String { "From \(Money.format(startingPriceCents, code: currencyCode))" }

    /// What they shoot and where, on one line: "Weddings · Portraits · Austin, TX".
    var detail: String {
        var parts = profile.specialties.prefix(2).map(\.title)
        if let place = profile.location?.name, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    /// "4 mi", when the client has a place and the creator a city.
    var distanceText: String? { distanceKm.map { GeoRules.distanceText(km: $0) } }

    /// Whether the client is inside the area they travel to.
    var travelsToClient: Bool {
        FeaturedRules.serves(distanceKm: distanceKm, travelRadiusKm: profile.location?.travelRadiusKm)
    }

    /// The whole tile in one sentence, for VoiceOver.
    var accessibilitySummary: String {
        var parts = [profile.displayName]
        if !detail.isEmpty { parts.append(detail) }
        if let distanceText { parts.append("\(distanceText) away") }
        parts.append(reviews.accessibilityText)
        parts.append(priceText)
        return parts.joined(separator: ". ")
    }
}

/// What the order of the featured creators depends on. The database and the app both work it out from these.
struct FeaturedRanking: Equatable {
    var id: UUID
    var portfolioCount: Int
    var reviewCount: Int
    var ratingSum: Int
    var createdAt: Date
    /// From the client's place to the creator's city. Nil when the client has no place or the creator no city.
    var distanceKm: Double? = nil
    /// How far the creator travels. Nil when they have no city.
    var travelRadiusKm: Int? = nil
}

/// Which creators a client sees under the search box on Home, and in what order. Not paid placement and not
/// hand-picked: the same for everyone. Keep this in step with `featured_creators()` in the database;
/// `SlateTests/Fixtures/featured_rules.json` is checked by both.
///
/// Candidates are creators a client could book (a published package). In order:
///  1. when the client has chosen a place, creators who work there come first: the client is inside the area they
///     travel to (distance from the client to their city is no more than their travel radius). With no place, nobody
///     does, and this changes nothing;
///  2. those with work to look at (a portfolio piece) before those without;
///  3. a smoothed average rating, best first: (stars + 12) / (reviews + 3), as if every creator began with three
///     four-star reviews, so one five-star review doesn't outrank fifty good ones and a creator with no reviews yet
///     isn't buried;
///  4. more reviews, 5. more portfolio pieces;
///  6. nearer first (a creator with no city last), 7. newest, then by id so the order never shuffles.
enum FeaturedRules {
    static let defaultLimit = 12
    static let maxLimit = 24
    /// The made-up starting record: three reviews worth twelve stars.
    static let priorStars = 12
    static let priorReviews = 3

    static func clamped(limit: Int) -> Int { min(max(limit, 1), maxLimit) }

    /// Whether a creator works where the client is. A creator whose profile has no travel radius counts as the
    /// standard one, as in the database.
    static func serves(distanceKm: Double?, travelRadiusKm: Int?) -> Bool {
        guard let distanceKm else { return false }
        return distanceKm <= Double(travelRadiusKm ?? TravelRadius.defaultKm)
    }

    /// Whether `a` is shown before `b`. A strict ordering, so it can sort.
    static func precedes(_ a: FeaturedRanking, _ b: FeaturedRanking) -> Bool {
        let aServes = serves(distanceKm: a.distanceKm, travelRadiusKm: a.travelRadiusKm)
        if aServes != serves(distanceKm: b.distanceKm, travelRadiusKm: b.travelRadiusKm) { return aServes }
        let aHasWork = a.portfolioCount > 0
        if aHasWork != (b.portfolioCount > 0) { return aHasWork }
        // (a.stars + 12) / (a.reviews + 3) against the same for b, multiplied out so equal averages are exactly equal.
        let left = (a.ratingSum + priorStars) * (b.reviewCount + priorReviews)
        let right = (b.ratingSum + priorStars) * (a.reviewCount + priorReviews)
        if left != right { return left > right }
        if a.reviewCount != b.reviewCount { return a.reviewCount > b.reviewCount }
        if a.portfolioCount != b.portfolioCount { return a.portfolioCount > b.portfolioCount }
        switch (a.distanceKm, b.distanceKm) {
        case let (near?, far?) where near != far: return near < far
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    static func order<T>(_ items: [T], ranking: (T) -> FeaturedRanking) -> [T] {
        items.sorted { precedes(ranking($0), ranking($1)) }
    }
}

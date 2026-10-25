import Foundation

extension LocalBackend {
    /// Creators a client could book, best first (see `FeaturedRules`), each with a cover, a starting price and reviews.
    func featuredCreators(specialty: Specialty?, limit: Int) async throws -> [FeaturedCreator] {
        await seedSampleCreatorsIfNeeded()
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var candidates: [(creator: FeaturedCreator, ranking: FeaturedRanking)] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let profile = try await loadProfile(for: id),
                  specialty.map({ profile.specialties.contains($0) }) ?? true else { continue }
            // Someone a client could book: at least one published package. The cheapest one sets "From".
            let published = try await loadPackages(for: id).filter(\.isPublished)
            guard let cheapest = published.min(by: { ($0.priceCents, $0.position) < ($1.priceCents, $1.position) }) else { continue }
            let pieces = try await loadPortfolio(for: id)
            let reviews = try await loadReviewSummary(creatorID: id)
            let creator = FeaturedCreator(
                profile: profile, coverURL: pieces.first?.thumbnailURL, startingPriceCents: cheapest.priceCents,
                currencyCode: cheapest.currencyCode, reviews: reviews
            )
            let ranking = FeaturedRanking(
                id: id, portfolioCount: pieces.count, reviewCount: reviews.count, ratingSum: reviews.ratingSum,
                createdAt: profile.createdAt
            )
            candidates.append((creator, ranking))
        }
        let ordered = FeaturedRules.order(candidates) { $0.ranking }
        return ordered.prefix(FeaturedRules.clamped(limit: limit)).map { $0.creator }
    }
}

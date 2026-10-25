import XCTest
@testable import Slate

// MARK: - The shared fixture

/// `Fixtures/featured_rules.json`, which `supabase/tests/featured_rules.py` reads too: the same creators, and the
/// order the database and the app must both put them in.
private struct FeaturedFixture: Decodable {
    struct Offer: Decodable {
        var cents: Int
        var published: Bool
    }

    struct Place: Decodable {
        var name: String
        var lat: Double
        var lon: Double
        var radiusKm: Int

        var point: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
    }

    struct Client: Decodable {
        var name: String
        var lat: Double
        var lon: Double
        /// What the database must put first to last for a client here.
        var order: [String]
        /// Kilometres from here to each creator who has a city.
        var km: [String: Double]

        var point: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
    }

    struct Distance: Decodable {
        struct End: Decodable {
            var lat: Double
            var lon: Double
        }

        var from: End
        var to: End
        var km: Double
    }

    struct Creator: Decodable {
        var id: UUID
        var handle: String
        var portfolio: Int
        var ratings: [Int]
        var created: String
        var specialties: [String]
        var packages: [Offer]
        var place: Place?

        var createdAt: Date {
            ISO8601DateFormatter().date(from: "\(created)T12:00:00Z") ?? .distantPast
        }

        var published: [Offer] { packages.filter(\.published) }
    }

    struct LimitCase: Decodable {
        var asked: Int
        var clamped: Int
    }

    var defaultLimit: Int
    var maxLimit: Int
    var defaultTravelRadiusKm: Int
    var rowColumns: [String]
    var limits: [LimitCase]
    var creators: [Creator]
    var order: [String]
    var bySpecialty: [String: [String]]
    var clients: [Client]
    var distances: [Distance]

    static func load() throws -> FeaturedFixture {
        let url = try XCTUnwrap(
            Bundle(for: FeaturedRulesTests.self).url(forResource: "featured_rules", withExtension: "json"),
            "featured_rules.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(FeaturedFixture.self, from: Data(contentsOf: url))
    }

    /// What a creator's place in the order depends on, for a client at `client` (nil: no place chosen).
    func ranking(_ creator: Creator, from client: GeoPoint? = nil) -> FeaturedRanking {
        let distance: Double? = {
            guard let client, let place = creator.place else { return nil }
            return GeoRules.distanceKm(from: client, to: place.point)
        }()
        return FeaturedRanking(
            id: creator.id, portfolioCount: creator.portfolio, reviewCount: creator.ratings.count,
            ratingSum: creator.ratings.reduce(0, +), createdAt: creator.createdAt,
            distanceKm: distance, travelRadiusKm: creator.place?.radiusKm
        )
    }

    func handle(of id: UUID) -> String { creators.first { $0.id == id }?.handle ?? "?" }
}

// MARK: - The rules

final class FeaturedRulesTests: XCTestCase {
    func testTheLimitsMatchTheDatabase() throws {
        let fixture = try FeaturedFixture.load()
        XCTAssertEqual(FeaturedRules.defaultLimit, fixture.defaultLimit)
        XCTAssertEqual(FeaturedRules.maxLimit, fixture.maxLimit)
        for example in fixture.limits {
            XCTAssertEqual(FeaturedRules.clamped(limit: example.asked), example.clamped, "asking for \(example.asked)")
        }
    }

    func testTheOrderMatchesTheDatabaseOnEverySharedCase() throws {
        let fixture = try FeaturedFixture.load()
        let rankings = fixture.creators.map { fixture.ranking($0) }
        let forwards = FeaturedRules.order(rankings) { $0 }.map { fixture.handle(of: $0.id) }
        let backwards = FeaturedRules.order(Array(rankings.reversed())) { $0 }.map { fixture.handle(of: $0.id) }
        XCTAssertEqual(forwards, fixture.order)
        XCTAssertEqual(backwards, fixture.order, "The order doesn't depend on the order they arrive in")
    }

    func testTheOrderForAClientAtAPlaceMatchesTheDatabase() throws {
        let fixture = try FeaturedFixture.load()
        XCTAssertGreaterThanOrEqual(fixture.clients.count, 3)
        for client in fixture.clients {
            let rankings = fixture.creators.map { fixture.ranking($0, from: client.point) }
            let forwards = FeaturedRules.order(rankings) { $0 }.map { fixture.handle(of: $0.id) }
            let backwards = FeaturedRules.order(Array(rankings.reversed())) { $0 }.map { fixture.handle(of: $0.id) }
            XCTAssertEqual(forwards, client.order, client.name)
            XCTAssertEqual(backwards, client.order, "\(client.name): the arrival order doesn't matter")
        }
    }

    func testDistancesMatchTheDatabaseToWithinAHundredMetres() throws {
        let fixture = try FeaturedFixture.load()
        for case_ in fixture.distances {
            let km = GeoRules.distanceKm(
                from: GeoPoint(latitude: case_.from.lat, longitude: case_.from.lon),
                to: GeoPoint(latitude: case_.to.lat, longitude: case_.to.lon)
            )
            XCTAssertEqual(km, case_.km, accuracy: 0.1, "\(case_.from) to \(case_.to)")
        }
        for client in fixture.clients {
            for creator in fixture.creators {
                guard let place = creator.place, let expected = client.km[creator.handle] else { continue }
                XCTAssertEqual(GeoRules.distanceKm(from: client.point, to: place.point), expected, accuracy: 0.1, "\(client.name) to \(creator.handle)")
            }
        }
    }

    func testTheDefaultTravelRadiusMatchesTheDatabase() throws {
        XCTAssertEqual(try FeaturedFixture.load().defaultTravelRadiusKm, TravelRadius.defaultKm)
    }

    func testWorkingWhereTheClientIsComesBeforeBetterReviews() {
        var near = ranking(reviews: [])
        near.distanceKm = 20
        near.travelRadiusKm = 40
        var far = ranking(reviews: [5, 5, 5, 5, 5])
        far.distanceKm = 55
        far.travelRadiusKm = 40
        XCTAssertTrue(FeaturedRules.precedes(near, far), "Inside their radius beats outside it")
        far.travelRadiusKm = 60
        XCTAssertTrue(FeaturedRules.precedes(far, near), "A wider radius reaches the client too, so the reviews decide")
        near.travelRadiusKm = nil
        far.travelRadiusKm = nil
        far.distanceKm = 41
        XCTAssertTrue(FeaturedRules.precedes(near, far), "No radius counts as the standard 40 km")
    }

    func testWithNoPlaceNoOneWorksThereAndNothingChanges() {
        var a = ranking(reviews: [5, 5], day: 0)
        var b = ranking(reviews: [4], day: 1)
        XCTAssertTrue(FeaturedRules.precedes(a, b))
        a.travelRadiusKm = 500
        b.travelRadiusKm = 500
        XCTAssertTrue(FeaturedRules.precedes(a, b), "A radius means nothing without a distance")
        XCTAssertFalse(FeaturedRules.serves(distanceKm: nil, travelRadiusKm: 500))
    }

    func testNearerComesFirstWhenEverythingElseIsTheSame() {
        var a = ranking(reviews: [], day: 0)
        var b = ranking(reviews: [], day: 5)
        a.distanceKm = 300
        b.distanceKm = 900
        XCTAssertTrue(FeaturedRules.precedes(a, b), "Nearer beats newer")
        b.distanceKm = nil
        XCTAssertTrue(FeaturedRules.precedes(a, b), "A creator with no city comes last")
        a.distanceKm = nil
        XCTAssertTrue(FeaturedRules.precedes(b, a), "With neither, newer first")
    }

    private func ranking(reviews ratings: [Int], pieces: Int = 1, day: Double = 0) -> FeaturedRanking {
        FeaturedRanking(
            id: UUID(), portfolioCount: pieces, reviewCount: ratings.count, ratingSum: ratings.reduce(0, +),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400)
        )
    }

    func testWorkToShowComesBeforeAnythingElse() {
        let showsWork = ranking(reviews: [], pieces: 1)
        let noWork = ranking(reviews: Array(repeating: 5, count: 40), pieces: 0)
        XCTAssertTrue(FeaturedRules.precedes(showsWork, noWork))
        XCTAssertFalse(FeaturedRules.precedes(noWork, showsWork))
    }

    func testOneFiveStarReviewDoesNotBeatFiftyGoodOnes() {
        let one = ranking(reviews: [5])
        let fifty = ranking(reviews: Array(repeating: 5, count: 49) + [4])
        XCTAssertTrue(FeaturedRules.precedes(fifty, one))
    }

    func testANewCreatorIsLevelWithAnAverageOneNotBelowThem() {
        let brandNew = ranking(reviews: [])
        let average = ranking(reviews: Array(repeating: 4, count: 10))
        // Same smoothed score, so the one with more reviews goes first, but neither is buried.
        XCTAssertTrue(FeaturedRules.precedes(average, brandNew))
        let poor = ranking(reviews: [2, 2, 3])
        XCTAssertTrue(FeaturedRules.precedes(brandNew, poor))
    }

    func testNothingTiesForever() {
        let a = ranking(reviews: [], day: 0)
        var b = a
        b.id = UUID()
        XCTAssertNotEqual(FeaturedRules.precedes(a, b), FeaturedRules.precedes(b, a), "Exactly one comes first")
        XCTAssertFalse(FeaturedRules.precedes(a, a))
        let newer = ranking(reviews: [], day: 1)
        XCTAssertTrue(FeaturedRules.precedes(newer, a))
    }
}

// MARK: - The on-device backend

final class FeaturedBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-featured-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Makes a creator the way the screens would, and returns their id.
    @discardableResult
    private func make(
        _ handle: String, specialties: [String] = [], created: Date = Date(), packages: [(cents: Int, published: Bool)],
        pieces: Int = 0, ratings: [Int] = [], place: FeaturedFixture.Place? = nil
    ) async throws -> UUID {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        let id = session.userID
        _ = try await backend.saveProfile(CreatorProfile(
            id: id, handle: handle, displayName: handle, bio: "", specialties: specialties.compactMap(Specialty.init(rawValue:)),
            location: place.map { CreatorLocation(name: $0.name, latitude: $0.lat, longitude: $0.lon, travelRadiusKm: $0.radiusKm) },
            avatarURL: nil, createdAt: created, updatedAt: created
        ), avatarJPEG: nil)
        let template = try await ContractFixtures.equip(backend, creatorID: id, signature: ContractFixtures.creatorSignature(name: handle))
        for (position, offer) in packages.enumerated() {
            _ = try await backend.savePackage(ServicePackage(
                id: UUID(), creatorID: id, name: "Package \(position + 1)", summary: "", category: nil,
                priceCents: offer.cents, currencyCode: "USD", durationMinutes: 60, deliverables: [], turnaroundDays: 7,
                depositCents: 0, addOns: [], isPublished: offer.published, position: position, createdAt: Date(), updatedAt: Date(),
                contractTemplateID: template.id, cancellationPolicy: .flexible, usageRights: .personal
            ))
        }
        if pieces > 0 {
            let items = (0..<pieces).map { _ in
                NewPortfolioItem(kind: .photo, imageJPEG: Data([0xFF, 0xD8]), thumbnailJPEG: Data([0xFF, 0xD8]), videoFile: nil, duration: nil, aspectRatio: 1)
            }
            _ = try await backend.addPortfolioItems(items, for: id)
        }
        let reviews = ratings.enumerated().map { position, rating in
            Review(
                id: UUID(), bookingID: nil, creatorID: id, rating: rating, body: "", reviewerName: "Alex R.",
                packageName: "Package 1", createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(position))
            )
        }
        try await backend.storeSampleReviews(reviews)
        return id
    }

    private func buildFixture() async throws -> FeaturedFixture {
        let fixture = try FeaturedFixture.load()
        for creator in fixture.creators {
            try await make(
                creator.handle, specialties: creator.specialties, created: creator.createdAt,
                packages: creator.packages.map { (cents: $0.cents, published: $0.published) }, pieces: creator.portfolio, ratings: creator.ratings,
                place: creator.place
            )
        }
        // Never shown, however good they look: nothing a client could book.
        try await make("draft-only", specialties: ["weddings"], packages: [(50_000, false)], pieces: 9, ratings: Array(repeating: 5, count: 30))
        try await make("no-packages", specialties: ["weddings"], packages: [], pieces: 9, ratings: Array(repeating: 5, count: 30))
        return fixture
    }

    /// The two creators that tie on everything are ordered by id, which a device picks at random: count them as one.
    private func settled(_ handles: [String]) -> [String] {
        handles.map { $0 == "tie-second" ? "tie-first" : $0 }
    }

    private func handles(_ specialty: Specialty? = nil, near: GeoPoint? = nil, limit: Int = 24) async throws -> [String] {
        try await backend.featuredCreators(specialty: specialty, near: near, limit: limit).map(\.profile.handle)
    }

    func testCreatorsComeInTheSharedOrderAndOnlyThoseAClientCouldBook() async throws {
        let fixture = try await buildFixture()
        let found = try await handles()
        XCTAssertEqual(settled(found), settled(fixture.order))
        XCTAssertFalse(found.contains("draft-only"))
        XCTAssertFalse(found.contains("no-packages"))
    }

    func testEachSpecialtyShowsOnlyThoseWhoShootIt() async throws {
        let fixture = try await buildFixture()
        for (raw, expected) in fixture.bySpecialty {
            let specialty = try XCTUnwrap(Specialty(rawValue: raw))
            let found = try await handles(specialty)
            XCTAssertEqual(settled(found), settled(expected), raw)
        }
    }

    func testATileCarriesTheCoverTheLowestPublishedPriceAndTheReviews() async throws {
        let fixture = try await buildFixture()
        let tiles = try await backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        for creator in fixture.creators {
            let tile = try XCTUnwrap(tiles.first { $0.profile.handle == creator.handle }, creator.handle)
            XCTAssertEqual(tile.startingPriceCents, creator.published.map(\.cents).min(), "\(creator.handle): lowest published price")
            XCTAssertEqual(tile.reviews, ReviewSummary(count: creator.ratings.count, ratingSum: creator.ratings.reduce(0, +)), creator.handle)
            XCTAssertEqual(tile.coverURL != nil, creator.portfolio > 0, "\(creator.handle): a cover only when there is work")
            XCTAssertEqual(tile.currencyCode, "USD")
        }
    }

    func testTheLimitIsKeptBetweenOneAndTwentyFour() async throws {
        let fixture = try await buildFixture()
        let all = try await handles()
        let three = try await handles(limit: 3)
        let none = try await handles(limit: 0)
        let huge = try await handles(limit: 500)
        XCTAssertEqual(three, Array(all.prefix(3)), "The best come first when the list is cut short")
        XCTAssertEqual(none.count, 1, "At least one")
        XCTAssertEqual(huge.count, fixture.order.count, "Never more than there are, nor more than 24")
        XCTAssertLessThanOrEqual(huge.count, FeaturedRules.maxLimit)
    }

    func testCreatorsWhoWorkWhereTheClientIsComeFirstInTheSharedOrder() async throws {
        let fixture = try await buildFixture()
        for client in fixture.clients {
            let found = try await handles(near: client.point)
            XCTAssertEqual(settled(found), settled(client.order), client.name)
            XCTAssertFalse(found.contains("draft-only"), client.name)
        }
    }

    func testEachTileKnowsHowFarAwayItIs() async throws {
        let fixture = try await buildFixture()
        let client = try XCTUnwrap(fixture.clients.first { $0.name == "austin" })
        let tiles = try await backend.featuredCreators(specialty: nil, near: client.point, limit: 24)
        for creator in fixture.creators {
            let tile = try XCTUnwrap(tiles.first { $0.profile.handle == creator.handle }, creator.handle)
            if let expected = client.km[creator.handle] {
                XCTAssertEqual(try XCTUnwrap(tile.distanceKm, creator.handle), expected, accuracy: 0.1, creator.handle)
            } else {
                XCTAssertNil(tile.distanceKm, "\(creator.handle) has no city, so no distance")
            }
        }
        let first = try XCTUnwrap(tiles.first)
        XCTAssertTrue(first.travelsToClient, "The first one works where the client is")
        XCTAssertNotNil(first.distanceText)
        // Without a place there is nothing to measure from.
        let anywhere = try await backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        XCTAssertTrue(anywhere.allSatisfy { $0.distanceKm == nil && !$0.travelsToClient })
    }

    func testAPlaceThatIsNotOnEarthCountsAsNone() async throws {
        let fixture = try await buildFixture()
        let usual = try await handles()
        let nowhere = try await handles(near: GeoPoint(latitude: 95, longitude: 10))
        XCTAssertEqual(nowhere, usual)
        XCTAssertEqual(usual.count, fixture.order.count)
    }

    func testNobodyIsShownWhenNobodyCanBeBooked() async throws {
        let found = try await handles()
        XCTAssertTrue(found.isEmpty)
        let none = try await handles(.aerial)
        XCTAssertTrue(none.isEmpty)
    }

    func testAnUnpublishedPackageDoesNotSetThePrice() async throws {
        try await make("mixed", specialties: ["food"], packages: [(10_000, false), (60_000, true), (90_000, true)], pieces: 1)
        let tiles = try await backend.featuredCreators(specialty: nil, near: nil, limit: 5)
        let tile = try XCTUnwrap(tiles.first)
        XCTAssertEqual(tile.startingPriceCents, 60_000)
    }
}

// MARK: - The sample creators the app starts with

final class SampleCreatorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-samples-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAFreshAppStartsWithEightCreatorsEachWithAPictureAPriceAndReviews() async throws {
        let backend = LocalBackend(root: root, offersSampleCreators: true)
        let tiles = try await backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        XCTAssertEqual(tiles.count, SampleCreator.all.count)
        XCTAssertEqual(tiles.count, 8)
        for tile in tiles {
            XCTAssertGreaterThan(tile.startingPriceCents, 0, tile.profile.displayName)
            let cover = try XCTUnwrap(tile.coverURL, "\(tile.profile.displayName) has a cover")
            let data = try Data(contentsOf: cover)
            XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "The cover is a real JPEG")
            XCTAssertGreaterThan(data.count, 500)
        }
        XCTAssertEqual(tiles.filter { $0.reviews.count == 0 }.count, 1, "One is new, with no reviews yet")
        XCTAssertEqual(tiles.first?.profile.handle, "lena-ortiz", "The best reviewed comes first")
        XCTAssertEqual(tiles.last?.profile.handle, "ivy-park", "The one with no reviews comes last")
    }

    func testTheyAreMadeOnceEvenWhenTwoScreensAskAtTheSameTime() async throws {
        let backend = LocalBackend(root: root, offersSampleCreators: true)
        async let first = backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        async let second = backend.searchCreators("wedding", limit: 20)
        let (tiles, found) = try await (first, second)
        XCTAssertEqual(tiles.count, 8)
        XCTAssertEqual(Set(found.map(\.handle)), ["lena-ortiz", "tomas-and-co"])
        let again = try await backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        XCTAssertEqual(again.count, 8, "Asking again doesn't make more")
        // A new backend on the same files finds them already there.
        let reopened = LocalBackend(root: root, offersSampleCreators: true)
        let after = try await reopened.featuredCreators(specialty: nil, near: nil, limit: 24)
        XCTAssertEqual(after.count, 8)
    }

    func testTheyHaveWhatABookingNeeds() async throws {
        let backend = LocalBackend(root: root, offersSampleCreators: true)
        _ = try await backend.featuredCreators(specialty: nil, near: nil, limit: 1)
        let found = try await backend.loadPublicPage(handle: "dana-lens")
        let page = try XCTUnwrap(found)
        XCTAssertEqual(page.packages.count, 1)
        let package = try XCTUnwrap(page.packages.first)
        XCTAssertNotNil(package.contractTemplateID, "A contract to sign")
        XCTAssertGreaterThan(package.depositCents, 0)
        XCTAssertFalse(page.portfolio.isEmpty)
        let settings = try await backend.loadAvailability(for: page.profile.id)
        let hours = try XCTUnwrap(settings)
        XCTAssertFalse(hours.weekly.isEmpty, "Open on some days")
        let taken = try await backend.isHandleAvailable("dana-lens", excluding: UUID())
        XCTAssertFalse(taken, "Their link names are taken")
    }

    func testNothingIsMadeUnlessTheAppAsks() async throws {
        let backend = LocalBackend(root: root)
        let tiles = try await backend.featuredCreators(specialty: nil, near: nil, limit: 24)
        XCTAssertTrue(tiles.isEmpty)
        let found = try await backend.searchCreators("wedding", limit: 20)
        XCTAssertTrue(found.isEmpty)
    }
}

// MARK: - What the database sends

final class FeaturedRowDecodingTests: XCTestCase {
    private let backend = SupabaseBackend(url: URL(string: "https://example.supabase.co")!, anonKey: "test")

    private func decode(_ row: [String: Any]) throws -> SupabaseBackend.FeaturedRow {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SupabaseBackend.FeaturedRow.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private var fullRow: [String: Any] {
        [
            "id": "2D5F7D8E-3A1B-4C62-9E0A-6E8E7B9C0A11", "handle": "ivy-ten-fives", "display_name": "Ivy Ten Fives", "bio": "Hello",
            "specialties": ["weddings", "portraits"], "location_name": "Austin, TX", "latitude": 30.27, "longitude": -97.74,
            "travel_radius_km": 80, "avatar_path": NSNull(), "created_at": "2026-03-01T12:00:00Z", "updated_at": "2026-03-02T12:00:00Z",
            "kind": "person", "cover_path": "ivy/0-thumb.jpg", "starting_price_cents": 90_000, "currency_code": "USD",
            "review_count": 10, "rating_sum": 50, "distance_km": 12.5,
        ]
    }

    func testARowWithEveryColumnTheDatabaseReturnsBecomesATile() throws {
        let fixture = try FeaturedFixture.load()
        XCTAssertEqual(Set(fullRow.keys), Set(fixture.rowColumns), "This row has exactly the columns featured_creators() returns")

        let tile = try backend.makeFeatured(decode(fullRow))
        XCTAssertEqual(tile.profile.handle, "ivy-ten-fives")
        XCTAssertEqual(tile.profile.displayName, "Ivy Ten Fives")
        XCTAssertEqual(tile.profile.specialties, [.weddings, .portraits])
        XCTAssertEqual(tile.profile.location?.name, "Austin, TX")
        XCTAssertTrue(try XCTUnwrap(tile.coverURL).absoluteString.hasSuffix("/portfolio/ivy/0-thumb.jpg"))
        XCTAssertEqual(tile.startingPriceCents, 90_000)
        XCTAssertEqual(tile.currencyCode, "USD")
        XCTAssertEqual(tile.reviews, ReviewSummary(count: 10, ratingSum: 50))
        XCTAssertEqual(tile.distanceKm, 12.5)
    }

    func testACreatorWithNoWorkAndNoPlaceStillBecomesATile() throws {
        var row = fullRow
        row["cover_path"] = NSNull()
        row["location_name"] = NSNull()
        row["latitude"] = NSNull()
        row["longitude"] = NSNull()
        row["travel_radius_km"] = NSNull()
        row["review_count"] = 0
        row["rating_sum"] = 0
        row["distance_km"] = NSNull()
        let tile = try backend.makeFeatured(decode(row))
        XCTAssertNil(tile.coverURL)
        XCTAssertNil(tile.profile.location)
        XCTAssertEqual(tile.reviews, .empty)
        XCTAssertNil(tile.distanceKm, "No place, or no city")
        XCTAssertNil(tile.distanceText)
    }
}

// MARK: - The words on a tile

final class FeaturedTileTextTests: XCTestCase {
    private func tile(specialties: [Specialty], place: String?, reviews: ReviewSummary, distanceKm: Double? = nil) -> FeaturedCreator {
        FeaturedCreator(
            profile: CreatorProfile(
                id: UUID(), handle: "ivy", displayName: "Ivy Park", bio: "", specialties: specialties,
                location: place.map { CreatorLocation(name: $0, latitude: 0, longitude: 0, travelRadiusKm: 50) },
                avatarURL: nil, createdAt: Date(), updatedAt: Date()
            ),
            coverURL: nil, startingPriceCents: 90_000, currencyCode: "USD", reviews: reviews, distanceKm: distanceKm
        )
    }

    func testTheDistanceIsSaidAndSpokenOnlyWithAPlace() {
        let near = tile(specialties: [.food], place: "Austin, TX", reviews: .empty, distanceKm: 6.4)
        let text = near.distanceText
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains(where: \.isNumber) ?? false, "A number of miles or kilometres")
        XCTAssertTrue(near.accessibilitySummary.contains("away"))
        XCTAssertTrue(near.travelsToClient, "6 km is inside their 50 km")
        let far = tile(specialties: [.food], place: "Austin, TX", reviews: .empty, distanceKm: 400)
        XCTAssertFalse(far.travelsToClient)
        let unplaced = tile(specialties: [.food], place: "Austin, TX", reviews: .empty)
        XCTAssertNil(unplaced.distanceText)
        XCTAssertFalse(unplaced.accessibilitySummary.contains("away"))
    }

    func testTheDetailLineNamesWhatTheyShootAndWhere() {
        let full = tile(specialties: [.weddings, .portraits, .family], place: "Austin, TX", reviews: .empty)
        XCTAssertEqual(full.detail, "Weddings · Portraits · Austin, TX", "Two specialties, then the place")
        XCTAssertEqual(tile(specialties: [.food], place: nil, reviews: .empty).detail, "Food")
        XCTAssertEqual(tile(specialties: [], place: "Denver, CO", reviews: .empty).detail, "Denver, CO")
        XCTAssertEqual(tile(specialties: [], place: nil, reviews: .empty).detail, "")
    }

    func testThePriceReadsFromAndTheSummaryIsOneSentence() {
        let reviewed = tile(specialties: [.weddings], place: "Austin, TX", reviews: ReviewSummary(count: 10, ratingSum: 50))
        XCTAssertTrue(reviewed.priceText.hasPrefix("From "))
        XCTAssertTrue(reviewed.priceText.contains("900"))
        let spoken = reviewed.accessibilitySummary
        XCTAssertTrue(spoken.contains("Ivy Park"))
        XCTAssertTrue(spoken.contains("Weddings"))
        XCTAssertTrue(spoken.contains("from 10 reviews"))
        XCTAssertTrue(spoken.contains("From "))
        XCTAssertTrue(tile(specialties: [], place: nil, reviews: .empty).accessibilitySummary.contains("No reviews yet"))
    }
}

// MARK: - Places and distances

final class GeoRulesTests: XCTestCase {
    func testAPlaceIsRoundedToAboutAKilometre() {
        let rounded = GeoPoint(latitude: 30.267153, longitude: -97.743061).rounded()
        XCTAssertEqual(rounded.latitude, 30.27, accuracy: 0.000_001)
        XCTAssertEqual(rounded.longitude, -97.74, accuracy: 0.000_001)
        let place = ClientPlace(name: "Austin, TX", point: GeoPoint(latitude: 30.267153, longitude: -97.743061))
        XCTAssertEqual(place.point, rounded, "A client's place is always kept rounded")
    }

    func testOnlyRealPlacesAreValid() {
        XCTAssertTrue(GeoPoint(latitude: 0, longitude: 0).isValid)
        XCTAssertTrue(GeoPoint(latitude: -90, longitude: 180).isValid)
        XCTAssertFalse(GeoPoint(latitude: 90.01, longitude: 0).isValid)
        XCTAssertFalse(GeoPoint(latitude: 0, longitude: -180.5).isValid)
        XCTAssertFalse(GeoPoint(latitude: .nan, longitude: 0).isValid)
    }

    func testDistancesAreRightAndTheSameBothWays() {
        let austin = GeoPoint(latitude: 30.27, longitude: -97.74)
        let dallas = GeoPoint(latitude: 32.78, longitude: -96.80)
        XCTAssertEqual(GeoRules.distanceKm(from: austin, to: austin), 0, accuracy: 0.000_001)
        XCTAssertEqual(GeoRules.distanceKm(from: austin, to: dallas), 293, accuracy: 1.5)
        XCTAssertEqual(GeoRules.distanceKm(from: austin, to: dallas), GeoRules.distanceKm(from: dallas, to: austin), accuracy: 0.000_001)
        // A quarter of the way round the Earth, along the equator.
        XCTAssertEqual(GeoRules.distanceKm(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: 90)),
                       GeoRules.earthRadiusKm * .pi / 2, accuracy: 0.01)
    }

    func testTheDistanceReadsAsAtLeastOne() {
        XCTAssertFalse(GeoRules.distanceText(km: 0).isEmpty)
        XCTAssertEqual(GeoRules.distanceText(km: 0), GeoRules.distanceText(km: 1), "Never \"0 mi away\"")
    }
}

// MARK: - The client's place in the app

@MainActor
final class FeaturedPlaceFlowTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-place-\(UUID().uuidString)")
        backend = LocalBackend(root: root, offersSampleCreators: true)
        model = AppModel(backend: backend)
        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        try await model.becomeClient(name: "Sam Client")
    }

    override func tearDown() async throws {
        if let id = model.session?.userID {
            UserDefaults.standard.removeObject(forKey: AppConfig.clientAccountKey(for: id))
            UserDefaults.standard.removeObject(forKey: AppConfig.clientPlaceKey(for: id))
        }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    func testWithNoPlaceNobodyHasADistance() async throws {
        XCTAssertNil(model.clientPlace)
        let tiles = try await model.featuredCreators(specialty: nil)
        XCTAssertEqual(tiles.count, 8)
        XCTAssertTrue(tiles.allSatisfy { $0.distanceKm == nil })
        XCTAssertEqual(tiles.first?.profile.handle, "lena-ortiz", "The best reviewed first, as before")
    }

    func testChoosingACityPutsCreatorsWhoWorkThereFirst() async throws {
        model.setClientPlace(ClientPlace(name: "Denver, CO", point: GeoPoint(latitude: 39.7392, longitude: -104.9903)))
        let tiles = try await model.featuredCreators(specialty: nil)
        XCTAssertEqual(tiles.first?.profile.handle, "dana-lens", "The creator in Denver comes first, ahead of better reviewed ones elsewhere")
        XCTAssertTrue(try XCTUnwrap(tiles.first).travelsToClient)
        XCTAssertEqual(try XCTUnwrap(tiles.first?.distanceKm), 0, accuracy: 3)
        XCTAssertTrue(tiles.dropFirst().allSatisfy { !$0.travelsToClient }, "Nobody else works in Denver")
        XCTAssertTrue(tiles.allSatisfy { $0.distanceKm != nil })

        model.setClientPlace(ClientPlace(name: "Austin, TX", point: GeoPoint(latitude: 30.27, longitude: -97.74)))
        let austin = try await model.featuredCreators(specialty: nil)
        XCTAssertEqual(austin.first?.profile.handle, "lena-ortiz")
        let weddings = try await model.featuredCreators(specialty: .weddings)
        XCTAssertEqual(weddings.map(\.profile.handle), ["lena-ortiz", "tomas-and-co"])
    }

    func testThePlaceIsRememberedPerPersonAndCanBeCleared() async throws {
        let id = try XCTUnwrap(model.session?.userID)
        model.setClientPlace(ClientPlace(name: "Denver, CO", point: GeoPoint(latitude: 39.7392, longitude: -104.9903)))
        XCTAssertEqual(model.savedClientPlace(for: id)?.name, "Denver, CO")
        XCTAssertEqual(model.savedClientPlace(for: id)?.point, GeoPoint(latitude: 39.74, longitude: -104.99), "Saved rounded")
        XCTAssertNil(model.savedClientPlace(for: UUID()), "Someone else has none")

        // Opening the app again on the same phone brings it back.
        let reopened = AppModel(backend: backend)
        await reopened.bootstrap()
        XCTAssertEqual(reopened.clientPlace?.name, "Denver, CO")

        model.setClientPlace(nil)
        XCTAssertNil(model.clientPlace)
        XCTAssertNil(model.savedClientPlace(for: id))
    }

    func testSigningOutForgetsThePlaceOnScreen() async throws {
        model.setClientPlace(ClientPlace(name: "Denver, CO", point: GeoPoint(latitude: 39.74, longitude: -104.99)))
        await model.signOut()
        XCTAssertNil(model.clientPlace)
    }
}

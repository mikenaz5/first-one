import Foundation

/// A few made-up creators for the on-device app. With no server there is nobody else to find, so Search and the
/// featured grid would be empty and a client couldn't try booking. Each has a profile, a published package with a
/// contract, hours, a few pictures and some reviews, made through the same calls a real creator's screens use, so
/// booking one works end to end. They are made once, the first time something asks for creators, and only in the app
/// itself (`BackendFactory`); with a server they never exist.
struct SampleCreator {
    struct Offer {
        var name: String
        var summary: String
        var priceCents: Int
        var minutes: Int
        var turnaroundDays: Int
        var deliverables: [String]
    }

    var handle: String
    var name: String
    var bio: String
    var specialties: [Specialty]
    var place: String
    var latitude: Double
    var longitude: Double
    /// Picks the colours of the made-up pictures, 0 to 1 around the colour wheel.
    var hue: Double
    var pieces: Int
    var isVideo: Bool
    var offer: Offer
    var ratings: [Int]
}

extension SampleCreator {
    static let all: [SampleCreator] = [
        SampleCreator(
            handle: "lena-ortiz", name: "Lena Ortiz", bio: "Warm, candid wedding stories, told the way the day felt.",
            specialties: [.weddings, .portraits], place: "Austin, TX", latitude: 30.267, longitude: -97.743, hue: 0.95,
            pieces: 5, isVideo: false,
            offer: Offer(
                name: "Wedding day", summary: "Eight hours of coverage, from getting ready to the first dance.",
                priceCents: 320_000, minutes: 480, turnaroundDays: 30,
                deliverables: ["400+ edited photos", "Online gallery", "Print release"]
            ),
            ratings: [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4]
        ),
        SampleCreator(
            handle: "northlight-films", name: "Northlight Films", bio: "Brand stories and event films for teams that want to be remembered.",
            specialties: [.commercial, .corporate], place: "Chicago, IL", latitude: 41.878, longitude: -87.629, hue: 0.58,
            pieces: 4, isVideo: true,
            offer: Offer(
                name: "Brand story film", summary: "A two-minute film: planning, one shoot day, editing and music.",
                priceCents: 480_000, minutes: 480, turnaroundDays: 21,
                deliverables: ["2-minute film", "Two social cutdowns", "Licensed music"]
            ),
            ratings: [5, 5, 4, 5, 5, 4, 5]
        ),
        SampleCreator(
            handle: "dana-lens", name: "Dana Lens", bio: "Natural-light portraits and family sessions that feel like you.",
            specialties: [.portraits, .family], place: "Denver, CO", latitude: 39.739, longitude: -104.99, hue: 0.08,
            pieces: 6, isVideo: false,
            offer: Offer(
                name: "Portrait session", summary: "An hour outdoors or at home, with a gallery to pick favourites from.",
                priceCents: 35_000, minutes: 60, turnaroundDays: 7,
                deliverables: ["20 edited photos", "Online gallery"]
            ),
            ratings: [5, 5, 5, 4]
        ),
        SampleCreator(
            handle: "kofi-aerial", name: "Kofi Mensah", bio: "Listing photos and drone views that help homes sell faster.",
            specialties: [.aerial, .realEstate], place: "Atlanta, GA", latitude: 33.749, longitude: -84.388, hue: 0.40,
            pieces: 4, isVideo: false,
            offer: Offer(
                name: "Listing photos and drone", summary: "Interior, exterior and aerial photos, delivered the next day.",
                priceCents: 42_500, minutes: 90, turnaroundDays: 2,
                deliverables: ["30 edited photos", "10 aerial photos"]
            ),
            ratings: [5, 4, 5]
        ),
        SampleCreator(
            handle: "sage-and-salt", name: "Sage & Salt Studio", bio: "Food and product photography for small brands and restaurants.",
            specialties: [.food, .product], place: "Portland, OR", latitude: 45.515, longitude: -122.679, hue: 0.28,
            pieces: 5, isVideo: false,
            offer: Offer(
                name: "Menu shoot", summary: "Up to twelve dishes or products, styled and shot in our studio.",
                priceCents: 90_000, minutes: 180, turnaroundDays: 5,
                deliverables: ["12 edited images", "Web and print sizes"]
            ),
            ratings: [5, 5, 5, 5, 4, 5]
        ),
        SampleCreator(
            handle: "marcus-reel", name: "Marcus Reel", bio: "Music videos and short-form clips with a lot of energy.",
            specialties: [.music, .social], place: "Nashville, TN", latitude: 36.163, longitude: -86.782, hue: 0.75,
            pieces: 3, isVideo: true,
            offer: Offer(
                name: "Music video", summary: "One location, one day, a polished video for one song.",
                priceCents: 250_000, minutes: 600, turnaroundDays: 21,
                deliverables: ["3-4 minute video", "Teaser for social"]
            ),
            ratings: [4, 5]
        ),
        SampleCreator(
            handle: "ivy-park", name: "Ivy Park", bio: "Editorial fashion and lively event coverage.",
            specialties: [.fashion, .events], place: "New York, NY", latitude: 40.713, longitude: -74.006, hue: 0.85,
            pieces: 4, isVideo: false,
            offer: Offer(
                name: "Event coverage", summary: "Three hours of candid coverage and a gallery for your guests.",
                priceCents: 120_000, minutes: 180, turnaroundDays: 7,
                deliverables: ["150 edited photos", "Online gallery"]
            ),
            ratings: []
        ),
        SampleCreator(
            handle: "tomas-and-co", name: "Tomás & Co", bio: "Documentary-style wedding films, quiet and honest.",
            specialties: [.weddings, .documentary], place: "Miami, FL", latitude: 25.762, longitude: -80.192, hue: 0.12,
            pieces: 3, isVideo: true,
            offer: Offer(
                name: "Highlight film", summary: "A five-minute film of your day, with your own vows in it.",
                priceCents: 280_000, minutes: 480, turnaroundDays: 28,
                deliverables: ["5-minute highlight film", "Full ceremony edit"]
            ),
            ratings: [5, 5, 5, 5, 5]
        ),
    ]
}

extension LocalBackend {
    private var sampleMarkerURL: URL { root.appendingPathComponent("sample-creators.json") }

    /// Makes the sample creators the first time anything asks for creators, once per install. Does nothing in tests.
    func seedSampleCreatorsIfNeeded() async {
        guard offersSampleCreators else { return }
        if let running = sampleSeeding {
            await running.value
            return
        }
        let task = Task { await self.seedSampleCreators() }
        sampleSeeding = task
        await task.value
    }

    private func seedSampleCreators() async {
        guard !fileManager.fileExists(atPath: sampleMarkerURL.path) else { return }
        for (index, sample) in SampleCreator.all.enumerated() {
            // One that can't be made shouldn't stop the rest.
            try? await seed(sample, index: index)
        }
        try? write(["version": 1], to: sampleMarkerURL)
    }

    private func seed(_ sample: SampleCreator, index: Int) async throws {
        let id = UUID()
        let stamp = now
        // Different ages, so the featured order has something to break ties with.
        let created = stamp.addingTimeInterval(-86_400 * Double(20 + index * 9))

        // They count as people with accounts, so nobody can take their link names.
        var accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        accounts["sample:\(sample.handle)"] = id
        try write(accounts, to: accountsURL)

        _ = try await saveProfile(CreatorProfile(
            id: id, handle: sample.handle, displayName: sample.name, bio: sample.bio, specialties: sample.specialties,
            location: CreatorLocation(name: sample.place, latitude: sample.latitude, longitude: sample.longitude, travelRadiusKm: 80),
            avatarURL: nil, createdAt: created, updatedAt: created
        ), avatarJPEG: nil)

        try await saveCreatorSignature(
            CreatorSignature(signedName: sample.name, method: .typed, imagePNG: nil, updatedAt: stamp), for: id
        )
        let template = StarterTemplates.make(sample.isVideo ? .videography : .photography, creatorID: id, now: stamp)
        let saved = try await saveContractTemplate(template)
        let offer = sample.offer
        _ = try await savePackage(ServicePackage(
            id: UUID(), creatorID: id, name: offer.name, summary: offer.summary, category: sample.specialties.first,
            priceCents: offer.priceCents, currencyCode: "USD", durationMinutes: offer.minutes,
            deliverables: offer.deliverables, turnaroundDays: offer.turnaroundDays, depositCents: offer.priceCents / 4,
            addOns: [], isPublished: true, position: 0, createdAt: stamp, updatedAt: stamp,
            contractTemplateID: saved.first { $0.id == template.id }?.id ?? template.id,
            cancellationPolicy: .moderate, usageRights: .personal
        ))
        _ = try await saveAvailability(.standard(), for: id)

        let pictures: [NewPortfolioItem] = (0..<sample.pieces).compactMap { variant in
            guard let full = SampleArt.jpeg(hue: sample.hue, variant: variant, width: 640, height: 800),
                  let thumbnail = SampleArt.jpeg(hue: sample.hue, variant: variant, width: 320, height: 400) else { return nil }
            return NewPortfolioItem(kind: .photo, imageJPEG: full, thumbnailJPEG: thumbnail, videoFile: nil, duration: nil, aspectRatio: 0.8)
        }
        if !pictures.isEmpty { _ = try await addPortfolioItems(pictures, for: id) }

        let reviewers = ["Alex R.", "Jordan T.", "Sam W.", "Priya N.", "Chris M.", "Taylor B."]
        let reviews = sample.ratings.enumerated().map { position, rating in
            Review(
                id: UUID(), bookingID: nil, creatorID: id, rating: rating, body: "",
                reviewerName: reviewers[position % reviewers.count], packageName: offer.name,
                createdAt: stamp.addingTimeInterval(-86_400 * Double(3 + position * 11))
            )
        }
        try storeSampleReviews(reviews)
    }
}

import XCTest
@testable import Slate

final class ModelsTests: XCTestCase {
    private func profile(
        name: String = "Maya Chen",
        handle: String = "maya-chen",
        bio: String = "",
        specialties: [Specialty] = [],
        location: CreatorLocation? = nil,
        avatar: URL? = nil
    ) -> CreatorProfile {
        CreatorProfile(
            id: UUID(), handle: handle, displayName: name, bio: bio,
            specialties: specialties, location: location, avatarURL: avatar,
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testProfileIsCompleteNeedsNameHandleAndSpecialty() {
        XCTAssertFalse(profile().isComplete)
        XCTAssertFalse(profile(name: "  ", specialties: [.weddings]).isComplete)
        XCTAssertFalse(profile(handle: "x", specialties: [.weddings]).isComplete)
        XCTAssertTrue(profile(specialties: [.weddings]).isComplete)
    }

    func testCompletenessCountsEachStep() {
        let empty = ProfileCompleteness(profile: profile(), portfolioCount: 0)
        XCTAssertEqual(empty.fraction, 0, accuracy: 0.0001)
        XCTAssertEqual(empty.nextStep?.id, "photo")

        let partial = ProfileCompleteness(profile: profile(specialties: [.events]), portfolioCount: 0)
        XCTAssertEqual(partial.fraction, 0.2, accuracy: 0.0001)

        let full = ProfileCompleteness(
            profile: profile(
                bio: "Hello",
                specialties: [.events],
                location: CreatorLocation(name: "Austin, TX", latitude: 30.27, longitude: -97.74, travelRadiusKm: 40),
                avatar: URL(string: "https://example.com/a.jpg")
            ),
            portfolioCount: ProfileCompleteness.recommendedPortfolioCount
        )
        XCTAssertEqual(full.fraction, 1, accuracy: 0.0001)
        XCTAssertTrue(full.isComplete)
        XCTAssertNil(full.nextStep)
    }

    func testPortfolioFilterMatching() {
        func item(_ kind: PortfolioItem.Kind) -> PortfolioItem {
            PortfolioItem(
                id: UUID(), kind: kind, position: 0, caption: "",
                imageURL: URL(fileURLWithPath: "/a.jpg"), thumbnailURL: URL(fileURLWithPath: "/t.jpg"),
                videoURL: nil, duration: nil, aspectRatio: 1, createdAt: Date()
            )
        }
        XCTAssertTrue(PortfolioFilter.all.matches(item(.photo)))
        XCTAssertTrue(PortfolioFilter.all.matches(item(.video)))
        XCTAssertTrue(PortfolioFilter.photos.matches(item(.photo)))
        XCTAssertFalse(PortfolioFilter.photos.matches(item(.video)))
        XCTAssertTrue(PortfolioFilter.reels.matches(item(.video)))
        XCTAssertFalse(PortfolioFilter.reels.matches(item(.photo)))
    }

    func testAccessibilityDescriptions() {
        let photo = PortfolioItem(
            id: UUID(), kind: .photo, position: 0, caption: "Golden hour",
            imageURL: URL(fileURLWithPath: "/a.jpg"), thumbnailURL: URL(fileURLWithPath: "/t.jpg"),
            videoURL: nil, duration: nil, aspectRatio: 1, createdAt: Date()
        )
        XCTAssertEqual(photo.accessibilityDescription, "Photo, Golden hour")

        var reel = photo
        reel.kind = .video
        reel.duration = 75
        reel.caption = "Highlights"
        XCTAssertTrue(reel.accessibilityDescription.hasPrefix("Reel, "))
        XCTAssertTrue(reel.accessibilityDescription.hasSuffix(", Highlights"))
    }

    func testBookingURLUsesHandle() {
        XCTAssertEqual(AppConfig.bookingURL(handle: "maya-chen")?.absoluteString,
                       "https://\(AppConfig.bookingLinkHost)/maya-chen")
    }
}

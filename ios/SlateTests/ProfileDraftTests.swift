import XCTest
@testable import Slate

@MainActor
final class ProfileDraftTests: XCTestCase {
    func testHandleFollowsNameUntilEdited() {
        let draft = ProfileDraft()
        draft.displayName = "Maya Chen"
        draft.updateSuggestedHandle()
        XCTAssertEqual(draft.handle, "maya-chen")
        draft.normalizeHandle()
        XCTAssertFalse(draft.handleTouched, "An automatic suggestion isn't a user edit")

        draft.handle = "mayac"
        draft.normalizeHandle()
        XCTAssertTrue(draft.handleTouched)

        draft.displayName = "Maya Chen Studio"
        draft.updateSuggestedHandle()
        XCTAssertEqual(draft.handle, "mayac", "Edited handles are never overwritten")
    }

    func testNormalizeHandleRewritesInvalidInput() {
        let draft = ProfileDraft()
        draft.handle = "Maya Chen"
        XCTAssertTrue(draft.normalizeHandle())
        XCTAssertEqual(draft.handle, "maya-chen")
        XCTAssertFalse(draft.normalizeHandle())
    }

    func testSpecialtyLimit() {
        let draft = ProfileDraft()
        for specialty in Specialty.allCases.prefix(AppConfig.maxSpecialties) {
            XCTAssertTrue(draft.toggle(specialty))
        }
        let extra = Specialty.allCases[AppConfig.maxSpecialties]
        XCTAssertFalse(draft.toggle(extra))
        XCTAssertFalse(draft.isSelected(extra))

        let first = Specialty.allCases[0]
        XCTAssertTrue(draft.toggle(first), "Deselecting is always allowed")
        XCTAssertTrue(draft.toggle(extra), "There is room again after deselecting")
    }

    func testIdentityValidity() {
        let draft = ProfileDraft()
        XCTAssertFalse(draft.identityIsValid)

        draft.displayName = "Maya Chen"
        draft.handle = "maya-chen"
        XCTAssertTrue(draft.identityIsValid)

        draft.handleStatus = .taken
        XCTAssertFalse(draft.identityIsValid)
        draft.handleStatus = .checking
        XCTAssertFalse(draft.identityIsValid)
        draft.handleStatus = .failed
        XCTAssertTrue(draft.identityIsValid, "An offline check shouldn't block; the server decides on save")
    }

    func testCanPublishNeedsSpecialty() {
        let draft = ProfileDraft()
        draft.displayName = "Maya"
        draft.handle = "maya-chen"
        XCTAssertFalse(draft.canPublish)
        draft.toggle(.portraits)
        XCTAssertTrue(draft.canPublish)
    }

    func testSettingPlaceKeepsTravelRadius() {
        let draft = ProfileDraft()
        draft.setPlace(name: "Austin, TX", latitude: 30.27, longitude: -97.74)
        XCTAssertEqual(draft.location?.travelRadiusKm, TravelRadius.defaultKm)
        draft.setTravelRadius(100)
        draft.setPlace(name: "Dallas, TX", latitude: 32.78, longitude: -96.8)
        XCTAssertEqual(draft.location?.travelRadiusKm, 100)
        XCTAssertEqual(draft.location?.name, "Dallas, TX")
    }

    func testBioIsClamped() {
        let draft = ProfileDraft()
        draft.bio = String(repeating: "x", count: AppConfig.bioLimit + 50)
        draft.clampBio()
        XCTAssertEqual(draft.bio.count, AppConfig.bioLimit)
    }

    func testMakeProfileTrimsAndKeepsExistingMetadata() {
        let created = Date(timeIntervalSince1970: 1_000)
        let avatar = URL(string: "https://example.com/a.jpg")
        let existing = CreatorProfile(
            id: UUID(), handle: "old", displayName: "Old", bio: "", specialties: [],
            location: nil, avatarURL: avatar, createdAt: created, updatedAt: created
        )
        let draft = ProfileDraft(profile: existing)
        draft.displayName = "  Maya Chen  "
        draft.handle = "maya-chen"
        draft.bio = "  Hello  "

        let made = draft.makeProfile(id: existing.id, existing: existing)
        XCTAssertEqual(made.displayName, "Maya Chen")
        XCTAssertEqual(made.bio, "Hello")
        XCTAssertEqual(made.createdAt, created)
        XCTAssertEqual(made.avatarURL, avatar)
    }
}

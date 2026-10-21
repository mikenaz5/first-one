import UIKit
import XCTest
@testable import Slate

final class LocalBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-tests-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private func credential(_ appleID: String = "apple-1", name: String? = nil) -> AppleCredential {
        var components: PersonNameComponents?
        if let name {
            var parts = PersonNameComponents()
            parts.givenName = name
            components = parts
        }
        return AppleCredential(userID: appleID, identityToken: "token", rawNonce: "nonce", fullName: components, email: nil)
    }

    private func profile(for userID: UUID, handle: String = "maya-chen") -> CreatorProfile {
        CreatorProfile(
            id: userID, handle: handle, displayName: "Maya Chen", bio: "Hi",
            specialties: [.weddings, .portraits], location: nil, avatarURL: nil,
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func jpeg() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        return renderer.jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    private func photo() -> NewPortfolioItem {
        NewPortfolioItem(kind: .photo, imageJPEG: jpeg(), thumbnailJPEG: jpeg(), aspectRatio: 4.0 / 3.0)
    }

    // MARK: Auth

    func testSignInPersistsSession() async throws {
        let session = try await backend.signInWithApple(credential(name: "Maya"))
        XCTAssertEqual(session.fullName, "Maya")
        let restored = await backend.restoreSession()
        XCTAssertEqual(restored, session)
    }

    func testSameAppleIDGetsSameUserAfterSignOut() async throws {
        let first = try await backend.signInWithApple(credential("apple-1"))
        try await backend.signOut()
        let restoredAfterSignOut = await backend.restoreSession()
        XCTAssertNil(restoredAfterSignOut)

        let again = try await backend.signInWithApple(credential("apple-1"))
        XCTAssertEqual(again.userID, first.userID)

        let other = try await backend.signInWithApple(credential("apple-2"))
        XCTAssertNotEqual(other.userID, first.userID)
    }

    func testDeleteAccountRemovesEverything() async throws {
        let session = try await backend.signInWithApple(credential())
        _ = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: jpeg())
        _ = try await backend.addPortfolioItems([photo()], for: session.userID)

        try await backend.deleteAccount()

        let restored = await backend.restoreSession()
        XCTAssertNil(restored)
        let loadedProfile = try await backend.loadProfile(for: session.userID)
        XCTAssertNil(loadedProfile)
        let loadedPortfolio = try await backend.loadPortfolio(for: session.userID)
        XCTAssertTrue(loadedPortfolio.isEmpty)

        let fresh = try await backend.signInWithApple(credential())
        XCTAssertNotEqual(fresh.userID, session.userID, "Deleted accounts don't come back")
    }

    // MARK: Profile

    func testProfileRoundTrip() async throws {
        let session = try await backend.signInWithApple(credential())
        let saved = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: jpeg())
        XCTAssertNotNil(saved.avatarURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.avatarURL).path))

        let loaded = try await backend.loadProfile(for: session.userID)
        XCTAssertEqual(loaded?.handle, "maya-chen")
        XCTAssertEqual(loaded?.specialties, [.weddings, .portraits])
        XCTAssertEqual(loaded?.avatarURL, saved.avatarURL)
    }

    func testReplacingAvatarDeletesTheOldFile() async throws {
        let session = try await backend.signInWithApple(credential())
        let first = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: jpeg())
        try await Task.sleep(for: .milliseconds(5)) // File names are timestamped.
        let second = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: jpeg())

        let firstURL = try XCTUnwrap(first.avatarURL)
        let secondURL = try XCTUnwrap(second.avatarURL)
        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testSavingWithoutAvatarKeepsExisting() async throws {
        let session = try await backend.signInWithApple(credential())
        let first = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: jpeg())
        let second = try await backend.saveProfile(profile(for: session.userID), avatarJPEG: nil)
        XCTAssertEqual(first.avatarURL, second.avatarURL)
    }

    func testHandleAvailability() async throws {
        let session = try await backend.signInWithApple(credential())
        let simulatedTaken = try await backend.isHandleAvailable("maya", excluding: session.userID)
        XCTAssertFalse(simulatedTaken)
        let free = try await backend.isHandleAvailable("someone-new", excluding: session.userID)
        XCTAssertTrue(free)

        do {
            _ = try await backend.saveProfile(profile(for: session.userID, handle: "maya"), avatarJPEG: nil)
            XCTFail("Expected handleTaken")
        } catch {
            XCTAssertEqual(error as? SlateError, .handleTaken)
        }
    }

    func testHandleTakenByAnotherLocalAccount() async throws {
        let first = try await backend.signInWithApple(credential("apple-1"))
        _ = try await backend.saveProfile(profile(for: first.userID, handle: "shared-name"), avatarJPEG: nil)

        let second = try await backend.signInWithApple(credential("apple-2"))
        let free = try await backend.isHandleAvailable("shared-name", excluding: second.userID)
        XCTAssertFalse(free)
        let ownIsFree = try await backend.isHandleAvailable("shared-name", excluding: first.userID)
        XCTAssertTrue(ownIsFree, "You can always keep your own handle")
    }

    // MARK: Portfolio

    func testAddingAssignsPositionsAndStoresFiles() async throws {
        let session = try await backend.signInWithApple(credential())
        let items = try await backend.addPortfolioItems([photo(), photo()], for: session.userID)
        XCTAssertEqual(items.map(\.position), [0, 1])
        for item in items {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.imageURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
        }
        let reloaded = try await backend.loadPortfolio(for: session.userID)
        XCTAssertEqual(reloaded.map(\.id), items.map(\.id))
    }

    func testDeleteRepacksPositionsAndRemovesFiles() async throws {
        let session = try await backend.signInWithApple(credential())
        let items = try await backend.addPortfolioItems([photo(), photo(), photo()], for: session.userID)

        let remaining = try await backend.deletePortfolioItem(items[0].id, for: session.userID)
        XCTAssertEqual(remaining.map(\.id), [items[1].id, items[2].id])
        XCTAssertEqual(remaining.map(\.position), [0, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[0].imageURL.path))
    }

    func testMoveToFront() async throws {
        let session = try await backend.signInWithApple(credential())
        let items = try await backend.addPortfolioItems([photo(), photo(), photo()], for: session.userID)

        let reordered = try await backend.movePortfolioItemToFront(items[2].id, for: session.userID)
        XCTAssertEqual(reordered.map(\.id), [items[2].id, items[0].id, items[1].id])
        XCTAssertEqual(reordered.map(\.position), [0, 1, 2])
    }

    func testPortfolioLimit() async throws {
        let session = try await backend.signInWithApple(credential())
        let full = (0..<AppConfig.portfolioLimit).map { _ in photo() }
        _ = try await backend.addPortfolioItems(full, for: session.userID)

        do {
            _ = try await backend.addPortfolioItems([photo()], for: session.userID)
            XCTFail("Expected portfolioFull")
        } catch {
            XCTAssertEqual(error as? SlateError, .portfolioFull(limit: AppConfig.portfolioLimit))
        }
    }

    func testVideoFileIsCopiedIntoMedia() async throws {
        let session = try await backend.signInWithApple(credential())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([0, 1, 2, 3]).write(to: source)

        let item = NewPortfolioItem(
            kind: .video, imageJPEG: jpeg(), thumbnailJPEG: jpeg(),
            videoFile: source, duration: 12, aspectRatio: 9.0 / 16.0
        )
        let saved = try await backend.addPortfolioItems([item], for: session.userID)
        let videoURL = try XCTUnwrap(saved.first?.videoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "The picker's temp copy is cleaned up")
    }
}

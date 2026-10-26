import XCTest
@testable import Slate

// MARK: - The shared fixture

/// `Fixtures/file_rules.json`, which `supabase/tests/file_rules.py` reads too: every case the phone and the database must
/// answer the same way (the caps, the allowance, the 30 days, who can open what, the reminders, names and types).
private struct FileFixture: Decodable {
    struct Cap: Decodable {
        var name: String
        var kind: String
        var originalBytes: Int64
        var previewBytes: Int64
        var filesInDelivery: Int
        var usedBytes: Int64
        var allowanceBytes: Int64
        var refusal: String?
    }

    struct Allowance: Decodable {
        var name: String
        var individual: Bool
        var billedSeats: Int
        var bytes: Int64
    }

    struct Expiry: Decodable {
        var name: String
        var deliveredAt: String
        var expiresAt: String
    }

    struct ExpiredAt: Decodable {
        var name: String
        var expiresAt: String
        var expired: Bool
    }

    struct Open: Decodable {
        var name: String
        var viewer: String
        var part: String
        var deliveryKind: String
        var state: String
        var expiresAt: String?
        var owedCents: Int
        var open: Bool
    }

    struct Reminder: Decodable {
        var name: String
        var expiresAt: String
        var day: Int?
    }

    struct Title: Decodable {
        var sequence: Int
        var title: String
    }

    struct Name: Decodable {
        var name: String
        var input: String
        var clean: String
    }

    struct ContentType: Decodable {
        var type: String
        var kind: String?
    }

    struct Locked: Decodable {
        var name: String
        var hasFilesDelivery: Bool
        var linkDelivered: Bool
        var balancePaid: Bool
        var locked: Bool
    }

    struct Revision: Decodable {
        var name: String
        var firstState: String
        var owedCents: Int
        var allowed: Bool
    }

    var config: FilesConfig
    var now: String
    var caps: [Cap]
    var allowance: [Allowance]
    var expiry: [Expiry]
    var expiredAt: [ExpiredAt]
    var open: [Open]
    var reminders: [Reminder]
    var titles: [Title]
    var names: [Name]
    var contentTypes: [ContentType]
    var firstDeliveryLocked: [Locked]
    var revisionAllowed: [Revision]

    static func load() throws -> FileFixture {
        let url = try XCTUnwrap(
            Bundle(for: FileRulesTests.self).url(forResource: "file_rules", withExtension: "json"),
            "file_rules.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(FileFixture.self, from: Data(contentsOf: url))
    }

    func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }
}

// MARK: - Rules

final class FileRulesTests: XCTestCase {
    func testTheStandardNumbersAreTheDatabasesOwn() throws {
        let fixture = try FileFixture.load()
        XCTAssertEqual(FilesConfig.standard, fixture.config)
    }

    func testEveryCapAgreesWithTheDatabase() throws {
        let fixture = try FileFixture.load()
        XCTAssertGreaterThanOrEqual(fixture.caps.count, 15)
        for item in fixture.caps {
            let kind = try XCTUnwrap(FileKind(rawValue: item.kind), item.name)
            let refusal = FileRules.refusal(
                kind: kind, originalBytes: item.originalBytes, previewBytes: item.previewBytes, filesInDelivery: item.filesInDelivery,
                usedBytes: item.usedBytes, allowanceBytes: item.allowanceBytes, config: fixture.config
            )
            XCTAssertEqual(FileRules.token(for: refusal), item.refusal, item.name)
        }
    }

    func testTheAllowanceOfAnIndividualAndOfACompany() throws {
        let fixture = try FileFixture.load()
        for item in fixture.allowance {
            XCTAssertEqual(
                FileRules.allowanceBytes(individual: item.individual, billedSeats: item.billedSeats, config: fixture.config),
                item.bytes, item.name
            )
        }
    }

    func testADeliveryEndsThirtyDaysAfterItIsMade() throws {
        let fixture = try FileFixture.load()
        for item in fixture.expiry {
            XCTAssertEqual(
                FileRules.expiresAt(deliveredAt: try fixture.date(item.deliveredAt), config: fixture.config),
                try fixture.date(item.expiresAt), item.name
            )
        }
        let now = try fixture.date(fixture.now)
        for item in fixture.expiredAt {
            XCTAssertEqual(FileRules.isExpired(expiresAt: try fixture.date(item.expiresAt), now: now), item.expired, item.name)
        }
    }

    func testWhoCanOpenWhatAgreesWithTheDatabase() throws {
        let fixture = try FileFixture.load()
        let now = try fixture.date(fixture.now)
        XCTAssertGreaterThanOrEqual(fixture.open.count, 12)
        for item in fixture.open {
            let viewer = try XCTUnwrap(FileRules.Viewer(rawValue: item.viewer), item.name)
            let part = try XCTUnwrap(FileRules.Part(rawValue: item.part), item.name)
            let kind = try XCTUnwrap(DeliveryKind(rawValue: item.deliveryKind), item.name)
            let state = try XCTUnwrap(DeliveryState(rawValue: item.state), item.name)
            let expires = try item.expiresAt.map { try fixture.date($0) }
            XCTAssertEqual(
                FileRules.canOpen(part, as: viewer, kind: kind, state: state, expiresAt: expires, owedCents: item.owedCents, now: now),
                item.open, item.name
            )
        }
    }

    func testTheClientIsRemindedAWeekAndADayBeforeTheEnd() throws {
        let fixture = try FileFixture.load()
        let now = try fixture.date(fixture.now)
        for item in fixture.reminders {
            XCTAssertEqual(FileRules.reminderDay(expiresAt: try fixture.date(item.expiresAt), now: now, config: fixture.config), item.day, item.name)
        }
    }

    func testRevisionsAreNumbered() throws {
        for item in try FileFixture.load().titles {
            XCTAssertEqual(FileRules.revisionTitle(sequence: item.sequence), item.title)
        }
    }

    func testNamesAreTidied() throws {
        for item in try FileFixture.load().names {
            XCTAssertEqual(FileRules.cleanName(item.input), item.clean, item.name)
        }
    }

    func testOnlyPhotosAndVideosAreTaken() throws {
        for item in try FileFixture.load().contentTypes {
            XCTAssertEqual(FileRules.kind(forContentType: item.type)?.rawValue, item.kind, item.type)
        }
    }

    func testTheFirstDeliveryIsLockedOnceTheClientHasPaidOrConfirmed() throws {
        for item in try FileFixture.load().firstDeliveryLocked {
            XCTAssertEqual(
                FileRules.firstDeliveryLocked(hasFilesDelivery: item.hasFilesDelivery, linkDelivered: item.linkDelivered, balancePaid: item.balancePaid),
                item.locked, item.name
            )
        }
    }

    func testARevisionIsNeverAWayRoundPayment() throws {
        for item in try FileFixture.load().revisionAllowed {
            let state: DeliveryState? = item.firstState == "none" ? nil : DeliveryState(rawValue: item.firstState)
            XCTAssertEqual(FileRules.revisionAllowed(firstState: state, owedCents: item.owedCents), item.allowed, item.name)
        }
    }

    // MARK: Words and numbers

    func testRefusalsSayWhatToDo() {
        XCTAssertTrue(FileRefusal.storageFull(usedBytes: 24_000_000_000, allowanceBytes: 25_000_000_000).message.contains("deliver by link"))
        XCTAssertTrue(FileRefusal.tooLarge(maxBytes: 100_000_000).message.contains("100 MB"))
        XCTAssertTrue(FileRefusal.tooManyFiles.message.contains("revision"))
    }

    func testTheStorageMeterReadsInPlainWords() {
        let meter = StorageMeter(usedBytes: 4_200_000_000, allowanceBytes: 25_000_000_000)
        XCTAssertEqual(meter.text, "4.2 GB of 25 GB used")
        XCTAssertEqual(meter.fraction, 0.168, accuracy: 0.0001)
        XCTAssertFalse(meter.isNearlyFull)
        XCTAssertTrue(StorageMeter(usedBytes: 23_000_000_000, allowanceBytes: 25_000_000_000).isNearlyFull)
        XCTAssertEqual(StorageMeter(usedBytes: 30, allowanceBytes: 0).fraction, 1)
        XCTAssertEqual(StorageMeter(usedBytes: 30_000_000_000, allowanceBytes: 25_000_000_000).remainingBytes, 0)
    }

    private func file(_ kind: FileKind = .photo, status: FileStatus = .ready, saved: Bool = false, bytes: Int64 = 1_000_000, duration: Double? = nil) -> DeliveryFile {
        DeliveryFile(
            id: UUID(), kind: kind, name: "IMG.jpg", contentType: kind == .photo ? "image/jpeg" : "video/mp4", width: 3000, height: 2000,
            durationSeconds: duration, originalBytes: bytes, previewBytes: 100_000, status: status,
            savedAt: saved ? Date(timeIntervalSince1970: 1_800_000_000) : nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            position: 0, previewPath: "a/b/c/preview", originalPath: "a/b/c/original"
        )
    }

    private func delivery(_ files: [DeliveryFile], state: DeliveryState = .delivered, kind: DeliveryKind = .delivery, sequence: Int = 0, expires: Date? = nil) -> FileDelivery {
        FileDelivery(
            id: UUID(), bookingID: UUID(), kind: kind, sequence: sequence, title: "", note: "", state: state,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), deliveredAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: expires, originalsOpen: true, files: files
        )
    }

    func testADeliveryCountsWhatItHolds() {
        let made = delivery([file(), file(), file(.video, duration: 42), file(status: .removed), file(saved: true)])
        XCTAssertEqual(made.photoCount, 3, "A removed file is not counted")
        XCTAssertEqual(made.videoCount, 1)
        XCTAssertEqual(made.savedCount, 1)
        XCTAssertEqual(made.unsavedCount, 3)
        XCTAssertEqual(made.countText, "3 photos and 1 video")
        XCTAssertEqual(delivery([file()]).countText, "1 photo")
        XCTAssertEqual(delivery([]).countText, "No files")
        XCTAssertEqual(delivery([file(.video)]).countText, "1 video")
    }

    func testADeliveryKnowsHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = delivery([file()], expires: now.addingTimeInterval(86_400 * 2.2))
        XCTAssertEqual(live.daysLeft(at: now), 3, "Rounded up, so it never says 0 days while there is time")
        XCTAssertFalse(live.isExpired(at: now))
        let over = delivery([file()], expires: now.addingTimeInterval(-1))
        XCTAssertNil(over.daysLeft(at: now))
        XCTAssertTrue(over.isExpired(at: now))
        XCTAssertTrue(delivery([file()], state: .expired, expires: now.addingTimeInterval(86_400)).isExpired(at: now))
        XCTAssertNil(delivery([file()], state: .draft).daysLeft(at: now))
    }

    func testHeadingsAndFileDetails() {
        XCTAssertEqual(delivery([]).heading, "Delivery")
        XCTAssertEqual(delivery([], kind: .revision, sequence: 2).heading, "Revision 2")
        var titled = delivery([], kind: .revision, sequence: 3)
        titled.title = "Colour corrections"
        XCTAssertEqual(titled.heading, "Colour corrections")
        XCTAssertEqual(file(.video, duration: 62).durationText, "1:02")
        XCTAssertNil(file().durationText)
        XCTAssertEqual(file().aspectRatio, 1.5, accuracy: 0.0001)
        var unknown = file()
        unknown.width = nil
        XCTAssertEqual(unknown.aspectRatio, 1.5)
    }

    func testABookingsFilesAreSortedForTheClient() {
        let draft = delivery([file()], state: .draft, sequence: 1)
        let first = delivery([file()], sequence: 0)
        let revision = delivery([file()], kind: .revision, sequence: 2)
        let all = BookingFiles(bookingID: UUID(), owedCents: 0, deliveries: [first, draft, revision], usedBytes: 1, allowanceBytes: 10, canDeliverFiles: false, canSendRevision: true)
        XCTAssertEqual(all.delivered.map(\.sequence), [2, 0], "Newest first, and no drafts")
        XCTAssertEqual(all.draft?.sequence, 1)
        XCTAssertEqual(all.firstDelivery?.sequence, 0)
        XCTAssertNotNil(all.meter)
        XCTAssertNil(BookingFiles.empty(for: UUID()).meter)
        XCTAssertFalse(BookingFiles.empty(for: UUID()).hasFiles)
    }
}

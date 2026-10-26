import XCTest
@testable import Slate

/// Slate Files against the on-device backend, on a clock the tests move by hand. The same rules are tested in Postgres by
/// `supabase/tests/file_rules.py`, and the numbers by `FileRulesTests`, from one shared fixture.
final class FileBackendTests: XCTestCase {
    private var roots: [URL] = []
    private var root: URL!
    private var scratch: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var creator: Creator!

    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot below is Friday 22 Jan at 10:00.
    private let start = TestClock.date(2027, 1, 4, 8, 0)
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let client = UUID()
    private let stranger = UUID()

    private struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    override func setUp() async throws {
        try await super.setUp()
        try await makeBackend()
    }

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeBackend(config: FilesConfig = .standard, deposit: Int = 50_000) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-files-\(UUID().uuidString)")
        scratch = root.appendingPathComponent("phone-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        roots.append(root)
        let clock = ManualClock(start)
        self.clock = clock
        backend = LocalBackend(root: root, clock: { clock.now }, filesConfig: config)
        creator = try await makeCreator(deposit: deposit)
    }

    private func makeCreator(handle: String = "dana-lens", deposit: Int) async throws -> Creator {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: deposit, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .moderate
        ))
        return Creator(id: session.userID, package: saved[0])
    }

    @discardableResult
    private func book(client: UUID? = nil) async throws -> SignedBooking {
        let request = BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: friday, notes: "")
        return try await ContractFixtures.signedBooking(backend, request, clientID: client ?? self.client, name: "Sam Client")
    }

    /// A booking whose shoot is over.
    private func bookedAndShot() async throws -> UUID {
        let signed = try await book()
        clock.set(signed.booking.endAt.addingTimeInterval(3600))
        return signed.booking.id
    }

    private func bytesOnPhone(_ name: String, count: Int) throws -> URL {
        let url = scratch.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(repeating: 7, count: count).write(to: url)
        return url
    }

    private func request(
        _ bookingID: UUID, name: String = "IMG_0001.HEIC", kind: FileKind = .photo, type: String = "image/heic",
        original: Int64 = 3_000, preview: Int64 = 400
    ) -> FileUploadRequest {
        FileUploadRequest(
            bookingID: bookingID, kind: kind, name: name, contentType: type, width: 4000, height: 3000,
            durationSeconds: kind == .video ? 12.5 : nil, originalBytes: original, previewBytes: preview
        )
    }

    /// Reserve, send, finish.
    @discardableResult
    private func addFile(
        _ bookingID: UUID, name: String = "IMG_0001.HEIC", kind: FileKind = .photo, type: String = "image/heic",
        original: Int = 3_000, preview: Int = 400, by user: UUID? = nil
    ) async throws -> (reservation: FileReservation, outcome: FileFinalization) {
        let user = user ?? creator.id
        let reservation = try await backend.reserveFile(
            request(bookingID, name: name, kind: kind, type: type, original: Int64(original), preview: Int64(preview)), by: user
        )
        let source = FileUploadSource(original: try bytesOnPhone("original", count: original), preview: try bytesOnPhone("preview", count: preview))
        try await backend.uploadFile(reservation, from: source, by: user) { _ in }
        return (reservation, try await backend.finishFile(reservation.fileID, by: user))
    }

    private func payBalance(_ bookingID: UUID) async throws {
        let info = try await backend.preparePayment(bookingID: bookingID, kind: .balance, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    private func theBooking(_ id: UUID) async throws -> Booking {
        let all = try await backend.loadBookings(for: client)
        return try XCTUnwrap(all.first { $0.id == id })
    }

    private func files(_ id: UUID, as user: UUID) async throws -> BookingFiles {
        try await backend.loadBookingFiles(bookingID: id, for: user)
    }

    private func events(_ bookingID: UUID) async throws -> [Message.Event] {
        try await backend.loadMessages(bookingID: bookingID, since: nil, for: client).compactMap(\.event)
    }

    // MARK: Starting

    func testOnlyTheCreatorSideCanAddFilesAndOnlyOnceTheShootHasStarted() async throws {
        let signed = try await book()
        let id = signed.booking.id
        await expectError(.filesNotAllowed) { try await backend.reserveFile(request(id), by: creator.id) }
        clock.set(friday.addingTimeInterval(1800))
        await expectError(.bookingNotFound) { try await backend.reserveFile(request(id), by: client) }
        await expectError(.bookingNotFound) { try await backend.reserveFile(request(id), by: stranger) }
        await expectError(.bookingNotFound) { try await backend.reserveFile(request(UUID()), by: creator.id) }
        let reservation = try await backend.reserveFile(request(id), by: creator.id)
        XCTAssertEqual(reservation.deliveryKind, .delivery)
    }

    func testOnlyPhotosAndVideosAreTaken() async throws {
        let id = try await bookedAndShot()
        await expectError(.unsupportedFileType) { try await backend.reserveFile(request(id, name: "a.pdf", type: "application/pdf"), by: creator.id) }
        await expectError(.unsupportedFileType) { try await backend.reserveFile(request(id, kind: .video, type: "image/heic"), by: creator.id) }
        await expectError(.unsupportedFileType) { try await backend.reserveFile(request(id, kind: .photo, type: "video/mp4"), by: creator.id) }
        let files = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        XCTAssertTrue(files.deliveries.isEmpty, "A refusal leaves nothing behind, not even a draft")
    }

    func testAReservationIsOnePlaceForTwoObjectsAndCountsAtOnce() async throws {
        let id = try await bookedAndShot()
        let reservation = try await backend.reserveFile(request(id, name: "  ../a\u{1}b.heic ", type: "IMAGE/HEIC"), by: creator.id)
        let base = "\(creator.id.uuidString.lowercased())/\(id.uuidString.lowercased())/\(reservation.fileID.uuidString.lowercased())"
        XCTAssertEqual(reservation.originalPath, "\(base)/original")
        XCTAssertEqual(reservation.previewPath, "\(base)/preview")

        let files = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        let file = try XCTUnwrap(files.draft?.files.first)
        XCTAssertEqual(file.status, .uploading)
        XCTAssertEqual(file.name, ".. a b.heic")
        XCTAssertEqual(file.contentType, "image/heic")
        XCTAssertEqual(files.usedBytes, 3_400)
        XCTAssertTrue(files.canDeliverFiles)
        XCTAssertFalse(files.canSendRevision)
    }

    func testTheLimitsAreCheckedBeforeAnythingIsSent() async throws {
        let id = try await bookedAndShot()
        await expectError(.fileRefused(.empty)) { try await backend.reserveFile(request(id, original: 0), by: creator.id) }
        await expectError(.fileRefused(.tooLarge(maxBytes: 100_000_000))) {
            try await backend.reserveFile(request(id, original: 100_000_001), by: creator.id)
        }
        await expectError(.fileRefused(.previewTooLarge(maxBytes: 5_000_000))) {
            try await backend.reserveFile(request(id, preview: 5_000_001), by: creator.id)
        }
        await expectError(.fileRefused(.tooLarge(maxBytes: 4_000_000_000))) {
            try await backend.reserveFile(request(id, name: "a.mov", kind: .video, type: "video/quicktime", original: 4_000_000_001), by: creator.id)
        }
        let files = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        XCTAssertTrue(files.deliveries.isEmpty)
    }

    func testADeliveryHoldsOnlyAsManyFilesAsAreAllowed() async throws {
        var config = FilesConfig.standard
        config.maxFiles = 2
        try await makeBackend(config: config)
        let id = try await bookedAndShot()

        let first = try await addFile(id, name: "1.heic")
        _ = try await addFile(id, name: "2.heic")
        await expectError(.fileRefused(.tooManyFiles)) { try await backend.reserveFile(request(id, name: "3.heic"), by: creator.id) }
        try await backend.removeFile(first.reservation.fileID, by: creator.id)
        let third = try await backend.reserveFile(request(id, name: "3.heic"), by: creator.id)
        XCTAssertEqual(third.deliveryKind, .delivery, "A removed file makes room")
    }

    func testAFullAllowanceTurnsFilesAway() async throws {
        var config = FilesConfig.standard
        config.quotaGBIndividual = 1
        config.maxPhotoMB = 1000
        try await makeBackend(config: config)
        let id = try await bookedAndShot()
        try await addFile(id, name: "1.heic")

        // 1 GB is 1,000,000,000 bytes. One more file takes all that is left.
        let before = try await backend.fileStorageMeter(owner: creator.id, for: creator.id)
        XCTAssertEqual(before.allowanceBytes, 1_000_000_000)
        let room = before.remainingBytes
        let big = try await backend.reserveFile(request(id, name: "big.heic", original: room - 1_000, preview: 1_000), by: creator.id)
        let full = try await backend.fileStorageMeter(owner: creator.id, for: creator.id)
        XCTAssertEqual(full.usedBytes, 1_000_000_000)
        XCTAssertTrue(full.isNearlyFull)
        await expectError(.fileRefused(.storageFull(usedBytes: 1_000_000_000, allowanceBytes: 1_000_000_000))) {
            try await backend.reserveFile(request(id, name: "one-more.heic", original: 10, preview: 5), by: creator.id)
        }
        try await backend.removeFile(big.fileID, by: creator.id)
        _ = try await backend.reserveFile(request(id, name: "one-more.heic", original: 10, preview: 5), by: creator.id)
    }

    // MARK: Sending

    func testAFileIsAcceptedOnlyOnceItsBytesAreIn() async throws {
        let id = try await bookedAndShot()
        let reservation = try await backend.reserveFile(request(id), by: creator.id)
        await expectError(.uploadIncomplete) { try await backend.finishFile(reservation.fileID, by: creator.id) }
        await expectError(.bookingNotFound) { try await backend.finishFile(reservation.fileID, by: client) }
        await expectError(.bookingNotFound) { try await backend.finishFile(UUID(), by: creator.id) }

        let source = FileUploadSource(original: try bytesOnPhone("o", count: 2_500), preview: try bytesOnPhone("p", count: 300))
        try await backend.uploadFile(reservation, from: source, by: creator.id) { _ in }
        let outcome = try await backend.finishFile(reservation.fileID, by: creator.id)
        XCTAssertEqual(outcome, .accepted)

        let draft = try await files(id, as: creator.id)
        let file = try XCTUnwrap(draft.draft?.files.first)
        XCTAssertEqual(file.status, .ready)
        XCTAssertEqual(file.originalBytes, 2_500, "What storage really holds replaces what was reserved")
        XCTAssertEqual(file.previewBytes, 300)
        let again = try await backend.finishFile(reservation.fileID, by: creator.id)
        XCTAssertEqual(again, .accepted, "Finishing twice changes nothing")
    }

    func testAFileBiggerThanWasReservedIsRefusedAndDeleted() async throws {
        let id = try await bookedAndShot()
        let reservation = try await backend.reserveFile(request(id, original: 1_000, preview: 200), by: creator.id)
        let source = FileUploadSource(original: try bytesOnPhone("o", count: 9_000), preview: try bytesOnPhone("p", count: 150))
        try await backend.uploadFile(reservation, from: source, by: creator.id) { _ in }
        let outcome = try await backend.finishFile(reservation.fileID, by: creator.id)
        XCTAssertEqual(outcome, .refused(.tooLarge(maxBytes: 100_000_000)))
        let files = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        XCTAssertTrue(files.draft?.files.isEmpty ?? false, "It is gone from the draft")
        XCTAssertEqual(files.usedBytes, 0, "and its space is free")
        let objects = root.appendingPathComponent("delivered_files/\(reservation.originalPath)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: objects.path), "and so are its bytes")
    }

    // MARK: Delivering

    func testDeliveringNeedsFinishedFilesAndStartsThirtyDays() async throws {
        let id = try await bookedAndShot()
        await expectError(.nothingToDeliver) { try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id) }
        let pending = try await backend.reserveFile(request(id), by: creator.id)
        await expectError(.filesNotReady) { try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id) }
        try await backend.removeFile(pending.fileID, by: creator.id)
        await expectError(.nothingToDeliver) { try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id) }

        _ = try await addFile(id, name: "a.heic")
        _ = try await addFile(id, name: "clip.mov", kind: .video, type: "video/quicktime", original: 5_000, preview: 800)
        await expectError(.bookingNotFound) { try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: client) }
        await expectError(.deliveryNoteTooLong) {
            try await backend.deliverFiles(bookingID: id, title: nil, note: String(repeating: "n", count: 501), by: creator.id)
        }
        let delivered = try await backend.deliverFiles(bookingID: id, title: nil, note: "  Enjoy!  ", by: creator.id)

        let first = try XCTUnwrap(delivered.firstDelivery)
        XCTAssertEqual(first.state, .delivered)
        XCTAssertEqual(first.note, "Enjoy!")
        XCTAssertEqual(first.deliveredAt, clock.now)
        XCTAssertEqual(first.expiresAt, clock.now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(first.countText, "1 photo and 1 video")
        XCTAssertFalse(delivered.canDeliverFiles)
        XCTAssertFalse(delivered.canSendRevision, "A balance is owed")
        await expectError(.nothingToDeliver) { try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id) }
    }

    func testDeliveringByFilesMarksTheBookingReceivedAndMakesTheBalancePayable() async throws {
        let id = try await bookedAndShot()
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: id, kind: .balance, by: client) }
        try await addFile(id)
        _ = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)

        let booking = try await theBooking(id)
        XCTAssertEqual(booking.deliveredAt, clock.now)
        XCTAssertEqual(booking.receiptConfirmedAt, clock.now)
        XCTAssertNil(booking.deliveryURL)
        XCTAssertEqual(booking.status, .confirmed, "A balance is still owed")
        let seen = try await events(id)
        XCTAssertTrue(seen.contains(.filesDelivered))
        XCTAssertFalse(seen.contains(.receiptConfirmed), "Nobody is told the client confirmed anything")
        XCTAssertFalse(seen.contains(.deliveryShared))

        try await payBalance(id)
        let paid = try await theBooking(id)
        XCTAssertEqual(paid.status, .completed)
    }

    func testABookingThatOwesNothingIsCompleteOnceItsFilesAreDelivered() async throws {
        try await makeBackend(deposit: 200_000)
        let id = try await bookedAndShot()
        try await addFile(id)
        let delivered = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)
        XCTAssertEqual(delivered.owedCents, 0)
        let booking = try await theBooking(id)
        XCTAssertEqual(booking.status, .completed)
        let source = try await backend.fileSource(
            for: try XCTUnwrap(delivered.firstDelivery?.files.first), part: .original, bookingID: id, for: client
        )
        XCTAssertFalse(source.isRemote, "With nothing owed the original opens at once")
    }

    // MARK: What the client can open

    func testPreviewsOpenAtOnceAndOriginalsWaitForTheBalance() async throws {
        let id = try await bookedAndShot()
        try await addFile(id)
        _ = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)

        let seen = try await backend.loadBookingFiles(bookingID: id, for: client)
        let delivery = try XCTUnwrap(seen.firstDelivery)
        let file = try XCTUnwrap(delivery.files.first)
        XCTAssertEqual(seen.owedCents, 150_000)
        XCTAssertFalse(delivery.originalsOpen)
        XCTAssertNil(file.originalPath, "A locked original has no address to give out")
        XCTAssertNil(seen.usedBytes, "The client is told nothing about the creator's storage")

        let preview = try await backend.fileSource(for: file, part: .preview, bookingID: id, for: client)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.url.path))
        await expectError(.originalsLocked) { try await backend.fileSource(for: file, part: .original, bookingID: id, for: client) }
        await expectError(.originalsLocked) { try await backend.markFileSaved(file.id, by: client) }
        await expectError(.bookingNotFound) { try await backend.fileSource(for: file, part: .preview, bookingID: id, for: stranger) }

        try await payBalance(id)
        let unlocked = try await backend.loadBookingFiles(bookingID: id, for: client)
        let openFile = try XCTUnwrap(unlocked.firstDelivery?.files.first)
        XCTAssertTrue(unlocked.firstDelivery?.originalsOpen ?? false)
        XCTAssertNotNil(openFile.originalPath)
        let original = try await backend.fileSource(for: openFile, part: .original, bookingID: id, for: client)
        XCTAssertEqual(try Data(contentsOf: original.url).count, 3_000)

        let count = try await backend.markFileSaved(file.id, by: client)
        XCTAssertEqual(count, FileSaveCount(saved: 1, total: 1))
        let afterFirst = try await files(id, as: client)
        let firstTime = try XCTUnwrap(afterFirst.firstDelivery?.files.first?.savedAt)
        clock.advance(by: 3_600)
        _ = try await backend.markFileSaved(file.id, by: client)
        let afterSecond = try await files(id, as: client)
        let secondTime = try XCTUnwrap(afterSecond.firstDelivery?.files.first?.savedAt)
        XCTAssertEqual(firstTime, secondTime, "Saving again keeps the first time")
    }

    func testTheCreatorSideSeesADraftAndTheClientDoesNot() async throws {
        let id = try await bookedAndShot()
        let added = try await addFile(id)
        let mine = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        XCTAssertEqual(mine.draft?.files.count, 1)
        XCTAssertNotNil(mine.draft?.files.first?.originalPath)
        let theirs = try await backend.loadBookingFiles(bookingID: id, for: client)
        XCTAssertTrue(theirs.deliveries.isEmpty)
        await expectError(.bookingNotFound) { try await backend.loadBookingFiles(bookingID: id, for: stranger) }
        let file = try XCTUnwrap(mine.draft?.files.first)
        await expectError(.fileUnavailable) { try await backend.fileSource(for: file, part: .preview, bookingID: id, for: client) }
        XCTAssertEqual(added.outcome, .accepted)
    }

    // MARK: Revisions

    func testARevisionIsFreeOnceTheBalanceIsPaidAndNeverBefore() async throws {
        let id = try await bookedAndShot()
        try await addFile(id)
        _ = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)
        await expectError(.revisionNotAllowed) { try await backend.reserveFile(request(id), by: creator.id) }

        try await payBalance(id)
        let before = try await files(id, as: creator.id)
        XCTAssertTrue(before.canSendRevision)
        XCTAssertFalse(before.canDeliverFiles)

        let revised = try await addFile(id, name: "fixed.heic")
        XCTAssertEqual(revised.reservation.deliveryKind, .revision)
        let sent = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)
        let revision = try XCTUnwrap(sent.deliveries.first { $0.sequence == 1 })
        XCTAssertEqual(revision.kind, .revision)
        XCTAssertEqual(revision.title, "Revision 1")
        XCTAssertEqual(revision.heading, "Revision 1")
        XCTAssertEqual(sent.firstDelivery?.state, .delivered, "The first delivery stays as it was")

        _ = try await addFile(id, name: "again.heic")
        await expectError(.fileTitleTooLong) { try await backend.deliverFiles(bookingID: id, title: String(repeating: "t", count: 81), note: nil, by: creator.id) }
        let second = try await backend.deliverFiles(bookingID: id, title: "Final colour", note: nil, by: creator.id)
        XCTAssertEqual(second.deliveries.first { $0.sequence == 2 }?.title, "Final colour")
        XCTAssertEqual(second.delivered.map(\.sequence), [2, 1, 0], "Newest first for the client")
        let seen = try await events(id)
        XCTAssertEqual(seen.filter { $0 == .filesDelivered }.count, 3, "Each delivery is announced once")
    }

    // MARK: One way for the first delivery

    func testFilesCannotFollowALinkOrAPaidBalance() async throws {
        let id = try await bookedAndShot()
        _ = try await backend.shareDelivery(bookingID: id, link: "https://files.example.com/final", note: "", by: creator.id)
        await expectError(.firstDeliveryLocked) { try await backend.reserveFile(request(id), by: creator.id) }
    }

    // MARK: Time passing

    func testADeliveryEndsAfterThirtyDaysAndItsFilesAreDeleted() async throws {
        let id = try await bookedAndShot()
        let added = try await addFile(id)
        try await addFile(id, name: "2.heic")
        let delivered = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)
        let firstFile = try XCTUnwrap(delivered.firstDelivery?.files.first)
        try await payBalance(id)
        _ = try await backend.markFileSaved(firstFile.id, by: client)

        clock.advance(by: 30 * 86_400 - 60)
        let still = try await backend.loadBookingFiles(bookingID: id, for: client)
        XCTAssertEqual(still.firstDelivery?.state, .delivered)
        XCTAssertEqual(still.firstDelivery?.daysLeft(at: clock.now), 1)

        clock.advance(by: 120)
        let ended = try await backend.loadBookingFiles(bookingID: id, for: client)
        let delivery = try XCTUnwrap(ended.firstDelivery)
        XCTAssertEqual(delivery.state, .expired)
        XCTAssertTrue(delivery.files.allSatisfy { $0.status == .expired && $0.originalPath == nil })
        XCTAssertFalse(delivery.originalsOpen)
        await expectError(.fileUnavailable) { try await backend.fileSource(for: firstFile, part: .preview, bookingID: id, for: client) }
        await expectError(.fileUnavailable) { try await backend.fileSource(for: firstFile, part: .preview, bookingID: id, for: creator.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("delivered_files/\(added.reservation.originalPath)").path))

        let line = try await backend.loadMessages(bookingID: id, since: nil, for: creator.id).last { $0.event == .filesExpired }
        XCTAssertEqual(line?.data.saved, 1)
        XCTAssertEqual(line?.data.total, 2)
        let used = try await backend.fileStorageMeter(owner: creator.id, for: creator.id).usedBytes
        XCTAssertEqual(used, 0, "Their space is free")

        _ = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        let lines = try await events(id).filter { $0 == .filesExpired }
        XCTAssertEqual(lines.count, 1, "It ends once")

        let creatorView = try await backend.loadBookingFiles(bookingID: id, for: creator.id)
        XCTAssertTrue(creatorView.canSendRevision, "Nothing is owed, so a revision can still be sent")
    }

    func testAnUploadNobodyFinishesGivesItsSpaceBackAfterADay() async throws {
        let id = try await bookedAndShot()
        let stuck = try await backend.reserveFile(request(id), by: creator.id)
        let soon = try await files(id, as: creator.id)
        XCTAssertEqual(soon.usedBytes, 3_400)
        clock.advance(by: 25 * 3_600)
        let afterADay = try await files(id, as: creator.id)
        XCTAssertEqual(afterADay.draft?.files.count ?? 0, 0)
        XCTAssertEqual(afterADay.usedBytes, 0)
        await expectError(.bookingNotFound) { try await backend.finishFile(stuck.fileID, by: creator.id) }
    }

    func testADraftNobodyDeliversIsRemovedAfterAWeek() async throws {
        let id = try await bookedAndShot()
        try await addFile(id)
        clock.advance(by: 6 * 86_400)
        let early = try await files(id, as: creator.id)
        XCTAssertEqual(early.draft?.files.count, 1, "Still there after six days")
        clock.advance(by: 2 * 86_400)
        let later = try await files(id, as: creator.id)
        XCTAssertTrue(later.deliveries.isEmpty)
        XCTAssertEqual(later.usedBytes, 0)
    }

    // MARK: Removing, reporting, storage

    func testOnlyTheCreatorSideRemovesAFileAndItsSpaceComesBack() async throws {
        let id = try await bookedAndShot()
        let added = try await addFile(id)
        await expectError(.bookingNotFound) { try await backend.removeFile(added.reservation.fileID, by: client) }
        await expectError(.bookingNotFound) { try await backend.removeFile(added.reservation.fileID, by: stranger) }
        let before = try await backend.fileStorageMeter(owner: creator.id, for: creator.id)
        XCTAssertEqual(before.usedBytes, 3_400)
        XCTAssertEqual(before.allowanceBytes, 50 * FilesConfig.gigabyte)
        try await backend.removeFile(added.reservation.fileID, by: creator.id)
        let after = try await backend.fileStorageMeter(owner: creator.id, for: creator.id)
        XCTAssertEqual(after.usedBytes, 0)
        await expectError(.bookingNotFound) { try await backend.removeFile(added.reservation.fileID, by: creator.id) }
        await expectError(.notFound) { try await backend.fileStorageMeter(owner: creator.id, for: stranger) }
    }

    func testEitherPersonOnTheBookingCanReportAFileAndNobodyElse() async throws {
        let id = try await bookedAndShot()
        let added = try await addFile(id)
        _ = try await backend.deliverFiles(bookingID: id, title: nil, note: nil, by: creator.id)
        try await backend.reportFile(added.reservation.fileID, reason: "  This isn't my wedding\n", by: client)
        try await backend.reportFile(added.reservation.fileID, reason: "", by: creator.id)
        await expectError(.bookingNotFound) { try await backend.reportFile(added.reservation.fileID, reason: "spam", by: stranger) }
        await expectError(.bookingNotFound) { try await backend.reportFile(UUID(), reason: "spam", by: client) }
    }
}

// MARK: - The server's answers

/// The Supabase backend against what the database really returns. `Fixtures/file_rows.json` is written by
/// `supabase/tests/file_rules.py --dump`, and that script fails if the database stops matching it.
final class FileRowDecodingTests: XCTestCase {
    private var rows: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "file_rows", withExtension: "json"), "file_rows.json is missing from the test bundle")
        rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Postgres writes microseconds; Foundation's ISO 8601 parser is only promised milliseconds, so trim them.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) { return date }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }

    private func load<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        let value = try XCTUnwrap(rows[key], "\(key) is missing from file_rows.json")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder().decode(type, from: data)
    }

    func testTheNumbersTheDatabaseGives() throws {
        let row: SupabaseBackend.FilesConfigRow = try load("config")
        XCTAssertEqual(row.config, FilesConfig.standard, "The database's defaults and the app's agree")
    }

    func testWhatTheCreatorSees() throws {
        let files = try load("creator_list", SupabaseBackend.BookingFilesRow.self).files()
        XCTAssertEqual(files.owedCents, 0)
        XCTAssertEqual(files.deliveries.map(\.sequence), [0, 1])
        let first = try XCTUnwrap(files.firstDelivery)
        XCTAssertEqual(first.state, .delivered)
        XCTAssertEqual(first.kind, .delivery)
        XCTAssertEqual(first.files.map(\.kind), [.photo, .video])
        XCTAssertEqual(first.files.last?.durationText, "0:13")
        XCTAssertEqual(first.photoCount, 1)
        XCTAssertEqual(first.videoCount, 1)
        XCTAssertNotNil(first.expiresAt)
        let draft = try XCTUnwrap(files.draft)
        XCTAssertEqual(draft.kind, .revision)
        XCTAssertEqual(draft.state, .draft)
        XCTAssertNotNil(files.meter, "The creator side is told the allowance")
        XCTAssertEqual(files.allowanceBytes, 50 * FilesConfig.gigabyte)
        XCTAssertFalse(files.canDeliverFiles)
        XCTAssertTrue(files.canSendRevision)
    }

    func testWhatTheClientSees() throws {
        let files = try load("client_list", SupabaseBackend.BookingFilesRow.self).files()
        XCTAssertNil(files.meter, "The client is told nothing about the creator's storage")
        XCTAssertNil(files.draft, "or about work in progress")
        let first = try XCTUnwrap(files.firstDelivery)
        XCTAssertTrue(first.originalsOpen)
        XCTAssertTrue(first.files.allSatisfy { $0.originalPath != nil })
        XCTAssertEqual(first.files.first?.isSaved, true)
        XCTAssertEqual(first.savedCount, 1)
        XCTAssertEqual(first.unsavedCount, 1)
    }

    func testAReservationAFinishedFileARefusalAndTheAllowance() throws {
        let reservation = try load("reserve", SupabaseBackend.FileReservationRow.self).reservation()
        XCTAssertEqual(reservation.deliveryKind, .revision)
        XCTAssertTrue(reservation.originalPath.hasSuffix("/original"))
        XCTAssertTrue(reservation.previewPath.hasSuffix("/preview"))
        XCTAssertEqual(reservation.originalPath, reservation.originalPath.lowercased())

        XCTAssertTrue(try load("finalize", SupabaseBackend.FileFinalizationRow.self).accepted)
        let refusal = try load("refusal", SupabaseBackend.FileFinalizationRow.self)
        XCTAssertFalse(refusal.accepted)
        XCTAssertEqual(refusal.refusal, "file_too_large")
        XCTAssertEqual(refusal.kind, "photo")
        XCTAssertEqual(SupabaseBackend.refusal(forToken: refusal.refusal ?? "", kind: .photo, config: .standard), .tooLarge(maxBytes: 100_000_000))

        let usage = try load("usage", SupabaseBackend.FileUsageRow.self)
        XCTAssertEqual(usage.allowanceBytes, 50_000_000_000)
        let saved = try load("saved", SupabaseBackend.FileSaveCountRow.self)
        XCTAssertEqual(saved.saved, 2)
        XCTAssertEqual(saved.total, 2)
    }
}

// MARK: - Errors

final class FileErrorMappingTests: XCTestCase {
    private struct Said: Error, CustomStringConvertible {
        var description: String
    }

    private func map(_ token: String, kind: FileKind = .photo) -> SlateError? {
        SupabaseBackend.mapFileError(Said(description: "PostgrestError: \(token)"), kind: kind, config: .standard) as? SlateError
    }

    func testTheDatabasesRefusalsBecomeWords() {
        XCTAssertEqual(map("files_not_allowed"), .filesNotAllowed)
        XCTAssertEqual(map("unsupported_type"), .unsupportedFileType)
        XCTAssertEqual(map("delivery_locked"), .firstDeliveryLocked)
        XCTAssertEqual(map("revision_not_allowed"), .revisionNotAllowed)
        XCTAssertEqual(map("upload_incomplete"), .uploadIncomplete)
        XCTAssertEqual(map("nothing_to_deliver"), .nothingToDeliver)
        XCTAssertEqual(map("files_not_ready"), .filesNotReady)
        XCTAssertEqual(map("originals_locked"), .originalsLocked)
        XCTAssertEqual(map("title_too_long"), .fileTitleTooLong)
        XCTAssertEqual(map("too_many_files"), .fileRefused(.tooManyFiles))
        XCTAssertEqual(map("file_empty"), .fileRefused(.empty))
        XCTAssertEqual(map("preview_too_large"), .fileRefused(.previewTooLarge(maxBytes: 5_000_000)))
        XCTAssertEqual(map("storage_full"), .fileRefused(.storageFull(usedBytes: 0, allowanceBytes: 0)))
    }

    func testTheLimitDependsOnWhetherItIsAPhotoOrAVideo() {
        XCTAssertEqual(map("file_too_large", kind: .photo), .fileRefused(.tooLarge(maxBytes: 100_000_000)))
        XCTAssertEqual(map("file_too_large", kind: .video), .fileRefused(.tooLarge(maxBytes: 4_000_000_000)))
        XCTAssertEqual(map("preview_too_large", kind: .video), .fileRefused(.previewTooLarge(maxBytes: 150_000_000)))
    }

    func testTokensSharedWithBookingsStillMeanWhatTheyDid() {
        XCTAssertEqual(map("not_found"), .bookingNotFound)
        XCTAssertEqual(map("not_signed_in"), .notSignedIn)
        XCTAssertEqual(map("note_too_long"), .deliveryNoteTooLong)
    }

    func testEveryTokenTheDatabaseRaisesIsMapped() throws {
        // The migration is the list of what can be raised; none may fall through to a message nobody can read.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/migrations/20261102000000_slate_files.sql")
        guard let sql = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("The migrations aren't next to the tests here.") }
        let regex = try NSRegularExpression(pattern: #"raise exception '([a-z_]+)'"#)
        let tokens = Set(regex.matches(in: sql, range: NSRange(sql.startIndex..., in: sql)).compactMap { match -> String? in
            Range(match.range(at: 1), in: sql).map { String(sql[$0]) }
        })
        XCTAssertGreaterThan(tokens.count, 10)
        for token in tokens {
            let mapped = map(token)
            XCTAssertNotNil(mapped, "\(token) isn't mapped to a SlateError")
        }
    }

    func testEveryFileErrorHasWordsForAPerson() {
        let errors: [SlateError] = [
            .filesNotAllowed, .unsupportedFileType, .firstDeliveryLocked, .revisionNotAllowed, .uploadIncomplete, .nothingToDeliver,
            .filesNotReady, .originalsLocked, .fileTitleTooLong, .fileUnavailable,
            .fileRefused(.tooManyFiles), .fileRefused(.empty), .fileRefused(.tooLarge(maxBytes: 100_000_000)),
            .fileRefused(.previewTooLarge(maxBytes: 5_000_000)), .fileRefused(.storageFull(usedBytes: 24_000_000_000, allowanceBytes: 25_000_000_000)),
            .fileRefused(.storageFull(usedBytes: 0, allowanceBytes: 0)),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
        XCTAssertTrue(SlateError.fileRefused(.storageFull(usedBytes: 24_000_000_000, allowanceBytes: 25_000_000_000)).errorDescription?.contains("25 GB") == true)
    }
}

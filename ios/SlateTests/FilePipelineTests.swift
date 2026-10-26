import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Slate

// MARK: - Stand-ins for the slow parts

/// Makes a small "preview" without decoding anything, and can be told to fail a file once.
final class FakePreparer: FilePreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<String> = []
    private var seen: [(name: String, style: PreviewStyle)] = []

    func failOnce(_ name: String) {
        lock.lock()
        failing.insert(name)
        lock.unlock()
    }

    var styles: [PreviewStyle] {
        lock.lock()
        defer { lock.unlock() }
        return seen.map(\.style)
    }

    func prepare(_ pick: PickedFile, kind: FileKind, style: PreviewStyle) async throws -> PreparedFile {
        lock.lock()
        seen.append((pick.name, style))
        let fails = failing.remove(pick.name) != nil
        lock.unlock()
        if fails { throw SlateError.mediaUnreadable }
        guard let type = pick.resolvedContentType else { throw SlateError.unsupportedFileType }
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("fake-preview-\(UUID().uuidString).jpg")
        try Data(repeating: 1, count: 300).write(to: preview)
        let size = ((try? FileManager.default.attributesOfItem(atPath: pick.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return PreparedFile(
            name: pick.name, kind: kind, contentType: type, originalURL: pick.url, previewURL: preview, width: 4000, height: 3000,
            durationSeconds: kind == .video ? 5 : nil, originalBytes: size, previewBytes: 300
        )
    }
}

/// "Downloads" by copying, and "saves to Photos" by writing the name down. Can be told to fail a save.
final class FakeTransfer: FileTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private var failAt: Int?

    var saved: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func failSave(number: Int) {
        lock.lock()
        failAt = number
        lock.unlock()
    }

    func download(_ source: FileSource, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source.url, to: destination)
        progress(1)
        return destination
    }

    func saveToPhotos(_ url: URL, kind: FileKind) async throws {
        lock.lock()
        defer { lock.unlock() }
        if let failAt, names.count + 1 == failAt { throw SlateError.photosAccessDenied }
        names.append(url.lastPathComponent)
    }
}

// MARK: - The app model

/// Adding, delivering and saving files through `AppModel`, against the on-device backend. The demo person books their own
/// package, so they are both sides of it; the rules for each side are tested in `FileBackendTests`.
@MainActor
final class FileModelTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var model: AppModel!
    private var preparer: FakePreparer!
    private var transfer: FakeTransfer!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-filemodel-\(UUID().uuidString)")
        scratch = root.appendingPathComponent("phone", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        clock = ManualClock(Date())
        let clock = self.clock!
        backend = LocalBackend(root: root, clock: { clock.now })
        preparer = FakePreparer()
        transfer = FakeTransfer()
        model = AppModel(backend: backend, authorizer: ScriptedAuthorizer(), widget: RecordingWidgetPublisher(), filePreparer: preparer, fileTransfer: transfer)
        model.clock = { clock.now }
        await model.signInAsDemo()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// The demo person's own booking, with the shoot over.
    private func shotBooking() async throws -> Booking {
        let userID = try XCTUnwrap(model.session?.userID)
        _ = try await backend.saveProfile(CreatorProfile(
            id: userID, handle: "demo-studio", displayName: "Demo Studio", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: userID)
        let template = try await ContractFixtures.equip(backend, creatorID: userID)
        let own = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: userID, name: "My session", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: [], turnaroundDays: 7,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id
        ))[0]
        let loaded = try await backend.loadProfile(for: userID)
        let screen = BookingModel(creator: try XCTUnwrap(loaded), package: own, signerName: "Demo Person")
        await screen.load(using: model)
        screen.select(screen.days[2].slots.first!)
        let ok = await screen.submit(using: model)
        XCTAssertTrue(ok)
        let booked = try XCTUnwrap(screen.confirmed)
        clock.set(booked.endAt.addingTimeInterval(3600))
        return booked
    }

    private func pick(_ name: String, bytes: Int = 2_000) throws -> PickedFile {
        let url = scratch.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(repeating: 9, count: bytes).write(to: url)
        return PickedFile(url: url, name: name, contentType: FileNames.contentType(forExtension: (name as NSString).pathExtension))
    }

    func testFilesAreMadeSentAndListed() async throws {
        let booking = try await shotBooking()
        await model.addFiles([try pick("a.heic"), try pick("b.mov", bytes: 5_000)], to: booking)

        XCTAssertTrue(model.uploads(for: booking.id).isEmpty, "Finished files leave the list")
        let draft = try XCTUnwrap(model.files(for: booking.id)?.draft)
        XCTAssertEqual(draft.readyFiles.count, 2)
        XCTAssertEqual(draft.countText, "1 photo and 1 video")
        XCTAssertEqual(preparer.styles, [.watermarked, .watermarked], "The first delivery's copy is watermarked")
        XCTAssertEqual(model.storageMeter?.usedBytes, 2_000 + 300 + 5_000 + 300)
        XCTAssertNil(model.alert)
    }

    func testAFileThatCannotBeUsedShowsWhyAndCanBeDismissed() async throws {
        let booking = try await shotBooking()
        let bad = try pick("notes.pdf")
        await model.addFiles([bad], to: booking)

        let item = try XCTUnwrap(model.uploads(for: booking.id).first)
        XCTAssertTrue(item.isFailed)
        XCTAssertEqual(item.failureMessage, SlateError.unsupportedFileType.errorDescription)
        await model.dismissUpload(item.id)
        XCTAssertTrue(model.uploads(for: booking.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.url.path), "Its copy on the phone goes with it")
    }

    func testAFileThatFailsCanBeTriedAgainAndGivesNothingAwayMeanwhile() async throws {
        let booking = try await shotBooking()
        preparer.failOnce("flaky.heic")
        await model.addFiles([try pick("flaky.heic")], to: booking)
        let failed = try XCTUnwrap(model.uploads(for: booking.id).first)
        XCTAssertTrue(failed.isFailed)
        XCTAssertEqual(model.files(for: booking.id)?.draft?.readyFiles.count ?? 0, 0)

        await model.retryUpload(failed.id)
        XCTAssertTrue(model.uploads(for: booking.id).isEmpty)
        XCTAssertEqual(model.files(for: booking.id)?.draft?.readyFiles.count, 1)
    }

    func testDeliveringMarksTheBookingDeliveredAndHidesTheLinkOption() async throws {
        let booking = try await shotBooking()
        XCTAssertFalse(model.isHostedDelivery(booking))
        await model.addFiles([try pick("a.heic")], to: booking)
        let delivered = await model.deliverFiles(for: booking, title: nil, note: "Enjoy")
        XCTAssertTrue(delivered)

        let after = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertTrue(model.isHostedDelivery(after))
        XCTAssertNotNil(after.receiptConfirmedAt)
        XCTAssertEqual(model.files(for: booking.id)?.firstDelivery?.state, .delivered)
        XCTAssertNil(model.files(for: booking.id)?.draft)
        XCTAssertNil(model.alert)
    }

    func testARevisionAfterPaymentIsMadeWithTheSmallPictureOnly() async throws {
        let booking = try await shotBooking()
        await model.addFiles([try pick("a.heic")], to: booking)
        _ = await model.deliverFiles(for: booking, title: nil, note: nil)

        // Nothing is owed yet? A balance is: a revision is refused until it is paid.
        await model.addFiles([try pick("early.heic")], to: booking)
        XCTAssertEqual(model.uploads(for: booking.id).first?.failureMessage, SlateError.revisionNotAllowed.errorDescription)
        if let item = model.uploads(for: booking.id).first { await model.dismissUpload(item.id) }

        let outcome = await model.pay(.balance, for: try XCTUnwrap(model.bookings.first { $0.id == booking.id }))
        XCTAssertEqual(outcome, .confirmed)
        await model.loadFiles(for: booking.id)
        XCTAssertEqual(model.files(for: booking.id)?.canSendRevision, true)

        await model.addFiles([try pick("fixed.heic")], to: booking)
        XCTAssertEqual(preparer.styles.last, .thumbnail, "A revision is never locked, so it needs no watermark")
        let draft = try XCTUnwrap(model.files(for: booking.id)?.draft)
        XCTAssertEqual(draft.kind, .revision)
        let sent = await model.deliverFiles(for: booking, title: "Colour fixes", note: nil)
        XCTAssertTrue(sent)
        XCTAssertEqual(model.files(for: booking.id)?.delivered.first?.title, "Colour fixes")
    }

    func testSavingEverythingCountsEachFileAsItIsSaved() async throws {
        let booking = try await shotBooking()
        await model.addFiles([try pick("a.heic"), try pick("b.heic"), try pick("c.heic")], to: booking)
        _ = await model.deliverFiles(for: booking, title: nil, note: nil)
        let delivery = try XCTUnwrap(model.files(for: booking.id)?.firstDelivery)

        await model.saveAll(delivery, bookingID: booking.id)
        XCTAssertEqual(transfer.saved.count, 3)
        XCTAssertTrue(model.fileSaveRuns.isEmpty, "The run is over")
        let after = try XCTUnwrap(model.files(for: booking.id)?.firstDelivery)
        XCTAssertEqual(after.savedCount, 3)
        XCTAssertEqual(after.unsavedCount, 0)
        XCTAssertNil(model.alert)

        await model.saveAll(after, bookingID: booking.id)
        XCTAssertEqual(transfer.saved.count, 3, "Nothing left to save, so nothing is saved twice")
    }

    func testSavingStopsAtAFailureAndSaysWhy() async throws {
        let booking = try await shotBooking()
        await model.addFiles([try pick("a.heic"), try pick("b.heic"), try pick("c.heic")], to: booking)
        _ = await model.deliverFiles(for: booking, title: nil, note: nil)
        let delivery = try XCTUnwrap(model.files(for: booking.id)?.firstDelivery)

        transfer.failSave(number: 2)
        await model.saveAll(delivery, bookingID: booking.id)
        XCTAssertEqual(transfer.saved.count, 1)
        XCTAssertEqual(model.files(for: booking.id)?.firstDelivery?.savedCount, 1)
        XCTAssertEqual(model.alert?.message, SlateError.photosAccessDenied.errorDescription)
        XCTAssertTrue(model.fileSaveRuns.isEmpty)
    }

    func testRemovingAFileFreesItsSpaceAndSigningOutForgetsEverything() async throws {
        let booking = try await shotBooking()
        await model.addFiles([try pick("a.heic")], to: booking)
        let file = try XCTUnwrap(model.files(for: booking.id)?.draft?.readyFiles.first)
        XCTAssertEqual(model.storageMeter?.usedBytes, 2_300)

        let removed = await model.removeFile(file, from: booking)
        XCTAssertTrue(removed)
        XCTAssertEqual(model.storageMeter?.usedBytes, 0)
        XCTAssertEqual(model.files(for: booking.id)?.draft?.readyFiles.count, 0)

        await model.signOut()
        XCTAssertTrue(model.bookingFiles.isEmpty)
        XCTAssertNil(model.storageMeter)
        XCTAssertTrue(model.fileUploads.isEmpty)
    }
}

// MARK: - The real preview maker

final class PreviewMakerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("slate-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A JPEG of one colour, optionally marked as turned a quarter (EXIF orientation 6).
    private func photo(width: Int, height: Int, gray: CGFloat = 0, orientation: Int? = nil) throws -> PickedFile {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor(white: gray, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return PickedFile(url: url, name: "IMG_0001.JPG", contentType: "image/jpeg")
    }

    private func longEdge(of url: URL) throws -> Int {
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        return Int(max(image.size.width * image.scale, image.size.height * image.scale))
    }

    /// The brightest pixel in the picture, 0 to 255.
    private func brightest(_ url: URL) throws -> Int {
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var best = 0
            for index in stride(from: 0, to: buffer.count, by: 4) { best = max(best, Int(buffer[index])) }
            return best
        }
    }

    func testAPhotoPreviewIsReducedMarkedAndSmall() async throws {
        let original = try photo(width: 3000, height: 2000)
        let prepared = try await PreviewMaker().prepare(original, kind: .photo, style: .watermarked)
        XCTAssertEqual(prepared.kind, .photo)
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertEqual(prepared.width, 3000)
        XCTAssertEqual(prepared.height, 2000)
        XCTAssertEqual(prepared.originalURL, original.url, "The original is sent as it is")
        XCTAssertEqual(try longEdge(of: prepared.previewURL), 1600)
        XCTAssertLessThanOrEqual(prepared.previewBytes, FileRules.maxPreviewBytes(.photo))
        XCTAssertGreaterThan(prepared.previewBytes, 0)
        XCTAssertGreaterThan(try brightest(prepared.previewURL), 60, "The watermark is drawn across a black picture")
    }

    func testARevisionsPictureIsSmallAndHasNoWatermark() async throws {
        let original = try photo(width: 3000, height: 2000)
        let prepared = try await PreviewMaker().prepare(original, kind: .photo, style: .thumbnail)
        XCTAssertEqual(try longEdge(of: prepared.previewURL), 480)
        XCTAssertLessThan(try brightest(prepared.previewURL), 25, "Nothing is drawn over it")
    }

    func testAPictureTurnedOnItsSideIsMeasuredAsPeopleSeeIt() async throws {
        let original = try photo(width: 4000, height: 3000, orientation: 6)
        let prepared = try await PreviewMaker().prepare(original, kind: .photo, style: .thumbnail)
        XCTAssertEqual(prepared.width, 3000)
        XCTAssertEqual(prepared.height, 4000)
    }

    func testThingsItCannotUseAreRefused() async throws {
        let empty = folder.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        do {
            _ = try await PreviewMaker().prepare(PickedFile(url: empty, name: "empty.jpg", contentType: "image/jpeg"), kind: .photo, style: .thumbnail)
            XCTFail("An empty file should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .fileRefused(.empty))
        }
        let pdf = folder.appendingPathComponent("notes.pdf")
        try Data(repeating: 1, count: 10).write(to: pdf)
        do {
            _ = try await PreviewMaker().prepare(PickedFile(url: pdf, name: "notes.pdf", contentType: nil), kind: .photo, style: .thumbnail)
            XCTFail("A PDF should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .unsupportedFileType)
        }
        let junk = folder.appendingPathComponent("junk.jpg")
        try Data(repeating: 1, count: 100).write(to: junk)
        do {
            _ = try await PreviewMaker().prepare(PickedFile(url: junk, name: "junk.jpg", contentType: "image/jpeg"), kind: .photo, style: .thumbnail)
            XCTFail("Bytes that aren't a picture should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .mediaUnreadable)
        }
    }

    // MARK: Video

    /// A one-second clip of changing grey, 320 by 240.
    private func clip() async throws -> PickedFile {
        let url = folder.appendingPathComponent("\(UUID().uuidString).mp4")
        let width = 320, height = 240, fps = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<fps {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 + frame * 15), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return PickedFile(url: url, name: "clip.mp4", contentType: "video/mp4")
    }

    func testAVideosRevisionPictureIsAStillFromIt() async throws {
        let original = try await clip()
        let prepared = try await PreviewMaker().prepare(original, kind: .video, style: .thumbnail)
        XCTAssertEqual(prepared.kind, .video)
        XCTAssertEqual(prepared.width, 320)
        XCTAssertEqual(prepared.height, 240)
        XCTAssertEqual(try XCTUnwrap(prepared.durationSeconds), 1, accuracy: 0.3)
        XCTAssertEqual(prepared.previewURL.pathExtension, "jpg")
        XCTAssertGreaterThan(prepared.previewBytes, 0)
    }

    func testAVideosFirstDeliveryCopyIsAReducedMarkedVideo() async throws {
        let original = try await clip()
        let prepared = try await PreviewMaker().prepare(original, kind: .video, style: .watermarked)
        XCTAssertEqual(prepared.previewURL.pathExtension, "mp4")
        XCTAssertGreaterThan(prepared.previewBytes, 0)
        XCTAssertLessThanOrEqual(prepared.previewBytes, FileRules.maxPreviewBytes(.video))
        let asset = AVURLAsset(url: prepared.previewURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.3)
    }
}

// MARK: - Small helpers

final class FileHelperTests: XCTestCase {
    func testWhatAPickedFileIsComesFromWhatTheSystemSaidOrItsEnding() {
        let url = URL(fileURLWithPath: "/tmp/IMG_0042.HEIC")
        XCTAssertEqual(PickedFile(url: url, name: "IMG_0042.HEIC", contentType: "image/heic").kind, .photo)
        XCTAssertEqual(PickedFile(url: url, name: "IMG_0042.HEIC", contentType: nil).resolvedContentType, "image/heic")
        XCTAssertEqual(PickedFile(url: URL(fileURLWithPath: "/tmp/a.MOV"), name: "a.MOV", contentType: nil).kind, .video)
        XCTAssertEqual(PickedFile(url: URL(fileURLWithPath: "/tmp/a.pdf"), name: "a.pdf", contentType: "application/pdf").kind, nil)
        XCTAssertEqual(PickedFile(url: URL(fileURLWithPath: "/tmp/a"), name: "a.jpeg", contentType: nil).kind, .photo, "The name's ending is used when the file has none")
    }

    func testSavedFilesKeepTheirNameWithTheRightEnding() {
        func file(_ name: String, _ type: String) -> DeliveryFile {
            DeliveryFile(id: UUID(), kind: .photo, name: name, contentType: type, width: nil, height: nil, durationSeconds: nil, originalBytes: 1,
                         previewBytes: 1, status: .ready, savedAt: nil, createdAt: Date(), position: 0, previewPath: "p", originalPath: "o")
        }
        XCTAssertEqual(FileNames.saveName(for: file("IMG_0042.HEIC", "image/heic")), "IMG_0042.HEIC")
        XCTAssertEqual(FileNames.saveName(for: file("sunset", "image/jpeg")), "sunset.jpg")
        XCTAssertEqual(FileNames.saveName(for: file("clip.MP4", "video/quicktime")), "clip.mov")
        XCTAssertEqual(FileNames.saveName(for: file("a/b.heic", "image/heic")), "a b.heic")
    }

    func testAnUploadsBarAndWords() {
        var item = FileUploadItem(id: UUID(), bookingID: UUID(), name: "a.heic", kind: .photo, stage: .preparing)
        XCTAssertEqual(item.fraction, 0)
        XCTAssertEqual(item.statusText, "Getting ready…")
        item.stage = .sending(0.426)
        XCTAssertEqual(item.statusText, "Sending 43%")
        item.stage = .sending(7)
        XCTAssertEqual(item.fraction, 1, "Never past full")
        item.stage = .failed("No room")
        XCTAssertTrue(item.isFailed)
        XCTAssertEqual(item.failureMessage, "No room")
    }

    func testASaveRunsProgressIncludesTheFileInHand() {
        var run = FileSaveRun(deliveryID: UUID(), done: 1, total: 4, currentName: "b.heic", currentFraction: 0.5)
        XCTAssertEqual(run.fraction, 0.375, accuracy: 0.0001)
        run.done = 4
        run.currentFraction = 0
        XCTAssertEqual(run.fraction, 1, accuracy: 0.0001)
        XCTAssertEqual(FileSaveRun(deliveryID: UUID(), done: 0, total: 0, currentName: nil, currentFraction: 0).fraction, 1)
    }

    func testOnlyAFirstDeliveryHasAVideoPreview() {
        XCTAssertTrue(FileRules.previewIsVideo(kind: .video, deliveryKind: .delivery))
        XCTAssertFalse(FileRules.previewIsVideo(kind: .video, deliveryKind: .revision))
        XCTAssertFalse(FileRules.previewIsVideo(kind: .photo, deliveryKind: .delivery))
    }

    func testCountsAreSaidTheSameWayEverywhere() {
        XCTAssertEqual(FileRules.countText(photos: 12, videos: 2), "12 photos and 2 videos")
        XCTAssertEqual(FileRules.countText(photos: 1, videos: 1), "1 photo and 1 video")
        XCTAssertEqual(FileRules.countText(photos: 1, videos: 0), "1 photo")
        XCTAssertEqual(FileRules.countText(photos: 0, videos: 3), "3 videos")
        XCTAssertEqual(FileRules.countText(photos: 0, videos: 0), "files")
    }
}

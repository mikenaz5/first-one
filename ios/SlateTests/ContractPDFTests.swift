import PDFKit
import UIKit
import XCTest
@testable import Slate

final class ContractPDFTests: XCTestCase {
    private func makeContract(
        repeating copies: Int = 1, clientInk: Bool = false, creatorInk: Bool = false, sections: [ContractSection]? = nil
    ) -> Contract {
        let template = StarterTemplates.make(.photography, creatorID: UUID())
        let rendered = ContractRenderer.render(template: template, values: ContractContextBuilder.sample)
        let body = sections ?? Array((0..<copies).map { _ in rendered.sections }.joined())
        let contract = RenderedContract(title: rendered.title, sections: body, templateID: template.id, templateVersion: 1)
        let signedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return Contract(
            id: UUID(), bookingID: UUID(), creatorID: UUID(), clientID: UUID(),
            templateID: template.id, templateVersion: 1,
            title: contract.title, sections: contract.sections, documentHash: contract.documentHash,
            status: .executed,
            signatures: [
                ContractSignature(
                    id: UUID(), role: .client, userID: nil, signedName: "Alex Rivera",
                    method: clientInk ? .drawn : .typed, imagePNG: clientInk ? ContractFixtures.pngData() : nil,
                    signedAt: signedAt, consentVersion: 1, device: "Slate iOS app, OS 17.0"
                ),
                ContractSignature(
                    id: UUID(), role: .creator, userID: nil, signedName: "Maya Chen",
                    method: .onFile, imagePNG: creatorInk ? ContractFixtures.pngData() : nil,
                    signedAt: signedAt, consentVersion: 1, device: "Signature on file, applied at booking"
                ),
            ],
            createdAt: signedAt, executedAt: signedAt
        )
    }

    private func document(_ data: Data) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: data), "The output should be a readable PDF")
    }

    func testTheAgreementIsRealTextFollowedByASignaturePage() throws {
        let contract = makeContract()
        let pdf = try document(ContractPDF.render(contract, creatorName: "Maya Chen Photography", clientName: "Alex Rivera"))

        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        let all = pdf.string ?? ""
        XCTAssertTrue(all.contains(contract.title), "Searchable text, not a picture of text")
        XCTAssertTrue(all.contains("Maya Chen Photography"))
        XCTAssertTrue(all.contains("Alex Rivera"))
        XCTAssertTrue(all.contains("Deliverables"))

        let last = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("Signatures"))
        XCTAssertTrue(last.contains("Client: Alex Rivera"))
        XCTAssertTrue(last.contains("Creator: Maya Chen"))
        XCTAssertTrue(last.contains("Certificate of completion"))
        XCTAssertTrue(last.contains("Signed by typing their full name"))
        XCTAssertTrue(last.contains("Signature saved in advance by the Creator"))
        XCTAssertTrue(last.contains(contract.documentHash), "The full hash identifies the exact wording")
        XCTAssertTrue(last.contains(contract.bookingID.uuidString.lowercased()))
        XCTAssertTrue(last.contains("2027-01-15 08:00:00 UTC"), "Times are unambiguous UTC")
    }

    func testEveryPageIsLetterSizedAndFootedWithItsNumber() throws {
        let pdf = try document(ContractPDF.render(makeContract(repeating: 3), creatorName: "Maya", clientName: "Alex"))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 4)
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, ContractPDF.pageSize)
            XCTAssertTrue((page.string ?? "").contains("Page \(index + 1)"), "Page \(index + 1) names itself")
        }
    }

    func testALongerAgreementTakesMorePages() throws {
        let short = try document(ContractPDF.render(makeContract(repeating: 1), creatorName: "M", clientName: "A"))
        let long = try document(ContractPDF.render(makeContract(repeating: 4), creatorName: "M", clientName: "A"))
        XCTAssertGreaterThan(long.pageCount, short.pageCount)
        // The signatures stay together on the final page however long the agreement is.
        let last = try XCTUnwrap(long.page(at: long.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("Signatures"))
        XCTAssertTrue(last.contains("Certificate of completion"))
    }

    func testOneEnormousSectionStillFinishes() throws {
        let words = Array(repeating: "The Creator will deliver the finished work promptly and with care.", count: 600).joined(separator: " ")
        let contract = makeContract(sections: [ContractSection(title: "Everything", body: words)])
        let pdf = try document(ContractPDF.render(contract, creatorName: "M", clientName: "A"))
        XCTAssertGreaterThan(pdf.pageCount, 3)
    }

    func testAnEmptyAgreementStillHasATitlePageAndSignatures() throws {
        let pdf = try document(ContractPDF.render(makeContract(sections: []), creatorName: "M", clientName: "A"))
        XCTAssertEqual(pdf.pageCount, 2)
    }

    func testDrawnSignaturesRenderWithoutChangingTheLayout() throws {
        let typed = try document(ContractPDF.render(makeContract(), creatorName: "M", clientName: "A"))
        let drawn = try document(ContractPDF.render(makeContract(clientInk: true, creatorInk: true), creatorName: "M", clientName: "A"))
        XCTAssertEqual(drawn.pageCount, typed.pageCount)
        let last = try XCTUnwrap(drawn.page(at: drawn.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("Signed by typing their full name") == false, "The client drew theirs")
        XCTAssertTrue(last.contains("Signed by drawing their signature"))
    }

    func testTheDocumentIsLabelledForFilesAndShareSheets() throws {
        let contract = makeContract()
        let pdf = try document(ContractPDF.render(contract, creatorName: "Maya Chen Photography", clientName: "Alex Rivera"))
        let info = pdf.documentAttributes ?? [:]
        XCTAssertEqual(info[PDFDocumentAttribute.titleAttribute] as? String, contract.title)
        XCTAssertEqual(info[PDFDocumentAttribute.authorAttribute] as? String, "Maya Chen Photography")
        XCTAssertEqual(info[PDFDocumentAttribute.creatorAttribute] as? String, "Slate")
    }
}

@MainActor
final class SignedPDFFlowTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-pdf-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
        model = AppModel(backend: backend)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func bookOne() async throws -> SignedBooking {
        let creator = try await backend.signInWithApple(
            AppleCredential(userID: "pdf-creator", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: creator.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: creator.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: creator.userID)
        let package = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: creator.userID, name: "Portrait session", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id
        ))[0]

        await model.signInAsDemo()
        var day = CalendarDay(Date(), calendar: TestClock.calendar).adding(days: 4, in: TestClock.calendar)
        while !(2...6).contains(day.weekday(in: TestClock.calendar)) { day = day.adding(days: 1, in: TestClock.calendar) }
        let request = BookingRequest(
            creatorID: creator.userID, packageID: package.id, addOnIDs: [],
            startAt: day.date(atMinute: 600, in: TestClock.calendar)!, notes: ""
        )
        let preview = try await model.previewContract(for: request)
        return try await model.book(request, signature: ContractFixtures.typedSignature(hash: preview.documentHash))
    }

    func testThePDFIsMadeOnceAndEveryoneGetsTheSameFile() async throws {
        let signed = try await bookOne()
        let first = await model.signedPDF(for: signed.contract, booking: signed.booking)
        let second = await model.signedPDF(for: signed.contract, booking: signed.booking)
        let stored = try await backend.loadContractPDF(contractID: signed.contract.id)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "A second request reuses the stored file instead of making another")
        XCTAssertEqual(first, stored)
        let pdf = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(first)))
        XCTAssertTrue((pdf.string ?? "").contains(signed.contract.documentHash))
    }

    func testTheContractIsAvailableToTheClientFromTheirBookingsList() async throws {
        let signed = try await bookOne()
        let found = await model.contract(for: signed.booking)
        XCTAssertEqual(found?.id, signed.contract.id)
        XCTAssertEqual(found?.status, .executed)
    }
}

@MainActor
final class SignatureCaptureTests: XCTestCase {
    private func ink(_ capture: SignatureCapture) {
        capture.canvasSize = CGSize(width: 300, height: 100)
        capture.extendStroke(to: CGPoint(x: 10, y: 80))
        capture.extendStroke(to: CGPoint(x: 80, y: 20))
        capture.extendStroke(to: CGPoint(x: 150, y: 70))
        capture.endStroke()
    }

    func testTypingNeedsOnlyAName() {
        let capture = SignatureCapture(fullName: "")
        XCTAssertFalse(capture.isReady)
        capture.fullName = "  A "
        XCTAssertFalse(capture.isReady, "One letter isn't a name")
        capture.fullName = "Alex Rivera"
        XCTAssertTrue(capture.isReady)
        XCTAssertEqual(capture.trimmedName, "Alex Rivera")
    }

    func testDrawingNeedsInkAsWellAsAName() {
        let capture = SignatureCapture(fullName: "Alex Rivera")
        capture.method = .drawn
        XCTAssertFalse(capture.isReady)
        capture.extendStroke(to: CGPoint(x: 5, y: 5))
        XCTAssertFalse(capture.hasInk, "A single dot isn't a signature")
        capture.endStroke()
        capture.clear()
        ink(capture)
        XCTAssertTrue(capture.hasInk)
        XCTAssertTrue(capture.isReady)
        capture.clear()
        XCTAssertFalse(capture.hasInk)
        XCTAssertFalse(capture.isReady)
    }

    func testEachStrokeStartsWhereTheFingerLandsAgain() {
        let capture = SignatureCapture()
        capture.extendStroke(to: CGPoint(x: 1, y: 1))
        capture.extendStroke(to: CGPoint(x: 2, y: 2))
        capture.endStroke()
        capture.extendStroke(to: CGPoint(x: 50, y: 50))
        capture.extendStroke(to: CGPoint(x: 60, y: 60))
        XCTAssertEqual(capture.strokes.count, 2)
        XCTAssertEqual(capture.strokes[0].count, 2)
        XCTAssertEqual(capture.strokes[1].first, CGPoint(x: 50, y: 50))
    }

    func testTheDrawnSignatureBecomesATransparentPNGTheBackendAccepts() throws {
        let capture = SignatureCapture(fullName: "Alex Rivera")
        capture.method = .drawn
        ink(capture)
        let data = try XCTUnwrap(capture.pngData())
        XCTAssertTrue(SignatureRules.isPNG(data))
        XCTAssertLessThanOrEqual(data.count, SignatureRules.maxImageBytes)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size.width / image.size.height, capture.canvasSize.width / capture.canvasSize.height, accuracy: 0.01, "Same shape as the pad it was drawn on")

        let input = capture.input(documentHash: "abc")
        XCTAssertEqual(input.method, .drawn)
        XCTAssertTrue(input.imagePNG.map(SignatureRules.isPNG) ?? false, "The ink travels with the signature")
        XCTAssertEqual(input.documentHash, "abc")
        XCTAssertEqual(input.signedName, "Alex Rivera")
        XCTAssertTrue(SignatureRules.isValid(input))
    }

    func testNoInkMeansNoImageAndTypedSignaturesCarryNone() {
        let blank = SignatureCapture(fullName: "Alex Rivera")
        blank.canvasSize = CGSize(width: 300, height: 100)
        XCTAssertNil(blank.pngData())

        let typed = SignatureCapture(fullName: "Alex Rivera")
        ink(typed) // Drew something, then switched back to typing.
        typed.method = .typed
        let input = typed.input(documentHash: "abc")
        XCTAssertEqual(input.method, .typed)
        XCTAssertNil(input.imagePNG)
        XCTAssertTrue(SignatureRules.isValid(input))
        XCTAssertEqual(typed.creatorSignature().method, .typed)
        XCTAssertNil(typed.creatorSignature().imagePNG)
    }
}

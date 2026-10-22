import XCTest
@testable import Slate

/// Templates, the creator's signature, and signing a contract as part of booking, against the on-device backend.
final class ContractBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-contracts-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private let cal = TestClock.calendar

    private func openDay(minDaysAhead: Int = 3) -> CalendarDay {
        var day = CalendarDay(Date(), calendar: cal).adding(days: minDaysAhead, in: cal)
        while !(2...6).contains(day.weekday(in: cal)) { day = day.adding(days: 1, in: cal) }
        return day
    }

    private func at(_ day: CalendarDay, _ hour: Int, _ minute: Int = 0) -> Date {
        day.date(atMinute: hour * 60 + minute, in: cal)!
    }

    private struct Creator {
        var id: UUID
        var template: ContractTemplate
        var package: ServicePackage
    }

    private func makeCreator(handle: String = "dana-lens", withSignature: Bool = true, signature: CreatorSignature? = nil) async throws -> Creator {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)

        let template: ContractTemplate
        if withSignature {
            template = try await ContractFixtures.equip(
                backend, creatorID: session.userID, signature: signature ?? ContractFixtures.creatorSignature(name: "Dana Lens")
            )
        } else {
            let starter = StarterTemplates.make(.photography, creatorID: session.userID)
            template = try await backend.saveContractTemplate(starter).first { $0.id == starter.id }!
        }

        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: 50_000, addOns: [AddOn(kind: .extraTime, name: "Extra hour", priceCents: 15_000, extraMinutes: 60)],
            isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .flexible, usageRights: .commercial
        ))
        return Creator(id: session.userID, template: template, package: saved[0])
    }

    private func request(_ creator: Creator, at start: Date, addOns: [UUID] = [], notes: String = "") -> BookingRequest {
        BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: addOns, startAt: start, notes: notes)
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    private func assertNothingWasBooked(_ creator: Creator, file: StaticString = #filePath, line: UInt = #line) async throws {
        let bookings = try await backend.loadBookings(for: creator.id)
        XCTAssertTrue(bookings.isEmpty, "No booking should exist", file: file, line: line)
        let contracts = await backend.readContracts()
        XCTAssertTrue(contracts.isEmpty, "No contract should exist", file: file, line: line)
    }

    // MARK: Templates

    func testStarterTemplatesSaveAndComeBack() async throws {
        let session = try await backend.signInWithApple(AppleCredential(userID: "a", identityToken: "t", rawNonce: "n", fullName: nil, email: nil))
        for kind in StarterTemplates.kinds {
            _ = try await backend.saveContractTemplate(StarterTemplates.make(kind, creatorID: session.userID))
        }
        let list = try await backend.loadContractTemplates(for: session.userID)
        XCTAssertEqual(Set(list.map(\.kind)), Set(StarterTemplates.kinds))
        XCTAssertTrue(list.allSatisfy { $0.version == 1 })
        let others = try await backend.loadContractTemplates(for: UUID())
        XCTAssertTrue(others.isEmpty)
    }

    func testOnlyRealChangesToTheWordingBumpTheVersion() async throws {
        let creator = try await makeCreator()
        let original = creator.template
        XCTAssertEqual(original.version, 1)

        let unchanged = try await backend.saveContractTemplate(original).first { $0.id == original.id }!
        XCTAssertEqual(unchanged.version, 1, "Saving without changes doesn't count as a new version")
        XCTAssertEqual(unchanged.updatedAt, original.updatedAt)

        var edited = original
        edited.clauses[1].body += " Bring a second outfit."
        let reworded = try await backend.saveContractTemplate(edited).first { $0.id == original.id }!
        XCTAssertEqual(reworded.version, 2)
        XCTAssertEqual(reworded.createdAt, original.createdAt)
        XCTAssertGreaterThanOrEqual(reworded.updatedAt, original.updatedAt)

        var retitled = reworded
        retitled.title = "Portrait agreement"
        let third = try await backend.saveContractTemplate(retitled).first { $0.id == original.id }!
        XCTAssertEqual(third.version, 3, "A new title is a change too")
    }

    func testTemplatesThatWouldMakeAnIncompleteContractAreRefused() async throws {
        let creator = try await makeCreator()
        var missing = creator.template
        missing.clauses = [ContractClause(title: "Only", body: "Nothing useful here.")]
        await expectError(.invalidContract) { try await backend.saveContractTemplate(missing) }

        var unknown = creator.template
        unknown.clauses[0].body += " {{favourite_colour}}"
        await expectError(.invalidContract) { try await backend.saveContractTemplate(unknown) }

        var untitled = creator.template
        untitled.title = " "
        await expectError(.invalidContract) { try await backend.saveContractTemplate(untitled) }

        let stored = try await backend.loadContractTemplates(for: creator.id)
        XCTAssertEqual(stored.first?.clauses, creator.template.clauses, "The saved contract is untouched by failed edits")
    }

    func testACreatorCanKeepTwentyContractsAndNoMore() async throws {
        let creator = try await makeCreator()
        for _ in 1..<ContractRules.templateLimit {
            _ = try await backend.saveContractTemplate(StarterTemplates.blank(creatorID: creator.id))
        }
        let full = try await backend.loadContractTemplates(for: creator.id)
        XCTAssertEqual(full.count, ContractRules.templateLimit)
        await expectError(.invalidContract) { try await backend.saveContractTemplate(StarterTemplates.blank(creatorID: creator.id)) }

        // Editing one of the twenty is still fine.
        var edited = full[0]
        edited.title = "Renamed"
        let after = try await backend.saveContractTemplate(edited)
        XCTAssertEqual(after.count, ContractRules.templateLimit)
    }

    func testAContractInUseCannotBeDeletedUntilNoPackageUsesIt() async throws {
        let creator = try await makeCreator()
        await expectError(.templateInUse) { try await backend.deleteContractTemplate(creator.template.id, for: creator.id) }

        _ = try await backend.deletePackage(creator.package.id, for: creator.id)
        let remaining = try await backend.deleteContractTemplate(creator.template.id, for: creator.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAPackageCanOnlyUseItsOwnCreatorsContract() async throws {
        let dana = try await makeCreator(handle: "dana-lens")
        let sam = try await makeCreator(handle: "sam-frame")
        var stolen = sam.package
        stolen.contractTemplateID = dana.template.id
        await expectError(.invalidContract) { try await backend.savePackage(stolen) }
        var nonexistent = sam.package
        nonexistent.contractTemplateID = UUID()
        await expectError(.invalidContract) { try await backend.savePackage(nonexistent) }
    }

    // MARK: Creator signature

    func testCreatorSignatureRoundTripsTypedAndDrawn() async throws {
        let creator = try await makeCreator(withSignature: false)
        let none = try await backend.loadCreatorSignature(for: creator.id)
        XCTAssertNil(none)

        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Dana Lens"), for: creator.id)
        var loaded = try await backend.loadCreatorSignature(for: creator.id)
        XCTAssertEqual(loaded?.signedName, "Dana Lens")
        XCTAssertEqual(loaded?.method, .typed)
        XCTAssertNil(loaded?.imagePNG)

        let drawn = ContractFixtures.creatorSignature(name: "Dana L.", method: .drawn)
        try await backend.saveCreatorSignature(drawn, for: creator.id)
        loaded = try await backend.loadCreatorSignature(for: creator.id)
        XCTAssertEqual(loaded?.method, .drawn)
        XCTAssertEqual(loaded?.imagePNG, drawn.imagePNG)
    }

    func testBadCreatorSignaturesAreRefused() async throws {
        let creator = try await makeCreator(withSignature: false)
        await expectError(.invalidSignature) {
            try await backend.saveCreatorSignature(CreatorSignature(signedName: "D", method: .typed, imagePNG: nil, updatedAt: Date()), for: creator.id)
        }
        await expectError(.invalidSignature) {
            try await backend.saveCreatorSignature(CreatorSignature(signedName: "Dana", method: .drawn, imagePNG: Data("nope".utf8), updatedAt: Date()), for: creator.id)
        }
        await expectError(.invalidSignature) {
            try await backend.saveCreatorSignature(CreatorSignature(signedName: "Dana", method: .onFile, imagePNG: nil, updatedAt: Date()), for: creator.id)
        }
        let still = try await backend.loadCreatorSignature(for: creator.id)
        XCTAssertNil(still)
    }

    func testClientsCannotBookUntilTheCreatorHasASignatureOnFile() async throws {
        let creator = try await makeCreator(withSignature: false)
        let req = request(creator, at: at(openDay(), 10))
        await expectError(.creatorNotReady) { try await backend.previewContract(req, clientName: "Sam Client") }
        await expectError(.creatorNotReady) { try await ContractFixtures.signedBooking(backend, req) }
        try await assertNothingWasBooked(creator)

        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(), for: creator.id)
        let signed = try await ContractFixtures.signedBooking(backend, req)
        XCTAssertEqual(signed.contract.status, .executed)
    }

    // MARK: The contract a client sees

    func testThePreviewIsFilledInFromThePackageTheChoicesAndTheNames() async throws {
        let creator = try await makeCreator()
        let extra = creator.package.addOns[0].id
        let day = openDay()
        let preview = try await backend.previewContract(
            request(creator, at: at(day, 10), addOns: [extra], notes: "Bring the dog."), clientName: "Sam Client"
        )
        let text = preview.contract.text

        XCTAssertFalse(text.contains("{{"))
        XCTAssertTrue(text.contains("Sam Client"))
        XCTAssertTrue(text.contains("Dana Lens"))
        XCTAssertTrue(text.contains("Portrait session"))
        XCTAssertTrue(text.contains("30 edited photos"))
        XCTAssertTrue(text.contains("Extra hour (+$150)"))
        XCTAssertTrue(text.contains("$2,150"), "Package plus the add-on")
        XCTAssertTrue(text.contains("$500"), "The deposit")
        XCTAssertTrue(text.contains("$1,650"), "The balance")
        XCTAssertTrue(text.contains("10:00 AM \u{2013} 12:00 PM"), "An hour plus the extra hour")
        XCTAssertTrue(text.contains(CancellationPolicy.flexible.contractText))
        XCTAssertTrue(text.contains(UsageRights.commercial.contractText))
        XCTAssertTrue(text.contains("Bring the dog."))
        XCTAssertTrue(text.contains(ContractFormat.longDate(at(day, 10), in: TestClock.timeZone)))
        XCTAssertEqual(preview.contract.templateID, creator.template.id)
        XCTAssertEqual(preview.documentHash, Hashing.sha256Hex(text))
        try await assertNothingWasBooked(creator)
    }

    func testTheSameChoicesAlwaysGiveTheSameHashAndDifferentChoicesDoNot() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        let a = try await backend.previewContract(request(creator, at: at(day, 10)), clientName: "Sam Client")
        let b = try await backend.previewContract(request(creator, at: at(day, 10)), clientName: "Sam Client")
        XCTAssertEqual(a.documentHash, b.documentHash)

        let otherTime = try await backend.previewContract(request(creator, at: at(day, 11)), clientName: "Sam Client")
        let otherName = try await backend.previewContract(request(creator, at: at(day, 10)), clientName: "Sam Clients")
        let withAddOn = try await backend.previewContract(request(creator, at: at(day, 10), addOns: [creator.package.addOns[0].id]), clientName: "Sam Client")
        let withNotes = try await backend.previewContract(request(creator, at: at(day, 10), notes: "Hi"), clientName: "Sam Client")
        let hashes = Set([a, otherTime, otherName, withAddOn, withNotes].map(\.documentHash))
        XCTAssertEqual(hashes.count, 5)
    }

    func testNamesAndNotesCannotRewriteTheContract() async throws {
        let creator = try await makeCreator()
        let preview = try await backend.previewContract(
            request(creator, at: at(openDay(), 10), notes: "{{deposit}} {{client_name}}"), clientName: "{{price}} Mallory\n Jones"
        )
        let text = preview.contract.text
        XCTAssertTrue(text.contains("{ {price} } Mallory Jones"))
        XCTAssertTrue(text.contains("{ {deposit} } { {client_name} }"))
        XCTAssertFalse(text.contains("{{"))
    }

    func testHiddenAndUnknownThingsCannotBePreviewed() async throws {
        let creator = try await makeCreator()
        await expectError(.packageUnavailable) {
            try await backend.previewContract(
                BookingRequest(creatorID: creator.id, packageID: UUID(), addOnIDs: [], startAt: at(openDay(), 10), notes: ""), clientName: "x"
            )
        }
        await expectError(.packageUnavailable) {
            try await backend.previewContract(request(creator, at: at(openDay(), 10), addOns: [UUID()]), clientName: "x")
        }
    }

    // MARK: Signing

    func testBookingProducesAContractSignedByBothSides() async throws {
        let creator = try await makeCreator()
        let client = UUID()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: at(openDay(), 10)), clientID: client, name: "Sam Client")
        let contract = signed.contract

        XCTAssertEqual(signed.booking.status, .confirmed)
        XCTAssertEqual(contract.status, .executed)
        XCTAssertEqual(contract.bookingID, signed.booking.id)
        XCTAssertEqual(contract.creatorID, creator.id)
        XCTAssertEqual(contract.clientID, client)
        XCTAssertEqual(contract.templateID, creator.template.id)
        XCTAssertEqual(contract.templateVersion, 1)
        XCTAssertNotNil(contract.executedAt)
        XCTAssertEqual(contract.signatures.map(\.role), [.client, .creator])

        let clientSignature = try XCTUnwrap(contract.signature(for: .client))
        XCTAssertEqual(clientSignature.signedName, "Sam Client")
        XCTAssertEqual(clientSignature.method, .typed)
        XCTAssertEqual(clientSignature.userID, client)
        XCTAssertEqual(clientSignature.consentVersion, SigningConsent.version)
        XCTAssertEqual(clientSignature.device, "Test device")

        let creatorSignature = try XCTUnwrap(contract.signature(for: .creator))
        XCTAssertEqual(creatorSignature.signedName, "Dana Lens")
        XCTAssertEqual(creatorSignature.method, .onFile, "Applied from the signature on file, and recorded as such")
        XCTAssertEqual(creatorSignature.userID, creator.id)

        // The stored hash is of the stored words.
        let rebuilt = RenderedContract(title: contract.title, sections: contract.sections, templateID: creator.template.id, templateVersion: 1)
        XCTAssertEqual(rebuilt.documentHash, contract.documentHash)
    }

    func testDrawnSignaturesKeepTheirImageForBothParties() async throws {
        let drawnCreator = ContractFixtures.creatorSignature(name: "Dana Lens", method: .drawn)
        let creator = try await makeCreator(signature: drawnCreator)
        let req = request(creator, at: at(openDay(), 10))
        let preview = try await backend.previewContract(req, clientName: "Sam Client")
        let clientInk = ContractFixtures.drawnSignature(hash: preview.documentHash)
        let held = try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: clientInk)
        XCTAssertNil(held.contract.signature(for: .creator), "The creator's side is added when the deposit is paid")
        let signed = try await ContractFixtures.payDeposit(backend, held)

        XCTAssertEqual(signed.contract.signature(for: .client)?.method, .drawn)
        XCTAssertEqual(signed.contract.signature(for: .client)?.imagePNG, clientInk.imagePNG)
        XCTAssertEqual(signed.contract.signature(for: .creator)?.method, .onFile)
        XCTAssertEqual(signed.contract.signature(for: .creator)?.imagePNG, drawnCreator.imagePNG, "A drawn creator signature is shown as drawn")
    }

    func testTypedSignaturesNeverCarryAnImage() async throws {
        let creator = try await makeCreator()
        let req = request(creator, at: at(openDay(), 10))
        let preview = try await backend.previewContract(req, clientName: "Sam Client")
        var sneaky = ContractFixtures.typedSignature(hash: preview.documentHash)
        sneaky.imagePNG = ContractFixtures.pngData()
        let signed = try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: sneaky)
        XCTAssertNil(signed.contract.signature(for: .client)?.imagePNG)
    }

    func testBothPartiesCanOpenTheContractAndStrangersCannot() async throws {
        let creator = try await makeCreator()
        let client = UUID()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: at(openDay(), 10)), clientID: client)

        let forClient = try await backend.loadContract(bookingID: signed.booking.id, for: client)
        let forCreator = try await backend.loadContract(bookingID: signed.booking.id, for: creator.id)
        let forStranger = try await backend.loadContract(bookingID: signed.booking.id, for: UUID())
        let unknownBooking = try await backend.loadContract(bookingID: UUID(), for: client)
        XCTAssertEqual(forClient, signed.contract)
        XCTAssertEqual(forCreator, signed.contract)
        XCTAssertNil(forStranger)
        XCTAssertNil(unknownBooking)
    }

    func testSigningTheWrongWordsOrSomeoneElsesNameMeansNothingIsBooked() async throws {
        let creator = try await makeCreator()
        let req = request(creator, at: at(openDay(), 10))
        let preview = try await backend.previewContract(req, clientName: "Sam Client")

        await expectError(.contractChanged) {
            try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: "deadbeef"))
        }
        await expectError(.contractChanged) {
            try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: ""))
        }
        // The hash was for a contract naming "Sam Client", so booking under another name is a different contract.
        await expectError(.contractChanged) {
            try await backend.createBooking(req, clientID: UUID(), clientName: "Someone Else", signature: ContractFixtures.typedSignature(hash: preview.documentHash))
        }
        // ...and so is the same hash for a different time.
        let later = request(creator, at: at(openDay(), 11))
        await expectError(.contractChanged) {
            try await backend.createBooking(later, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: preview.documentHash))
        }
        try await assertNothingWasBooked(creator)
    }

    func testIfTheCreatorEditsTheWordingAfterPreviewTheOldSignatureIsRefusedAndTheNewOneWorks() async throws {
        let creator = try await makeCreator()
        let req = request(creator, at: at(openDay(), 10))
        let shown = try await backend.previewContract(req, clientName: "Sam Client")

        var edited = creator.template
        edited.clauses[0].body += " (Updated terms.)"
        _ = try await backend.saveContractTemplate(edited)

        await expectError(.contractChanged) {
            try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: shown.documentHash))
        }
        try await assertNothingWasBooked(creator)

        let reshown = try await backend.previewContract(req, clientName: "Sam Client")
        XCTAssertNotEqual(reshown.documentHash, shown.documentHash)
        XCTAssertTrue(reshown.contract.text.contains("(Updated terms.)"))
        let signed = try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: reshown.documentHash))
        XCTAssertEqual(signed.contract.templateVersion, 2)
    }

    func testASignedContractKeepsItsWordsWhenTheTemplateChangesLater() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        let first = try await ContractFixtures.signedBooking(backend, request(creator, at: at(day, 9)))

        var edited = creator.template
        edited.clauses[0].body += " (Changed after signing.)"
        _ = try await backend.saveContractTemplate(edited)

        let reopened = try await backend.loadContract(bookingID: first.booking.id, for: creator.id)
        XCTAssertEqual(reopened?.documentHash, first.contract.documentHash)
        XCTAssertEqual(reopened?.sections, first.contract.sections)
        XCTAssertEqual(reopened?.templateVersion, 1)
        XCTAssertFalse(reopened?.sections.contains { $0.body.contains("Changed after signing") } ?? true)

        let second = try await ContractFixtures.signedBooking(backend, request(creator, at: at(day, 14)))
        XCTAssertEqual(second.contract.templateVersion, 2)
        XCTAssertNotEqual(second.contract.documentHash, first.contract.documentHash)
    }

    func testSignaturesThatCouldNotHaveComeFromAPersonAreRefused() async throws {
        let creator = try await makeCreator()
        let req = request(creator, at: at(openDay(), 10))
        let preview = try await backend.previewContract(req, clientName: "Sam Client")
        let good = ContractFixtures.typedSignature(hash: preview.documentHash)

        var tooShort = good
        tooShort.signedName = "S"
        var claimsOnFile = good
        claimsOnFile.method = .onFile
        var drawnWithNothing = good
        drawnWithNothing.method = .drawn
        var drawnWithJunk = good
        drawnWithJunk.method = .drawn
        drawnWithJunk.imagePNG = Data("not a png".utf8)

        for bad in [tooShort, claimsOnFile, drawnWithNothing, drawnWithJunk] {
            await expectError(.invalidSignature) {
                try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: bad)
            }
        }
        try await assertNothingWasBooked(creator)
        let fine = try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: good)
        XCTAssertEqual(fine.contract.status, .pending, "Signed by the client; complete once the deposit is paid")
        XCTAssertEqual(fine.booking.status, .held)
    }

    func testATakenTimeIsReportedBeforeAnythingElse() async throws {
        let creator = try await makeCreator()
        let req = request(creator, at: at(openDay(), 10))
        _ = try await ContractFixtures.signedBooking(backend, req)
        // A stale preview and a taken slot: the client should hear about the slot, not a hash problem.
        await expectError(.slotTaken) {
            try await backend.createBooking(req, clientID: UUID(), clientName: "Sam Client", signature: ContractFixtures.typedSignature(hash: "stale"))
        }
        let contracts = await backend.readContracts()
        let bookings = await backend.readBookings()
        XCTAssertEqual(contracts.count, 1)
        XCTAssertEqual(bookings.count, 1)
    }

    func testEveryBookingHasExactlyOneContract() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        var bookingIDs: [UUID] = []
        for hour in [9, 11, 13, 15] {
            bookingIDs.append(try await ContractFixtures.signedBooking(backend, request(creator, at: at(day, hour))).booking.id)
        }
        let contracts = await backend.readContracts()
        XCTAssertEqual(Set(contracts.map(\.bookingID)), Set(bookingIDs))
        XCTAssertEqual(contracts.count, bookingIDs.count)
        XCTAssertEqual(Set(contracts.map(\.id)).count, bookingIDs.count)
    }

    // MARK: Signed PDFs

    func testASignedPDFIsStoredOnceAndBothPartiesGetTheSameFile() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: at(openDay(), 10)))
        let none = try await backend.loadContractPDF(contractID: signed.contract.id)
        XCTAssertNil(none)

        let first = Data("%PDF first".utf8)
        try await backend.attachContractPDF(first, contractID: signed.contract.id)
        try await backend.attachContractPDF(Data("%PDF second".utf8), contractID: signed.contract.id)
        let stored = try await backend.loadContractPDF(contractID: signed.contract.id)
        XCTAssertEqual(stored, first, "The first PDF stored is the one everyone keeps")
    }

    func testAPDFCannotBeStoredForAContractThatDoesNotExist() async throws {
        await expectError(.invalidContract) { try await backend.attachContractPDF(Data("%PDF".utf8), contractID: UUID()) }
    }
}

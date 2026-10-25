import XCTest
@testable import Slate

// MARK: - Rules

final class EmailCodeRulesTests: XCTestCase {
    func testAnAddressIsTrimmedAndLowercased() {
        XCTAssertEqual(EmailCodeRules.cleanEmail("  Sam@Example.COM \n"), "sam@example.com")
        XCTAssertEqual(EmailCodeRules.cleanEmail("a.b+tag@mail.example.co"), "a.b+tag@mail.example.co")
    }

    func testThingsThatAreNotAddressesAreRefused() {
        for bad in ["", "   ", "sam", "sam@", "@example.com", "sam@example", "sam@@example.com", "sam @example.com",
                    "sam@exa mple.com", "sam@.com", "sam@example.", "sam@example.c", String(repeating: "a", count: 65) + "@example.com"] {
            XCTAssertNil(EmailCodeRules.cleanEmail(bad), "\"\(bad)\" should not be an address")
        }
    }

    func testACodeIsSixDigitsHoweverItWasTyped() {
        XCTAssertEqual(EmailCodeRules.cleanCode("123456"), "123456")
        XCTAssertEqual(EmailCodeRules.cleanCode(" 123 456 "), "123456")
        XCTAssertEqual(EmailCodeRules.cleanCode("123-456"), "123456")
    }

    func testAnythingElseIsNotACode() {
        for bad in ["", "12345", "1234567", "12345a", "abcdef", "12 34 5", "١٢٣٤٥٦"] {
            XCTAssertNil(EmailCodeRules.cleanCode(bad), "\"\(bad)\" should not be a code")
        }
    }

    func testANameLosesExtraSpacesAndHasALimit() {
        XCTAssertEqual(EmailCodeRules.cleanName("  Sam   Client \n"), "Sam Client")
        XCTAssertNil(EmailCodeRules.cleanName("   "))
        XCTAssertNil(EmailCodeRules.cleanName(String(repeating: "x", count: EmailCodeRules.nameMaxLength + 1)))
        XCTAssertNotNil(EmailCodeRules.cleanName(String(repeating: "x", count: EmailCodeRules.nameMaxLength)))
    }
}

final class BookingLinkTextTests: XCTestCase {
    func testEveryWayOfWritingALinkFindsTheName() {
        for text in [
            "slate://book/dana-lens", "https://slate.example/dana-lens", "http://slate.example/dana-lens/", "slate.example/dana-lens",
            "SLATE.EXAMPLE/Dana-Lens", "@dana-lens", "dana-lens", "  dana-lens  ", "https://slate.example/dana-lens?ref=card",
        ] {
            XCTAssertEqual(BookingLinkText.handle(from: text), "dana-lens", text)
        }
    }

    func testTextThatCannotBeANameFindsNothing() {
        for text in ["", "  ", "no", "slate://booking/\(UUID().uuidString)", "slate://join/abc", "has spaces here", "https://slate.example/", "admin"] {
            XCTAssertNil(BookingLinkText.handle(from: text), "\"\(text)\" should find nothing")
        }
    }
}

final class BookedCreatorsTests: XCTestCase {
    private let me = UUID()

    private func booking(creator: UUID, name: String, status: BookingStatus = .confirmed, daysAgo: Int, client: UUID? = nil) -> Booking {
        let start = TestClock.date(2027, 2, 10, 10, 0)
        return Booking(
            id: UUID(), creatorID: creator, clientID: client ?? me, creatorName: name, clientName: "Sam",
            packageID: nil, packageName: "Portrait session", addOns: [],
            startAt: start, endAt: start.addingTimeInterval(3600), blockedUntil: start.addingTimeInterval(5400),
            timeZoneID: "America/Chicago", currencyCode: "USD", totalCents: 100_000, depositCents: 25_000, status: status,
            notes: "", createdAt: TestClock.date(2027, 1, 20, 9, 0).addingTimeInterval(-86_400 * Double(daysAgo))
        )
    }

    func testTheMostRecentlyBookedCreatorComesFirstAndBookingsAreCounted() {
        let dana = UUID(), noor = UUID()
        let list = BookedCreators.list(from: [
            booking(creator: dana, name: "Dana Lens", daysAgo: 30),
            booking(creator: noor, name: "Noor Haddad", daysAgo: 10),
            booking(creator: dana, name: "Dana Lens", daysAgo: 20),
        ], clientID: me)
        XCTAssertEqual(list.map(\.name), ["Noor Haddad", "Dana Lens"])
        XCTAssertEqual(list.map(\.bookingCount), [1, 2])
    }

    func testCancelledAndLapsedBookingsAndOtherPeoplesDontCount() {
        let dana = UUID()
        let list = BookedCreators.list(from: [
            booking(creator: dana, name: "Dana Lens", status: .cancelled, daysAgo: 5),
            booking(creator: dana, name: "Dana Lens", status: .expired, daysAgo: 6),
            booking(creator: UUID(), name: "Someone Else", daysAgo: 7, client: UUID()),
        ], clientID: me)
        XCTAssertTrue(list.isEmpty)
    }

    func testAHeldOrFinishedBookingCounts() {
        let dana = UUID()
        let list = BookedCreators.list(from: [
            booking(creator: dana, name: "Dana Lens", status: .held, daysAgo: 1),
            booking(creator: dana, name: "Dana Lens", status: .completed, daysAgo: 40),
        ], clientID: me)
        XCTAssertEqual(list.first?.bookingCount, 2)
    }
}

// MARK: - The on-device backend

final class ClientBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-client-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testTheDemoCodeSignsInAndMakesAnAccount() async throws {
        let session = try await backend.signInWithEmailCode(email: "Sam@Example.com", code: EmailCodeRules.demoCode)
        XCTAssertEqual(session.email, "sam@example.com")
        XCTAssertNil(session.appleUserID)
        XCTAssertNil(session.fullName)
        let restored = await backend.restoreSession()
        XCTAssertEqual(restored?.userID, session.userID)
    }

    func testTheSameAddressIsTheSamePersonOnTheNextVisit() async throws {
        let first = try await backend.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        _ = try await backend.updateDisplayName("Sam Client")
        try await backend.signOut()
        let again = try await backend.signInWithEmailCode(email: " SAM@example.com ", code: "123 456")
        XCTAssertEqual(again.userID, first.userID)
        XCTAssertEqual(again.fullName, "Sam Client", "The name comes back with the account")
    }

    func testDifferentAddressesAreDifferentPeople() async throws {
        let sam = try await backend.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        let alex = try await backend.signInWithEmailCode(email: "alex@example.com", code: EmailCodeRules.demoCode)
        XCTAssertNotEqual(sam.userID, alex.userID)
    }

    func testAWrongCodeOrAddressSignsNobodyIn() async throws {
        do {
            _ = try await backend.signInWithEmailCode(email: "sam@example.com", code: "654321")
            XCTFail("A wrong code should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .invalidCode)
        }
        do {
            _ = try await backend.signInWithEmailCode(email: "not an email", code: EmailCodeRules.demoCode)
            XCTFail("A bad address should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .invalidEmail)
        }
        let restored = await backend.restoreSession()
        XCTAssertNil(restored)
    }

    func testAskingForACodeChecksTheAddress() async throws {
        try await backend.requestEmailCode("sam@example.com")
        do {
            try await backend.requestEmailCode("sam@")
            XCTFail("A bad address should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .invalidEmail)
        }
    }

    func testTheNameNeedsToBeRealAndNeedsASession() async throws {
        do {
            _ = try await backend.updateDisplayName("Sam")
            XCTFail("There is nobody to name")
        } catch {
            XCTAssertEqual(error as? SlateError, .notSignedIn)
        }
        _ = try await backend.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        do {
            _ = try await backend.updateDisplayName("   ")
            XCTFail("An empty name should be refused")
        } catch {
            XCTAssertEqual(error as? SlateError, .nameRequired)
        }
        let named = try await backend.updateDisplayName("  Sam   Client ")
        XCTAssertEqual(named.fullName, "Sam Client")
    }

    func testAppleSignInKeepsTheNameApplePlayedOnlyOnce() async throws {
        var name = PersonNameComponents()
        name.givenName = "Alex"
        name.familyName = "Rivera"
        let first = try await backend.signInWithApple(
            AppleCredential(userID: "apple-alex", identityToken: "t", rawNonce: "n", fullName: name, email: "alex@example.com")
        )
        XCTAssertEqual(first.fullName, "Alex Rivera")
        try await backend.signOut()
        // The second time Apple gives no name.
        let second = try await backend.signInWithApple(
            AppleCredential(userID: "apple-alex", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        XCTAssertEqual(second.fullName, "Alex Rivera")
        XCTAssertEqual(second.email, "alex@example.com")
    }

    func testDeletingAnAccountForgetsTheAddress() async throws {
        let first = try await backend.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        try await backend.deleteAccount()
        let again = try await backend.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        XCTAssertNotEqual(again.userID, first.userID, "A deleted account doesn't come back")
    }
}

// MARK: - The app

@MainActor
final class ClientAccountFlowTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var model: AppModel!
    private let cal = TestClock.calendar

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-client-app-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
        model = AppModel(backend: backend)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func signInAsSam(named name: String? = "Sam Client") async throws {
        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        if let name { try await model.becomeClient(name: name) }
    }

    func testANewEmailAccountChoosesATypeAndCanChooseClient() async throws {
        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        XCTAssertEqual(model.phase, .onboarding, "Someone new is asked what they are")
        try await model.becomeClient(name: "Sam Client")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.isClientOnly)
        XCTAssertEqual(model.clientDisplayName, "Sam Client")
        XCTAssertEqual(model.clientFirstName, "Sam")
    }

    func testAClientNeedsANameBeforeTheyContinue() async throws {
        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        do {
            try await model.becomeClient(name: nil)
            XCTFail("There is no name yet")
        } catch {
            XCTAssertEqual(error as? SlateError, .nameRequired)
        }
        XCTAssertEqual(model.phase, .onboarding)
        do {
            try await model.becomeClient(name: "   ")
            XCTFail("An empty name isn't a name")
        } catch {
            XCTAssertEqual(error as? SlateError, .nameRequired)
        }
    }

    func testAKnownNameLetsThemContinueWithNoMoreQuestions() async throws {
        try await signInAsSam()
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        // The same person: ready at once, with their name, and nothing to choose.
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.isClientOnly)
        XCTAssertEqual(model.clientFirstName, "Sam")
    }

    func testAWrongCodeLeavesThemSignedOut() async throws {
        do {
            try await model.signInWithEmailCode(email: "sam@example.com", code: "000000")
            XCTFail("The code was wrong")
        } catch {
            XCTAssertEqual(error as? SlateError, .invalidCode)
        }
        XCTAssertEqual(model.phase, .launching, "Nothing changed")
        XCTAssertNil(model.session)
    }

    func testTheDemoClientIsReadyAtOnce() async throws {
        await model.signInAsDemoClient()
        XCTAssertEqual(model.phase, .ready, "Failed: \(model.alert?.message ?? "no message")")
        XCTAssertTrue(model.isClientOnly)
        XCTAssertEqual(model.clientDisplayName, "Sam Client")
    }

    func testSomeoneWhoArrivesFromABookingLinkIsMadeAClientWithoutChoosing() async throws {
        // Sam used the app before, so their name is known.
        try await signInAsSam()
        await model.signOut()

        let dana = try await makeBookableCreator()
        try await backend.signOut()
        model.handle(url: URL(string: "slate://book/dana-lens")!)
        XCTAssertEqual(model.pendingBookingHandle, "dana-lens", "The link waits for them to sign in")
        XCTAssertEqual(model.phase, .signedOut)

        try await model.signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.isClientOnly)
        for _ in 0..<100 where model.presentedPage == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.presentedPage?.profile.id, dana.id, "Their page opens after signing in")
        XCTAssertNil(model.pendingBookingHandle)
    }

    func testALinkFromSomeoneWhoseNameIsUnknownStillAsksForIt() async throws {
        model.handle(url: URL(string: "slate://book/dana-lens")!)
        try await model.signInWithEmailCode(email: "new.person@example.com", code: EmailCodeRules.demoCode)
        XCTAssertEqual(model.phase, .onboarding, "A name is needed before the contract can carry one")
        try await model.becomeClient(name: "New Person")
        XCTAssertEqual(model.phase, .ready)
    }

    func testAClientCanBookAndThenSeesThatCreatorToBookAgain() async throws {
        let dana = try await makeBookableCreator()
        try await backend.signOut()
        try await signInAsSam()

        let start = nextOpenMorning()
        let request = BookingRequest(creatorID: dana.id, packageID: dana.package.id, addOnIDs: [], startAt: start, notes: "")
        let preview = try await backend.previewContract(request, clientName: model.clientDisplayName)
        let signed = try await model.book(request, signature: ContractFixtures.typedSignature(hash: preview.documentHash, name: "Sam Client"))

        XCTAssertEqual(signed.booking.clientName, "Sam Client")
        XCTAssertTrue(model.isClientOnly, "Booking doesn't turn a client into a seller")
        XCTAssertEqual(model.creatorsBooked.map(\.name), ["Dana Lens"])
        XCTAssertEqual(model.visibleBookings.map(\.id), [signed.booking.id])
    }

    func testAClientWhoStartsSellingKeepsTheirBookingsAndStopsBeingClientOnly() async throws {
        let dana = try await makeBookableCreator()
        try await backend.signOut()
        try await signInAsSam()
        let start = nextOpenMorning()
        let request = BookingRequest(creatorID: dana.id, packageID: dana.package.id, addOnIDs: [], startAt: start, notes: "")
        let preview = try await backend.previewContract(request, clientName: "Sam Client")
        let signed = try await model.book(request, signature: ContractFixtures.typedSignature(hash: preview.documentHash, name: "Sam Client"))

        model.startingCreatorSetup = true
        let draft = ProfileDraft()
        draft.displayName = "Sam Client Studio"
        draft.handle = "samclient"
        draft.specialties = [.portraits]
        try await model.completeOnboarding(draft: draft, portfolio: [])

        XCTAssertFalse(model.isClientOnly)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.bookings.contains { $0.id == signed.booking.id }, "Their booking is still theirs")
    }

    func testAPastBookingMakesAPersonWithoutAProfileAClientOnANewDevice() async throws {
        let dana = try await makeBookableCreator()
        try await backend.signOut()
        try await signInAsSam()
        let start = nextOpenMorning()
        let request = BookingRequest(creatorID: dana.id, packageID: dana.package.id, addOnIDs: [], startAt: start, notes: "")
        let preview = try await backend.previewContract(request, clientName: "Sam Client")
        _ = try await model.book(request, signature: ContractFixtures.typedSignature(hash: preview.documentHash, name: "Sam Client"))

        // A fresh model on the same backend, with the "I'm a client" memory gone, as on another phone.
        let userID = try XCTUnwrap(model.session?.userID)
        UserDefaults.standard.removeObject(forKey: AppConfig.clientAccountKey(for: userID))
        let other = AppModel(backend: backend)
        await other.bootstrap()
        XCTAssertEqual(other.phase, .ready, "Their bookings show they are a client")
        XCTAssertTrue(other.isClientOnly)
    }

    // MARK: Helpers

    private struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    private func nextOpenMorning() -> Date {
        var day = CalendarDay(Date(), calendar: cal).adding(days: 3, in: cal)
        while !(2...6).contains(day.weekday(in: cal)) { day = day.adding(days: 1, in: cal) }
        return day.date(atMinute: 10 * 60, in: cal)!
    }

    /// Dana Lens, with hours, a signature, a contract and one package, on this device's backend. Leaves Dana signed in.
    private func makeBookableCreator() async throws -> Creator {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-dana", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(
            backend, creatorID: session.userID, signature: ContractFixtures.creatorSignature(name: "Dana Lens")
        )
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .flexible, usageRights: .commercial
        ))
        return Creator(id: session.userID, package: saved[0])
    }
}

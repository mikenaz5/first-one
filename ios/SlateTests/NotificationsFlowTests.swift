import XCTest
@testable import Slate

/// The system's notification center, which the test controls.
@MainActor
final class FakeNotificationCenter: NotificationCenterClient {
    var status: NotificationAuthorization
    var grants: Bool
    private(set) var permissionRequests = 0
    private(set) var remoteRegistrations = 0
    private(set) var pending: [String: PlannedReminder] = [:]
    private(set) var badges: [Int] = []

    init(status: NotificationAuthorization = .allowed, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorization() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        if status == .notDetermined { status = grants ? .allowed : .denied }
        return status == .allowed
    }

    func pendingReminderIDs() async -> [String] { Array(pending.keys) }
    func schedule(_ reminder: PlannedReminder) async throws { pending[reminder.id] = reminder }
    func removePending(ids: [String]) { for id in ids { pending[id] = nil } }
    func setBadge(_ count: Int) async { badges.append(count) }
    func registerForRemoteNotifications() { remoteRegistrations += 1 }

    /// The scheduled reminders, soonest first.
    var reminders: [PlannedReminder] { pending.values.sorted { $0.fireDate < $1.fireDate } }
}

/// An app with a signed-in client (the demo person), one creator, and a clock the test moves by hand.
@MainActor
final class NotificationWorld {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-notify-\(UUID().uuidString)")
    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot is Friday 22 Jan at 10:00.
    let start = TestClock.date(2027, 1, 4, 8, 0)
    let friday = TestClock.date(2027, 1, 22, 10, 0)
    let clock: ManualClock
    let backend: LocalBackend
    let center: FakeNotificationCenter
    let model: AppModel
    private(set) var creatorID = UUID()
    private(set) var package: ServicePackage!

    private init(status: NotificationAuthorization, grants: Bool, sendsPush: Bool) {
        clock = ManualClock(start)
        let clock = self.clock
        backend = LocalBackend(root: root, clock: { clock.now }, sendsPushFromServer: sendsPush)
        center = FakeNotificationCenter(status: status, grants: grants)
        model = AppModel(backend: backend, notifications: center)
        model.clock = { clock.now }
    }

    static func make(
        status: NotificationAuthorization = .allowed, grants: Bool = true, sendsPush: Bool = false, deposit: Int = 0
    ) async throws -> NotificationWorld {
        // The "Not now" card remembers itself in UserDefaults; every test starts as a fresh install.
        UserDefaults.standard.removeObject(forKey: AppConfig.notificationPromptDismissedKey)
        let world = NotificationWorld(status: status, grants: grants, sendsPush: sendsPush)
        try await world.makeCreator(deposit: deposit)
        await world.model.signInAsDemo()
        await world.model.waitForStartupWork()
        return world
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeCreator(deposit: Int) async throws {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "creator-apple", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        creatorID = session.userID
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: [], turnaroundDays: 7,
            depositCents: deposit, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .moderate
        ))
        package = saved[0]
    }

    var myID: UUID { model.session!.userID }

    /// The signed-in person books the creator's package for Friday 22 January, and the app loads it.
    @discardableResult
    func bookAsClient(pay: Bool = true) async throws -> Booking {
        let request = BookingRequest(creatorID: creatorID, packageID: package.id, addOnIDs: [], startAt: friday, notes: "")
        let signed = try await ContractFixtures.signedBooking(backend, request, clientID: myID, pay: pay)
        await model.reloadMoney()
        await model.waitForReminderSync()
        return try XCTUnwrap(model.bookings.first { $0.id == signed.booking.id })
    }

    /// The creator writes to the signed-in person.
    @discardableResult
    func creatorSays(_ text: String, in bookingID: UUID) async throws -> Message {
        try await backend.sendMessage(text, bookingID: bookingID, clientMessageID: UUID(), from: creatorID)
    }
}

@MainActor
final class NotificationsFlowTests: XCTestCase {
    private var world: NotificationWorld!

    override func tearDown() async throws {
        world?.tearDown()
        try await super.tearDown()
    }

    // MARK: Reminders on this phone

    func testTurningNotificationsOnAsksOnceAndKeepsTheReminders() async throws {
        world = try await NotificationWorld.make(status: .notDetermined)
        let model = world.model, center = world.center
        try await world.bookAsClient()
        await model.refreshNotificationStatus()

        XCTAssertTrue(model.wantsNotificationPrompt, "Home offers to turn them on")
        XCTAssertEqual(center.permissionRequests, 0, "Nothing asks until the person chooses to")
        XCTAssertEqual(center.reminders.count, 2, "Reminders are queued so they fire once allowed")

        await model.enableNotifications()
        XCTAssertEqual(center.permissionRequests, 1)
        XCTAssertEqual(model.notificationAuthorization, .allowed)
        XCTAssertFalse(model.wantsNotificationPrompt)
        XCTAssertEqual(center.reminders.count, 2)
        XCTAssertEqual(center.remoteRegistrations, 0, "With no server there is no device token to ask Apple for")
    }

    func testSayingNotNowHidesThePromptForGood() async throws {
        world = try await NotificationWorld.make(status: .notDetermined)
        let model = world.model
        await model.refreshNotificationStatus()
        XCTAssertTrue(model.wantsNotificationPrompt)
        model.dismissNotificationPrompt()
        XCTAssertFalse(model.wantsNotificationPrompt)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppConfig.notificationPromptDismissedKey))
        UserDefaults.standard.removeObject(forKey: AppConfig.notificationPromptDismissedKey)
    }

    func testARefusedPermissionIsRememberedAndSchedulesNothing() async throws {
        world = try await NotificationWorld.make(status: .notDetermined, grants: false)
        let model = world.model, center = world.center
        try await world.bookAsClient()
        await model.enableNotifications()
        XCTAssertEqual(model.notificationAuthorization, .denied)
        XCTAssertTrue(center.reminders.isEmpty)
        XCTAssertFalse(model.wantsNotificationPrompt)
    }

    func testAShootGetsADayBeforeAndATwoHoursBeforeReminder() async throws {
        world = try await NotificationWorld.make()
        let booking = try await world.bookAsClient()
        let reminders = world.center.reminders

        XCTAssertEqual(reminders.map(\.fireDate), [world.friday.addingTimeInterval(-86_400), world.friday.addingTimeInterval(-7200)])
        XCTAssertEqual(reminders.map(\.title), ["Shoot tomorrow", "Shoot in 2 hours"])
        XCTAssertEqual(reminders.first?.body, "Portrait session with Dana Lens at 10:00 AM")
        XCTAssertTrue(reminders.allSatisfy { $0.bookingID == booking.id })
    }

    func testAHeldBookingGetsNoRemindersUntilItsDepositIsPaid() async throws {
        world = try await NotificationWorld.make(deposit: 50_000)
        let held = try await world.bookAsClient(pay: false)
        XCTAssertEqual(held.status, .held)
        XCTAssertTrue(world.center.reminders.isEmpty)

        let info = try await world.backend.preparePayment(bookingID: held.id, kind: .deposit, by: world.myID)
        try await world.backend.completeSimulatedPayment(info.paymentID)
        await world.model.reloadMoney()
        await world.model.waitForReminderSync()
        XCTAssertEqual(world.center.reminders.count, 2)
    }

    func testCancellingTakesTheRemindersAway() async throws {
        world = try await NotificationWorld.make()
        let booking = try await world.bookAsClient()
        XCTAssertEqual(world.center.reminders.count, 2)

        await world.model.cancel(booking)
        await world.model.waitForReminderSync()
        XCTAssertTrue(world.center.reminders.isEmpty)
    }

    func testTurningRemindersOffAndOnAgain() async throws {
        world = try await NotificationWorld.make()
        try await world.bookAsClient()

        await world.model.setNotification(.reminders, enabled: false)
        XCTAssertTrue(world.center.reminders.isEmpty)
        XCTAssertFalse(world.model.notificationPreferences.reminders)
        let stored = try await world.backend.loadNotificationPreferences(for: world.myID)
        XCTAssertFalse(stored.reminders, "The choice is saved with the backend")

        await world.model.setNotification(.reminders, enabled: true)
        XCTAssertEqual(world.center.reminders.count, 2)
    }

    func testRemindersFollowTheClockNotJustTheBookings() async throws {
        world = try await NotificationWorld.make()
        try await world.bookAsClient()
        // Past the day-before moment, only the two-hour reminder is left to schedule.
        world.clock.set(world.friday.addingTimeInterval(-20 * 3600))
        await world.model.syncReminders()
        XCTAssertEqual(world.center.reminders.map(\.title), ["Shoot in 2 hours"])
    }

    func testSyncingTwiceDoesNotScheduleTwice() async throws {
        world = try await NotificationWorld.make()
        try await world.bookAsClient()
        await world.model.syncReminders()
        await world.model.syncReminders()
        XCTAssertEqual(world.center.reminders.count, 2)
    }

    func testPermissionTakenAwayInSettingsClearsThem() async throws {
        world = try await NotificationWorld.make()
        try await world.bookAsClient()
        XCTAssertEqual(world.center.reminders.count, 2)
        world.center.status = .denied
        await world.model.syncReminders()
        XCTAssertTrue(world.center.reminders.isEmpty)
        XCTAssertEqual(world.model.notificationAuthorization, .denied)
    }

    // MARK: With a server

    func testWithAServerTheAppSchedulesNoRemindersAndClearsLeftovers() async throws {
        world = try await NotificationWorld.make(sendsPush: true)
        try await world.center.schedule(PlannedReminder(
            id: "\(ReminderRules.identifierPrefix)leftover", bookingID: UUID(), fireDate: world.friday, title: "Old", body: "Old"
        ))
        try await world.bookAsClient()
        await world.model.syncReminders()
        XCTAssertTrue(world.center.reminders.isEmpty, "The server sends them, so the phone must not as well")
    }

    func testWithAServerThePhoneAsksAppleForATokenWhenAllowed() async throws {
        world = try await NotificationWorld.make(sendsPush: true)
        await world.model.prepareNotifications()
        XCTAssertGreaterThanOrEqual(world.center.remoteRegistrations, 1)
    }

    func testWithoutPermissionThePhoneDoesNotAskForAToken() async throws {
        world = try await NotificationWorld.make(status: .notDetermined, sendsPush: true)
        await world.model.prepareNotifications()
        XCTAssertEqual(world.center.remoteRegistrations, 0)
    }

    func testWithAServerAskingForPermissionAlsoAsksForAToken() async throws {
        world = try await NotificationWorld.make(status: .notDetermined, sendsPush: true)
        await world.model.enableNotifications()
        XCTAssertGreaterThanOrEqual(world.center.remoteRegistrations, 1)
        XCTAssertEqual(world.model.notificationAuthorization, .allowed)
    }

    func testTheDeviceTokenIsHandedToTheServer() async throws {
        world = try await NotificationWorld.make(sendsPush: true)
        let token = Data(repeating: 0xAB, count: 32)
        await world.model.didRegisterForRemoteNotifications(token: token)

        let expected = String(repeating: "ab", count: 32)
        XCTAssertEqual(world.model.deviceToken, expected)
        XCTAssertNil(world.model.pushRegistrationProblem)
        let devices = await world.backend.registeredDevices()
        XCTAssertEqual(devices, [LocalBackend.RegisteredDevice(token: expected, environment: .current, userID: world.myID)])
    }

    func testSigningOutClearsRemindersTheBadgeAndConversations() async throws {
        world = try await NotificationWorld.make()
        try await world.bookAsClient()
        XCTAssertEqual(world.center.reminders.count, 2)
        try await world.creatorSays("Hello!", in: world.model.bookings[0].id)
        await world.model.refreshConversations()
        XCTAssertEqual(world.model.unreadMessageCount, 1)

        await world.model.signOut()
        XCTAssertTrue(world.center.reminders.isEmpty)
        XCTAssertEqual(world.center.badges.last, 0)
        XCTAssertTrue(world.model.conversations.isEmpty)
    }

    func testSigningOutUnregistersTheDevice() async throws {
        world = try await NotificationWorld.make(sendsPush: true)
        await world.model.didRegisterForRemoteNotifications(token: Data(repeating: 0x11, count: 32))
        let registered = await world.backend.registeredDevices()
        XCTAssertEqual(registered.count, 1)

        await world.model.signOut()
        let remaining = await world.backend.registeredDevices()
        XCTAssertTrue(remaining.isEmpty, "A signed-out phone must stop receiving that person's notifications")
    }

    func testAFailedRegistrationIsExplainedAndClearedByASuccess() async throws {
        world = try await NotificationWorld.make(sendsPush: true)
        struct NoEntitlement: LocalizedError { var errorDescription: String? { "no valid aps-environment entitlement" } }
        world.model.didFailToRegisterForRemoteNotifications(NoEntitlement())
        XCTAssertTrue(world.model.pushRegistrationProblem?.contains("can't receive push notifications yet") == true)
        XCTAssertTrue(world.model.pushRegistrationProblem?.contains("aps-environment") == true)

        await world.model.didRegisterForRemoteNotifications(token: Data(repeating: 0x22, count: 32))
        XCTAssertNil(world.model.pushRegistrationProblem)
    }

    // MARK: Settings

    func testSettingsAreSavedAndShown() async throws {
        world = try await NotificationWorld.make()
        await world.model.setNotification(.messages, enabled: false)
        XCTAssertFalse(world.model.notificationPreferences.messages)
        XCTAssertTrue(world.model.notificationPreferences.payments)
        let stored = try await world.backend.loadNotificationPreferences(for: world.myID)
        XCTAssertEqual(stored, world.model.notificationPreferences)
    }

    func testSettingsAreLoadedWhenTheAccountOpens() async throws {
        world = try await NotificationWorld.make()
        var chosen = NotificationPreferences()
        chosen.contracts = false
        _ = try await world.backend.saveNotificationPreferences(chosen, for: world.myID)
        await world.model.prepareNotifications()
        XCTAssertEqual(world.model.notificationPreferences, chosen)
    }

    // MARK: Notifications arriving

    func testAMessageForTheConversationOnScreenNeedsNoBanner() async throws {
        world = try await NotificationWorld.make()
        let id = UUID()
        func payload(_ link: String) -> [AnyHashable: Any] { ["aps": ["badge": 1], "slate": ["url": link]] }

        XCTAssertTrue(world.model.shouldShowBanner(forUserInfo: payload("slate://messages/\(id.uuidString)")))
        world.model.openConversationID = id
        XCTAssertFalse(world.model.shouldShowBanner(forUserInfo: payload("slate://messages/\(id.uuidString)")))
        XCTAssertTrue(world.model.shouldShowBanner(forUserInfo: payload("slate://messages/\(UUID().uuidString)")), "A different conversation still shows")
        XCTAssertTrue(world.model.shouldShowBanner(forUserInfo: payload("slate://booking/\(id.uuidString)")), "Only messages are suppressed")
        XCTAssertTrue(world.model.shouldShowBanner(forUserInfo: ["aps": ["badge": 1]]))
    }

    func testTappingANotificationOpensTheRightScreen() async throws {
        world = try await NotificationWorld.make()
        let id = UUID()
        world.model.handle(url: URL(string: "slate://messages/\(id.uuidString)")!)
        XCTAssertEqual(world.model.selectedTab, .messages)
        XCTAssertEqual(world.model.messagesPath, [id])

        world.model.handle(url: URL(string: "slate://booking/\(id.uuidString)")!)
        XCTAssertEqual(world.model.selectedTab, .bookings)
        XCTAssertEqual(world.model.bookingsPath, [id])

        world.model.handle(url: URL(string: "slate://messages")!)
        XCTAssertEqual(world.model.selectedTab, .messages)
        world.model.handle(url: URL(string: "slate://booking")!)
        XCTAssertEqual(world.model.selectedTab, .bookings)
    }

    func testTheIconBadgeFollowsWhatIsUnread() async throws {
        world = try await NotificationWorld.make()
        let booking = try await world.bookAsClient()
        try await world.creatorSays("First", in: booking.id)
        try await world.creatorSays("Second", in: booking.id)

        await world.model.refreshConversations()
        XCTAssertEqual(world.model.unreadMessageCount, 2)
        XCTAssertEqual(world.center.badges.last, 2)
        XCTAssertEqual(world.model.conversation(for: booking.id)?.unreadCount, 2)

        await world.model.markConversationRead(booking.id)
        XCTAssertEqual(world.model.unreadMessageCount, 0)
        XCTAssertEqual(world.center.badges.last, 0)
        let onServer = try await world.backend.loadConversations(for: world.myID)
        XCTAssertEqual(onServer.map(\.unreadCount), [0])
    }

    func testWhoCanBeMessaged() async throws {
        world = try await NotificationWorld.make(deposit: 50_000)
        let held = try await world.bookAsClient(pay: false)
        XCTAssertTrue(world.model.canMessage(held))
        XCTAssertEqual(world.model.counterpartName(for: held), "Dana Lens")

        var lapsed = held
        lapsed.holdExpiresAt = world.start.addingTimeInterval(-60)
        XCTAssertFalse(world.model.canMessage(lapsed), "A hold that ran out has no conversation")
    }
}

@MainActor
final class ConversationModelTests: XCTestCase {
    private var world: NotificationWorld!
    private var booking: Booking!

    override func setUp() async throws {
        try await super.setUp()
        world = try await NotificationWorld.make()
        booking = try await world.bookAsClient()
    }

    override func tearDown() async throws {
        world.tearDown()
        try await super.tearDown()
    }

    private func conversation() -> ConversationModel {
        ConversationModel(bookingID: booking.id, app: world.model)
    }

    private func texts(_ model: ConversationModel) -> [String] {
        model.messages.filter { $0.kind == .text }.map(\.body)
    }

    func testOpeningShowsTheWholeThreadAndMarksItRead() async throws {
        try await world.creatorSays("Welcome!", in: booking.id)
        try await world.creatorSays("See you Friday.", in: booking.id)
        await world.model.refreshConversations()
        XCTAssertEqual(world.model.unreadMessageCount, 2)

        let thread = conversation()
        XCTAssertFalse(thread.hasLoaded)
        await thread.load()

        XCTAssertTrue(thread.hasLoaded)
        XCTAssertEqual(texts(thread), ["Welcome!", "See you Friday."])
        XCTAssertEqual(thread.messages.compactMap(\.event), [.booked, .contractSigned], "System lines are part of the thread")
        XCTAssertEqual(world.model.unreadMessageCount, 0)
        let onServer = try await world.backend.loadConversations(for: world.myID)
        XCTAssertEqual(onServer.map(\.unreadCount), [0])
    }

    func testSendingPutsTheMessageInTheThread() async throws {
        let thread = conversation()
        await thread.load()
        let sent = await thread.send("  Hello Dana  ")

        XCTAssertTrue(sent)
        XCTAssertEqual(texts(thread), ["Hello Dana"], "Tidied, as the backend stores it")
        XCTAssertTrue(thread.pending.isEmpty)
        XCTAssertEqual(thread.sentCount, 1)
        XCTAssertEqual(thread.failedCount, 0)
        let stored = try await world.backend.loadMessages(bookingID: booking.id, since: nil, for: world.creatorID)
        XCTAssertEqual(stored.filter { $0.kind == .text }.map(\.body), ["Hello Dana"])
        XCTAssertEqual(world.model.conversation(for: booking.id)?.last.body, "Hello Dana")
    }

    func testNothingSendableIsSent() async throws {
        let thread = conversation()
        await thread.load()
        let empty = await thread.send("  \n ")
        let long = await thread.send(String(repeating: "x", count: 2001))
        XCTAssertFalse(empty)
        XCTAssertFalse(long)
        XCTAssertTrue(thread.pending.isEmpty)
        XCTAssertTrue(texts(thread).isEmpty)
    }

    func testRefreshPicksUpWhatTheOtherPersonWroteAndReadsIt() async throws {
        let thread = conversation()
        await thread.load()
        try await world.creatorSays("Running five minutes late", in: booking.id)
        await world.model.refreshConversations()
        XCTAssertEqual(world.model.unreadMessageCount, 1)

        await thread.refresh()
        XCTAssertEqual(texts(thread), ["Running five minutes late"])
        XCTAssertEqual(world.model.unreadMessageCount, 0, "It is on screen, so it counts as read")
    }

    func testRefreshingDoesNotDuplicateWhatWasJustSent() async throws {
        let thread = conversation()
        await thread.load()
        await thread.send("Once")
        await thread.refresh()
        await thread.refresh()
        XCTAssertEqual(texts(thread), ["Once"])
        XCTAssertTrue(thread.pending.isEmpty)
    }

    func testAMessageThatCannotBeDeliveredStaysVisibleAndCanBeDiscarded() async throws {
        world.tearDown()
        world = try await NotificationWorld.make(deposit: 50_000)
        booking = try await world.bookAsClient(pay: false)

        let thread = conversation()
        await thread.load()
        world.clock.advance(by: 16 * 60) // The hold runs out, so the conversation closes.
        await thread.send("Anyone there?")

        XCTAssertEqual(thread.pending.count, 1)
        XCTAssertEqual(thread.pending.first?.body, "Anyone there?")
        XCTAssertEqual(thread.pending.first?.state, PendingMessage.State.failed("This conversation is closed."))
        XCTAssertEqual(thread.failedCount, 1)
        XCTAssertEqual(thread.sentCount, 0)

        let id = try XCTUnwrap(thread.pending.first?.id)
        await thread.retry(id)
        XCTAssertEqual(thread.pending.count, 1, "Still can't be delivered, so it stays")
        XCTAssertEqual(thread.failedCount, 2)

        thread.discard(id)
        XCTAssertTrue(thread.pending.isEmpty)
    }

    func testTheOtherPersonCanTellTheSenderApartFromThemselves() async throws {
        let thread = conversation()
        await thread.load()
        await thread.send("From me")
        try await world.creatorSays("From Dana", in: booking.id)
        await thread.refresh()

        let me = world.myID
        let mine = thread.messages.filter { $0.isFrom(me) }.map(\.body)
        let theirs = thread.messages.filter { $0.kind == .text && !$0.isFrom(me) }.map(\.body)
        XCTAssertEqual(mine, ["From me"])
        XCTAssertEqual(theirs, ["From Dana"])
    }
}

import XCTest
@testable import Slate

/// Team events and calendar links: the numbers shared with the database, the on-device backend (which follows
/// `…_team_events.sql` rule for rule), the pieces of the app around them, and what the Supabase backend decodes.
/// The same rules are tested in Postgres by `supabase/tests/event_rules.py`.

// MARK: - Shared numbers and text

final class EventRulesTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "event_rules", withExtension: "json"), "event_rules.json is missing from the test bundle")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTheNumbersAreTheOnesTheDatabaseIsTestedAgainst() throws {
        let rules = try fixture()
        XCTAssertEqual(rules["titleMaxLength"] as? Int, EventRules.titleMaxLength)
        XCTAssertEqual(rules["notesMaxLength"] as? Int, EventRules.notesMaxLength)
        XCTAssertEqual(rules["locationMaxLength"] as? Int, EventRules.locationMaxLength)
        XCTAssertEqual(rules["maxDays"] as? Int, EventRules.maxDays)
        XCTAssertEqual(rules["maxUpcoming"] as? Int, EventRules.maxUpcoming)
        XCTAssertEqual(rules["maxPeople"] as? Int, EventRules.maxPeople)
    }

    func testATitleIsCleanedTheWayTheDatabaseCleansIt() throws {
        let cases = try XCTUnwrap(try fixture()["cleanLine"] as? [[String: String]])
        XCTAssertGreaterThan(cases.count, 10)
        for entry in cases {
            let input = try XCTUnwrap(entry["input"])
            XCTAssertEqual(EventRules.cleanLine(input), entry["expected"], "cleaning \(input.debugDescription)")
        }
    }

    func testNotesKeepTheirLineBreaks() {
        XCTAssertEqual(EventRules.cleanNotes("  Bring the 24-70\r\nand the gimbal \n"), "Bring the 24-70\nand the gimbal")
    }

    // MARK: Problems

    private let start = TestClock.date(2027, 1, 6, 10, 0)

    private func problem(
        title: String = "Meeting", notes: String = "", location: String = "", hours: Double = 1, everyone: Bool = true, people: Int = 0
    ) -> EventRules.Problem? {
        EventRules.problem(
            title: title, notes: notes, location: location, startsAt: start, endsAt: start.addingTimeInterval(hours * 3600),
            everyone: everyone, people: people
        )
    }

    func testAnEventNeedsANameAndAnEndAfterItsStart() {
        XCTAssertNil(problem())
        XCTAssertEqual(problem(title: "   \n "), .noTitle)
        XCTAssertEqual(problem(hours: 0), .endNotAfterStart)
        XCTAssertEqual(problem(hours: -1), .endNotAfterStart)
    }

    func testTheTextLimitsCountTheWayTheDatabaseCounts() {
        XCTAssertNil(problem(title: String(repeating: "x", count: 80)))
        XCTAssertEqual(problem(title: String(repeating: "x", count: 81)), .titleTooLong)
        XCTAssertNil(problem(notes: String(repeating: "n", count: 500)))
        XCTAssertEqual(problem(notes: String(repeating: "n", count: 501)), .notesTooLong)
        XCTAssertNil(problem(location: String(repeating: "p", count: 120)))
        XCTAssertEqual(problem(location: String(repeating: "p", count: 121)), .locationTooLong)
        // Emoji are one each, as in Postgres (code points, not UTF-16 units).
        XCTAssertNil(problem(title: String(repeating: "📸", count: 80)))
        XCTAssertEqual(problem(title: String(repeating: "📸", count: 81)), .titleTooLong)
    }

    func testAnEventCanRunThirtyOneDaysButNoLonger() {
        XCTAssertNil(problem(hours: 31 * 24))
        XCTAssertEqual(problem(hours: 31 * 24 + 1), .tooLong)
    }

    func testAnEventForNamedPeopleNeedsSomeAndNotTooMany() {
        XCTAssertEqual(problem(everyone: false, people: 0), .nobodyChosen)
        XCTAssertNil(problem(everyone: false, people: 1))
        XCTAssertNil(problem(everyone: false, people: EventRules.maxPeople))
        XCTAssertEqual(problem(everyone: false, people: EventRules.maxPeople + 1), .tooManyPeople)
        XCTAssertNil(problem(everyone: true, people: 0), "Nobody needs naming when it's for the team")
    }

    func testEachProblemHasWordsAndAMatchingDatabaseError() {
        let all: [EventRules.Problem] = [.noTitle, .endNotAfterStart, .titleTooLong, .notesTooLong, .locationTooLong, .tooLong, .nobodyChosen, .tooManyPeople]
        for item in all {
            XCTAssertFalse(EventRules.message(for: item).isEmpty)
            XCTAssertFalse((item.error.errorDescription ?? "").isEmpty)
        }
        XCTAssertEqual(EventRules.Problem.noTitle.error, .invalidEvent)
        XCTAssertEqual(EventRules.Problem.titleTooLong.error, .eventTextTooLong)
        XCTAssertEqual(EventRules.Problem.tooLong.error, .eventTooLong)
    }

    // MARK: The draft

    func testADraftKnowsWhatIsWrongWithIt() {
        var draft = TeamEventDraft(startsAt: start, endsAt: start.addingTimeInterval(3600))
        XCTAssertEqual(draft.problem, .noTitle)
        draft.title = "Editing day"
        XCTAssertNil(draft.problem)
        draft.everyone = false
        XCTAssertEqual(draft.problem, .nobodyChosen)
        draft.memberIDs = [UUID()]
        XCTAssertNil(draft.problem)
    }

    func testEditingAnEventStartsFromWhatItSays() {
        let id = UUID()
        let person = UUID()
        let event = TeamEvent(
            id: id, organizationID: UUID(), title: "Trip", notes: "n", location: "Austin", startsAt: start, endsAt: start.addingTimeInterval(7200),
            allDay: false, everyone: false, blocksBookings: false, memberIDs: [person], createdBy: nil, createdByName: "", canEdit: true
        )
        let draft = TeamEventDraft(editing: event)
        XCTAssertEqual(draft.id, id)
        XCTAssertEqual(draft.title, "Trip")
        XCTAssertEqual(draft.memberIDs, [person])
        XCTAssertFalse(draft.blocksBookings)
        XCTAssertFalse(draft.everyone)
    }

    func testWhoAnEventIsFor() {
        let me = UUID()
        let other = UUID()
        var event = TeamEvent(
            id: UUID(), organizationID: UUID(), title: "x", notes: "", location: "", startsAt: start, endsAt: start.addingTimeInterval(60),
            allDay: false, everyone: true, blocksBookings: true, memberIDs: [], createdBy: nil, createdByName: "", canEdit: false
        )
        XCTAssertTrue(event.isFor(me))
        XCTAssertEqual(event.audience(names: [:]), "Everyone")
        event.everyone = false
        event.memberIDs = [other]
        XCTAssertFalse(event.isFor(me))
        XCTAssertTrue(event.isFor(other))
        XCTAssertEqual(event.audience(names: [other: "Theo"]), "Theo")
        XCTAssertEqual(event.audience(names: [:]), "Named people")
    }
}

// MARK: - Calendar links and the phone's calendar settings

final class CalendarLinkTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"
    private let project = URL(string: "https://example.supabase.co")!

    func testTheAddressIsOnTheProjectsFunctions() {
        let link = CalendarLink.make(projectURL: project, token: token)
        XCTAssertEqual(link.url.absoluteString, "https://example.supabase.co/functions/v1/calendar-feed/\(token).ics")
    }

    func testAppleCalendarSubscribesThroughWebcal() {
        let link = CalendarLink.make(projectURL: project, token: token)
        XCTAssertEqual(link.webcalURL.scheme, "webcal")
        XCTAssertEqual(link.webcalURL.host, "example.supabase.co")
        XCTAssertEqual(link.webcalURL.path, link.url.path)
    }

    func testGoogleCalendarGetsTheAddressInItsOwnAddPage() throws {
        let link = CalendarLink.make(projectURL: project, token: token)
        let google = try XCTUnwrap(link.googleURL)
        XCTAssertEqual(google.host, "calendar.google.com")
        let parts = try XCTUnwrap(URLComponents(url: google, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first { $0.name == "cid" }?.value, link.webcalURL.absoluteString)
    }

    func testSettingsSavedByAnOlderVersionStillLoad() throws {
        // What the app wrote before team events: none of the newer keys.
        let old = """
        {"blockBusyTimes":true,"busyCalendarIDs":["a","b"],"includeAllDayEvents":false,"addBookingsToCalendar":true,
         "destinationCalendarID":"work","eventIDs":[]}
        """
        let prefs = try JSONDecoder().decode(CalendarPreferences.self, from: Data(old.utf8))
        XCTAssertTrue(prefs.blockBusyTimes)
        XCTAssertEqual(prefs.busyCalendarIDs, ["a", "b"])
        XCTAssertTrue(prefs.addBookingsToCalendar)
        XCTAssertEqual(prefs.destinationCalendarID, "work")
        XCTAssertFalse(prefs.addTeamEventsToCalendar)
        XCTAssertTrue(prefs.teamEventMarks.isEmpty)
    }

    func testTheMarksOfEventsAddedToThePhoneSurviveSaving() throws {
        var prefs = CalendarPreferences()
        let id = UUID()
        prefs.addTeamEventsToCalendar = true
        prefs.teamEventMarks[id] = TeamEventMark(eventID: "EK-1", fingerprint: "f", startsAt: Date(timeIntervalSince1970: 100), endsAt: Date(timeIntervalSince1970: 200))
        let again = try JSONDecoder().decode(CalendarPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(again, prefs)
    }

    func testAnEventChangesItsFingerprintWhenWhatItSaysChanges() {
        var event = TeamEvent(
            id: UUID(), organizationID: UUID(), title: "Meeting", notes: "", location: "", startsAt: Date(timeIntervalSince1970: 1000),
            endsAt: Date(timeIntervalSince1970: 2000), allDay: false, everyone: true, blocksBookings: true, memberIDs: [], createdBy: nil,
            createdByName: "", canEdit: false
        )
        let before = AppModel.fingerprint(of: event)
        XCTAssertEqual(AppModel.fingerprint(of: event), before)
        event.title = "Meeting (moved)"
        XCTAssertNotEqual(AppModel.fingerprint(of: event), before)
        event.title = "Meeting"
        event.endsAt = Date(timeIntervalSince1970: 2600)
        XCTAssertNotEqual(AppModel.fingerprint(of: event), before)
        event.endsAt = Date(timeIntervalSince1970: 2000)
        // Who it is for, or whether it blocks bookings, doesn't change the calendar entry.
        event.everyone = false
        event.blocksBookings = false
        XCTAssertEqual(AppModel.fingerprint(of: event), before)
    }
}

// MARK: - The on-device backend

final class TeamEventBackendTests: TeamTestCase {
    private func draft(
        _ title: String = "Team meeting", start: Date? = nil, hours: Double = 1, everyone: Bool = true,
        members: Set<UUID> = [], blocks: Bool = true, allDay: Bool = false
    ) -> TeamEventDraft {
        let begin = start ?? TestClock.date(2027, 1, 8, 9, 0)
        var value = TeamEventDraft(startsAt: begin, endsAt: begin.addingTimeInterval(hours * 3600))
        value.title = title
        value.everyone = everyone
        value.memberIDs = members
        value.blocksBookings = blocks
        value.allDay = allDay
        return value
    }

    @discardableResult
    private func add(_ c: Company, by user: UUID, _ value: TeamEventDraft? = nil) async throws -> TeamEvent {
        try await backend.saveTeamEvent(value ?? draft(), organizationID: c.org.id, by: user)
    }

    private func events(_ c: Company, as user: UUID, from: Date? = nil, to: Date? = nil) async throws -> [TeamEvent] {
        try await backend.loadTeamEvents(
            organizationID: c.org.id, from: from ?? TestClock.date(2027, 1, 4), to: to ?? TestClock.date(2027, 2, 14), for: user
        )
    }

    /// A booking that is refused because the time is gone: taken, or not offered.
    private func expectRefused<T>(file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected the time to be refused", file: file, line: line)
        } catch {
            let refused = [SlateError.slotTaken, .slotUnavailable]
            XCTAssertTrue((error as? SlateError).map(refused.contains) ?? false, "\(error)", file: file, line: line)
        }
    }

    // MARK: Who can add

    func testOwnersAdminsManagersAndCreatorsCanAddAndViewersCannot() async throws {
        let c = try await makeCompany()
        for (name, user) in [("Owner", c.owner), ("Admin", c.admin), ("Manager", c.manager), ("Creator", c.theo)] {
            let event = try await add(c, by: user, draft("\(name)'s event"))
            XCTAssertEqual(event.title, "\(name)'s event")
            XCTAssertEqual(event.createdBy, user)
            XCTAssertTrue(event.canEdit, name)
        }
        await expectError(.notAllowed) { try await add(c, by: c.viewer) }
        await expectError(.notFound) { try await add(c, by: UUID()) }
    }

    func testATitleAndPlaceAreKeptOnOneLineAndNotesKeepTheirBreaks() async throws {
        let c = try await makeCompany()
        var value = draft("  Gear   check\nbefore the wedding ")
        value.location = " Studio\tB "
        value.notes = "Bring the 24-70\r\nand the gimbal"
        let event = try await add(c, by: c.theo, value)
        XCTAssertEqual(event.title, "Gear check before the wedding")
        XCTAssertEqual(event.location, "Studio B")
        XCTAssertEqual(event.notes, "Bring the 24-70\nand the gimbal")
        XCTAssertTrue(event.blocksBookings, "Events block bookings unless told otherwise")
    }

    func testWhatAnEventHasToBe() async throws {
        let c = try await makeCompany()
        await expectError(.invalidEvent) { try await add(c, by: c.admin, draft("   ")) }
        await expectError(.invalidEvent) { try await add(c, by: c.admin, draft(hours: 0)) }
        await expectError(.eventTextTooLong) { try await add(c, by: c.admin, draft(String(repeating: "x", count: 81))) }
        await expectError(.eventTooLong) { try await add(c, by: c.admin, draft(hours: Double(31 * 24 + 1))) }
        await expectError(.invalidEvent) { try await add(c, by: c.admin, draft(everyone: false, members: [])) }
        await expectError(.invalidAttendee) { try await add(c, by: c.admin, draft(everyone: false, members: [c.theo, UUID()])) }
        _ = try await add(c, by: c.admin, draft(String(repeating: "x", count: 80), hours: Double(31 * 24)))
    }

    func testAnEventForNamedPeopleKeepsThemAndAViewerCanBeNamed() async throws {
        let c = try await makeCompany()
        let event = try await add(c, by: c.admin, draft(everyone: false, members: [c.theo, c.viewer, c.theo]))
        XCTAssertFalse(event.everyone)
        XCTAssertEqual(Set(event.memberIDs), [c.theo, c.viewer])
        XCTAssertEqual(event.memberIDs.count, 2)
    }

    func testTooManyEventsThatHaventHappenedYet() async throws {
        let c = try await makeCompany()
        for index in 0..<EventRules.maxUpcoming {
            _ = try await add(c, by: c.owner, draft("Event \(index)", start: TestClock.date(2027, 1, 8, 9, 0).addingTimeInterval(Double(index) * 7200), hours: 1))
        }
        await expectError(.tooManyEvents) { try await add(c, by: c.owner, draft("One too many")) }
    }

    // MARK: Who can change or remove

    func testTheAuthorChangesTheirOwnAndManagersChangeAnyones() async throws {
        let c = try await makeCompany()
        let theos = try await add(c, by: c.theo, draft("Theo's errand"))
        var edit = TeamEventDraft(editing: theos)
        edit.title = "Theo's errand (moved)"
        let moved = try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: c.theo)
        XCTAssertEqual(moved.title, "Theo's errand (moved)")
        XCTAssertEqual(moved.id, theos.id)
        XCTAssertEqual(moved.createdBy, c.theo, "It keeps its author")

        edit.title = "Mine now"
        await expectError(.notAllowed) { try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: c.jun) }
        await expectError(.notAllowed) { try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: c.viewer) }
        await expectError(.notFound) { try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: UUID()) }
        for manager in [c.manager, c.admin, c.owner] {
            edit.title = "Changed by \(manager == c.manager ? "Noor" : "a leader")"
            let changed = try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: manager)
            XCTAssertEqual(changed.title, edit.title)
        }
        var missing = edit
        missing.id = UUID()
        await expectError(.notFound) { try await backend.saveTeamEvent(missing, organizationID: c.org.id, by: c.owner) }
    }

    func testTheListSaysWhoCanChangeWhich() async throws {
        let c = try await makeCompany()
        let theos = try await add(c, by: c.theo, draft("Theo's"))
        let juns = try await add(c, by: c.jun, draft("Jun's", start: TestClock.date(2027, 1, 8, 11, 0)))
        let asTheo = try await events(c, as: c.theo)
        XCTAssertEqual(asTheo.first { $0.id == theos.id }?.canEdit, true)
        XCTAssertEqual(asTheo.first { $0.id == juns.id }?.canEdit, false)
        let asManager = try await events(c, as: c.manager)
        XCTAssertTrue(asManager.allSatisfy(\.canEdit))
        let asViewer = try await events(c, as: c.viewer)
        XCTAssertFalse(asViewer.contains(where: \.canEdit))
        XCTAssertEqual(asViewer.first { $0.id == theos.id }?.createdByName, "Theo")
    }

    func testRemovingAnEvent() async throws {
        let c = try await makeCompany()
        let theos = try await add(c, by: c.theo)
        await expectError(.notAllowed) { try await backend.deleteTeamEvent(theos.id, by: c.jun) }
        await expectError(.notAllowed) { try await backend.deleteTeamEvent(theos.id, by: c.viewer) }
        await expectError(.notFound) { try await backend.deleteTeamEvent(theos.id, by: UUID()) }
        try await backend.deleteTeamEvent(theos.id, by: c.theo)
        let left = try await events(c, as: c.owner)
        XCTAssertTrue(left.isEmpty)
        await expectError(.notFound) { try await backend.deleteTeamEvent(theos.id, by: c.owner) }

        let other = try await add(c, by: c.jun)
        try await backend.deleteTeamEvent(other.id, by: c.manager)
    }

    // MARK: Reading

    func testEveryoneOnTheTeamSeesTheEventsAndOutsidersDont() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("All hands"))
        for user in [c.owner, c.admin, c.manager, c.theo, c.jun, c.viewer] {
            let seen = try await events(c, as: user)
            XCTAssertEqual(seen.map(\.title), ["All hands"])
        }
        await expectError(.notFound) { try await events(c, as: UUID()) }
    }

    func testAWindowIsCutToSixtyTwoDays() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("Soon", start: TestClock.date(2027, 1, 20, 9, 0)))
        _ = try await add(c, by: c.admin, draft("Far", start: TestClock.date(2027, 6, 1, 9, 0)))
        let seen = try await events(c, as: c.admin, from: TestClock.date(2027, 1, 4), to: TestClock.date(2027, 12, 31))
        XCTAssertEqual(seen.map(\.title), ["Soon"])
    }

    func testAPersonWhoLeavesDropsOutOfWhoItIsFor() async throws {
        let c = try await makeCompany()
        let event = try await add(c, by: c.admin, draft(everyone: false, members: [c.theo, c.jun]))
        try await backend.removeMember(memberID: c.jun, organizationID: c.org.id, by: c.owner)
        let seen = try await events(c, as: c.owner)
        XCTAssertEqual(seen.first { $0.id == event.id }?.memberIDs, [c.theo])
    }

    func testTheEventsThatAreForMeAcrossCompanies() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("All hands", start: TestClock.date(2027, 1, 8, 9, 0)))
        _ = try await add(c, by: c.admin, draft("Theo only", start: TestClock.date(2027, 1, 8, 11, 0), everyone: false, members: [c.theo]))
        let from = TestClock.date(2027, 1, 4)
        let to = TestClock.date(2027, 3, 1)
        let theos = try await backend.loadMyTeamEvents(from: from, to: to, for: c.theo)
        XCTAssertEqual(theos.map(\.title), ["All hands", "Theo only"])
        XCTAssertTrue(theos.allSatisfy { $0.organizationName == "Northlight Films" })
        let juns = try await backend.loadMyTeamEvents(from: from, to: to, for: c.jun)
        XCTAssertEqual(juns.map(\.title), ["All hands"])
        let viewers = try await backend.loadMyTeamEvents(from: from, to: to, for: c.viewer)
        XCTAssertEqual(viewers.map(\.title), ["All hands"])
        let nobody = try await backend.loadMyTeamEvents(from: from, to: to, for: UUID())
        XCTAssertTrue(nobody.isEmpty)
    }

    // MARK: Time they take

    func testAnEventKeepsClientsFromBookingThePeopleItIsFor() async throws {
        let c = try await makeCompany()
        let wedMorning = TestClock.date(2027, 1, 6, 9, 0)
        _ = try await add(c, by: c.admin, draft("Theo edits", start: wedMorning, hours: 3, everyone: false, members: [c.theo]))

        let first = try await book(c, at: wednesday(10))
        XCTAssertEqual(first.booking.assignedTo, c.jun, "Theo is in the event, so it goes to Jun")
        await expectRefused { try await book(c, at: wednesday(10)) }
        await expectRefused { try await book(c, at: wednesday(10), member: c.theo) }
    }

    func testTheUsualBufferFollowsAnEvent() async throws {
        let c = try await makeCompany()
        // The company keeps 30 minutes after busy time. An all-hands from 9 to 10 holds 10:00 too, but not 10:30.
        _ = try await add(c, by: c.admin, draft("All hands", start: TestClock.date(2027, 1, 6, 9, 0), hours: 1))
        await expectRefused { try await book(c, at: wednesday(9)) }
        await expectRefused { try await book(c, at: wednesday(10)) }
        let after = try await book(c, at: wednesday(10, 30))
        XCTAssertNotNil(after.booking.assignedTo)
    }

    func testAnEventThatDoesNotBlockLeavesTheTimeBookable() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("Just a note", start: TestClock.date(2027, 1, 6, 9, 0), hours: 1, blocks: false))
        let booked = try await book(c, at: wednesday(9))
        XCTAssertNotNil(booked.booking.assignedTo)
    }

    func testMovingOrRemovingAnEventFreesTheTime() async throws {
        let c = try await makeCompany()
        let event = try await add(c, by: c.admin, draft("All hands", start: TestClock.date(2027, 1, 6, 9, 0), hours: 1))
        await expectRefused { try await book(c, at: wednesday(9)) }

        var move = TeamEventDraft(editing: event)
        move.startsAt = TestClock.date(2027, 1, 6, 14, 0)
        move.endsAt = TestClock.date(2027, 1, 6, 15, 0)
        _ = try await backend.saveTeamEvent(move, organizationID: c.org.id, by: c.admin)
        _ = try await book(c, at: wednesday(9))
        await expectRefused { try await book(c, at: wednesday(14)) }

        try await backend.deleteTeamEvent(event.id, by: c.admin)
        _ = try await book(c, at: wednesday(14))
    }

    func testAnEventAddedOverABookingLeavesTheBookingAlone() async throws {
        let c = try await makeCompany()
        let booked = try await book(c, at: wednesday(10))
        _ = try await add(c, by: c.admin, draft("Oops, same time", start: TestClock.date(2027, 1, 6, 10, 0), hours: 2))
        let mine = try await backend.loadBookings(for: c.owner)
        XCTAssertEqual(mine.first { $0.id == booked.booking.id }?.status, .confirmed)
    }

    func testTheBookingPageSeesTheEventAsBusyTime() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("Theo edits", start: TestClock.date(2027, 1, 6, 9, 0), hours: 3, everyone: false, members: [c.theo]))
        let schedule = try await backend.loadTeamSchedule(
            packageID: c.package.id, memberID: nil, from: TestClock.date(2027, 1, 6), to: TestClock.date(2027, 1, 7)
        )
        let theo = try XCTUnwrap(schedule.members.first { $0.userID == c.theo })
        let jun = try XCTUnwrap(schedule.members.first { $0.userID == c.jun })
        XCTAssertTrue(theo.busy.contains { $0.start == TestClock.date(2027, 1, 6, 9, 0) && $0.end == TestClock.date(2027, 1, 6, 12, 30) },
                      "The event plus the buffer after it")
        XCTAssertTrue(jun.busy.isEmpty)
    }

    func testTheTeamCalendarDrawsItAsBusyTimeOfItsOwnKind() async throws {
        let c = try await makeCompany()
        _ = try await add(c, by: c.admin, draft("Theo edits", start: TestClock.date(2027, 1, 6, 9, 0), hours: 3, everyone: false, members: [c.theo]))
        let calendar = try await backend.loadTeamCalendar(
            organizationID: c.org.id, from: TestClock.date(2027, 1, 6), to: TestClock.date(2027, 1, 7), members: [], for: c.owner
        )
        let theo = try XCTUnwrap(calendar.members.first { $0.userID == c.theo })
        XCTAssertTrue(theo.busy.contains { $0.kind == .event && $0.range.duration == 3 * 3600 })
        let jun = try XCTUnwrap(calendar.members.first { $0.userID == c.jun })
        XCTAssertFalse(jun.busy.contains { $0.kind == .event })
    }

    // MARK: The log

    func testAddingChangingAndRemovingAreLogged() async throws {
        let c = try await makeCompany()
        let event = try await add(c, by: c.theo, draft("Gear check"))
        var edit = TeamEventDraft(editing: event)
        edit.title = "Gear check (late)"
        _ = try await backend.saveTeamEvent(edit, organizationID: c.org.id, by: c.manager)
        try await backend.deleteTeamEvent(event.id, by: c.manager)

        let log = try await activity(c)
        XCTAssertTrue(log.contains { $0.action == "event.created" && $0.summary == "Added the event \"Gear check\"" && $0.actorName == "Theo" })
        XCTAssertTrue(log.contains { $0.action == "event.updated" && $0.summary == "Changed the event \"Gear check (late)\"" && $0.actorName == "Noor" })
        XCTAssertTrue(log.contains { $0.action == "event.deleted" && $0.summary == "Removed the event \"Gear check (late)\"" })
    }

    // MARK: Calendar links

    func testAnOnDeviceAccountHasNoCalendarLink() async throws {
        let owner = try await person("Dana")
        let link = try await backend.calendarLink(for: owner)
        XCTAssertNil(link)
        let reset = try await backend.resetCalendarLink(for: owner)
        XCTAssertNil(reset)
    }
}

// MARK: - What the server returns

/// The Supabase backend against what the database really returns. `Fixtures/event_rows.json` is written by
/// `supabase/tests/event_rules.py --dump`, and that script fails if the database stops matching it.
final class TeamEventRowDecodingTests: XCTestCase {
    private var rows: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "event_rows", withExtension: "json"), "event_rows.json is missing from the test bundle")
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
        let value = try XCTUnwrap(rows[key], "\(key) is missing from event_rows.json")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder().decode(type, from: data)
    }

    func testAnEventAsSaved() throws {
        let row: SupabaseBackend.TeamEventRow = try load("event")
        let event = try XCTUnwrap(row.event)
        XCTAssertEqual(event.title, "Shape check")
        XCTAssertFalse(event.everyone)
        XCTAssertEqual(event.memberIDs.count, 1)
        XCTAssertTrue(event.blocksBookings)
        XCTAssertTrue(event.canEdit)
        XCTAssertGreaterThan(event.endsAt, event.startsAt)
        XCTAssertEqual(event.organizationName, "", "Only the list of my events carries the company's name")
    }

    func testTheTeamsList() throws {
        let list: [SupabaseBackend.TeamEventRow] = try load("events")
        XCTAssertFalse(list.isEmpty)
        XCTAssertEqual(list.compactMap(\.event).count, list.count)
    }

    func testMyEventsNameTheirCompany() throws {
        let list: [SupabaseBackend.TeamEventRow] = try load("mine")
        let event = try XCTUnwrap(list.first?.event)
        XCTAssertEqual(event.organizationName, "Acme Films")
    }

    func testEveryNewErrorTokenBecomesATypedError() {
        struct Raised: Error, CustomStringConvertible { var description: String }
        let expected: [(String, SlateError)] = [
            ("invalid_event", .invalidEvent), ("event_text_too_long", .eventTextTooLong), ("event_too_long", .eventTooLong),
            ("too_many_events", .tooManyEvents), ("invalid_attendee", .invalidAttendee), ("not_allowed", .notAllowed),
        ]
        for (token, error) in expected {
            XCTAssertEqual(SupabaseBackend.mapTeamError(Raised(description: "PostgrestError: \(token)")) as? SlateError, error, token)
        }
    }
}

import Foundation

// MARK: - A team event

/// Something on a company's team calendar that isn't a booking: a meeting, an editing day, a day off. It is for the whole
/// team or for the people named, and while it lasts a client can't book them (unless it says it doesn't block bookings).
/// Mirrors `public.team_events` and `team_event_json()` in `…_team_events.sql`.
struct TeamEvent: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    var organizationID: UUID
    var title: String
    var notes: String
    var location: String
    var startsAt: Date
    var endsAt: Date
    /// Only changes how it is drawn: the times already run from midnight to midnight in the company's time zone.
    var allDay: Bool
    var everyone: Bool
    var blocksBookings: Bool
    /// The people it is for when it isn't for everyone (only those still in the team).
    var memberIDs: [UUID]
    var createdBy: UUID?
    var createdByName: String
    /// Whether the person who asked may change or remove it.
    var canEdit: Bool
    /// Which company it is from. Only set for the events that are for me across companies.
    var organizationName: String = ""

    var interval: DateInterval { DateInterval(start: startsAt, end: max(endsAt, startsAt)) }

    /// Whether the event is for this person.
    func isFor(_ userID: UUID) -> Bool { everyone || memberIDs.contains(userID) }

    /// "Everyone", or the people it is for, from the names the caller has.
    func audience(names: [UUID: String]) -> String {
        if everyone { return "Everyone" }
        let people = memberIDs.compactMap { names[$0] }.filter { !$0.isEmpty }
        return people.isEmpty ? "Named people" : people.joined(separator: ", ")
    }
}

/// What the editor holds while someone adds or changes an event.
struct TeamEventDraft: Equatable {
    /// Nil for a new event.
    var id: UUID?
    var title = ""
    var notes = ""
    var location = ""
    var startsAt: Date
    var endsAt: Date
    var allDay = false
    var everyone = true
    var memberIDs: Set<UUID> = []
    var blocksBookings = true

    init(startsAt: Date, endsAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    init(editing event: TeamEvent) {
        id = event.id
        title = event.title
        notes = event.notes
        location = event.location
        startsAt = event.startsAt
        endsAt = event.endsAt
        allDay = event.allDay
        everyone = event.everyone
        memberIDs = Set(event.memberIDs)
        blocksBookings = event.blocksBookings
    }

    /// The first thing wrong with it, or nil when it can be saved.
    var problem: EventRules.Problem? {
        EventRules.problem(
            title: title, notes: notes, location: location, startsAt: startsAt, endsAt: endsAt,
            everyone: everyone, people: memberIDs.count
        )
    }
}

// MARK: - Rules

/// What an event may be. Mirrors the checks in `team_event_save()`; `SlateTests/Fixtures/event_rules.json` is read by the
/// Swift tests and by `supabase/tests/event_rules.py`, so the numbers and the text cleaning cannot drift apart.
enum EventRules {
    static let titleMaxLength = 80
    static let notesMaxLength = 500
    static let locationMaxLength = 120
    /// The longest one event may run, for a trip or a stretch of leave.
    static let maxDays = 31
    /// How many events that haven't ended a company may have at once.
    static let maxUpcoming = 500
    /// How many people one event can name.
    static let maxPeople = 50

    enum Problem: Equatable {
        case noTitle, endNotAfterStart, titleTooLong, notesTooLong, locationTooLong, tooLong, nobodyChosen, tooManyPeople

        /// What the database would have said.
        var error: SlateError {
            switch self {
            case .noTitle, .endNotAfterStart, .nobodyChosen, .tooManyPeople: .invalidEvent
            case .titleTooLong, .notesTooLong, .locationTooLong: .eventTextTooLong
            case .tooLong: .eventTooLong
            }
        }
    }

    private static let spaces: Set<Unicode.Scalar> = [" ", "\n", "\t"]

    /// A title or place as it is kept: one line, no control characters, single spaces, none at either end.
    /// Works on Unicode scalars like `MessageRules.clean`, so it counts and splits the way SQL does.
    static func cleanLine(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in MessageRules.clean(text).unicodeScalars {
            if spaces.contains(scalar) {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                pendingSpace = false
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// Notes keep their line breaks; otherwise they are tidied like a message.
    static func cleanNotes(_ text: String) -> String { MessageRules.clean(text) }

    static func length(of text: String) -> Int { text.unicodeScalars.count }

    /// The first thing wrong, checked in the order the database checks.
    static func problem(
        title: String, notes: String, location: String, startsAt: Date, endsAt: Date, everyone: Bool, people: Int
    ) -> Problem? {
        let cleanedTitle = cleanLine(title)
        if cleanedTitle.isEmpty || endsAt <= startsAt { return cleanedTitle.isEmpty ? .noTitle : .endNotAfterStart }
        if length(of: cleanedTitle) > titleMaxLength { return .titleTooLong }
        if length(of: cleanNotes(notes)) > notesMaxLength { return .notesTooLong }
        if length(of: cleanLine(location)) > locationMaxLength { return .locationTooLong }
        if endsAt.timeIntervalSince(startsAt) > Double(maxDays) * 86_400 { return .tooLong }
        if !everyone {
            if people == 0 { return .nobodyChosen }
            if people > maxPeople { return .tooManyPeople }
        }
        return nil
    }

    /// Words for the editor, next to the field that needs fixing.
    static func message(for problem: Problem) -> String {
        switch problem {
        case .noTitle: "Give the event a name."
        case .endNotAfterStart: "The event has to end after it starts."
        case .titleTooLong: "The name can be up to \(titleMaxLength) characters."
        case .notesTooLong: "Notes can be up to \(notesMaxLength) characters."
        case .locationTooLong: "The place can be up to \(locationMaxLength) characters."
        case .tooLong: "An event can run for up to \(maxDays) days."
        case .nobodyChosen: "Choose who it is for."
        case .tooManyPeople: "An event can name up to \(maxPeople) people."
        }
    }
}

// MARK: - Calendar links

/// The private web address other calendar apps read to show a person's bookings and team events, and the one-tap ways to
/// subscribe to it. Whoever has the address can read the calendar, so it is shown only to its owner and can be replaced.
struct CalendarLink: Equatable {
    var url: URL

    /// `webcal://` makes Apple Calendar offer to subscribe instead of downloading a file.
    var webcalURL: URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "webcal"
        return parts?.url ?? url
    }

    /// Google Calendar's own "add by link" page, with this address filled in.
    var googleURL: URL? {
        var parts = URLComponents(string: "https://calendar.google.com/calendar/r")
        parts?.queryItems = [URLQueryItem(name: "cid", value: webcalURL.absoluteString)]
        return parts?.url
    }

    static func make(projectURL: URL, token: String) -> CalendarLink {
        CalendarLink(url: projectURL.appendingPathComponent("functions/v1/calendar-feed/\(token).ics"))
    }
}

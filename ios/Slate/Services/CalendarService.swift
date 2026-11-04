import EventKit
import Foundation

struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    let allowsModifications: Bool
    /// Holidays and birthdays are noisy for availability, so they start switched off.
    let isNoisy: Bool
}

/// A team event that was put in this phone's calendar, so it can be changed or removed when the event is.
struct TeamEventMark: Codable, Equatable {
    /// EventKit's identifier for the calendar event.
    var eventID: String
    /// What the event said when it was last copied, to tell when it has changed.
    var fingerprint: String
    var startsAt: Date
    var endsAt: Date
}

/// Per-device calendar settings. Calendar identifiers only mean something on the device that
/// owns them, so these are stored locally and never sent to the server.
struct CalendarPreferences: Codable, Equatable {
    /// Treat busy time in the chosen calendars as unavailable for booking.
    var blockBusyTimes = false
    var busyCalendarIDs: Set<String> = []
    /// All-day events (birthdays, holidays, "out of office") usually shouldn't block a whole day.
    var includeAllDayEvents = false
    /// Add confirmed bookings to the calendar automatically.
    var addBookingsToCalendar = false
    var destinationCalendarID: String?
    /// Booking id to the event it created, so nothing is added twice and cancellations can remove it.
    var eventIDs: [UUID: String] = [:]
    var lastBusySync: Date?
    /// Add the team events that are for this person to the calendar too, and keep them up to date.
    var addTeamEventsToCalendar = false
    /// Team event id to what was copied, so changes and removals follow.
    var teamEventMarks: [UUID: TeamEventMark] = [:]

    init() {}

    /// Settings saved by an older version don't have the newer keys; they keep what they had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockBusyTimes = try container.decodeIfPresent(Bool.self, forKey: .blockBusyTimes) ?? false
        busyCalendarIDs = try container.decodeIfPresent(Set<String>.self, forKey: .busyCalendarIDs) ?? []
        includeAllDayEvents = try container.decodeIfPresent(Bool.self, forKey: .includeAllDayEvents) ?? false
        addBookingsToCalendar = try container.decodeIfPresent(Bool.self, forKey: .addBookingsToCalendar) ?? false
        destinationCalendarID = try container.decodeIfPresent(String.self, forKey: .destinationCalendarID)
        eventIDs = try container.decodeIfPresent([UUID: String].self, forKey: .eventIDs) ?? [:]
        lastBusySync = try container.decodeIfPresent(Date.self, forKey: .lastBusySync)
        addTeamEventsToCalendar = try container.decodeIfPresent(Bool.self, forKey: .addTeamEventsToCalendar) ?? false
        teamEventMarks = try container.decodeIfPresent([UUID: TeamEventMark].self, forKey: .teamEventMarks) ?? [:]
    }

    private static let key = "slate.calendarPreferences"

    static func load(from defaults: UserDefaults = .standard) -> CalendarPreferences {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(CalendarPreferences.self, from: data)
        else { return CalendarPreferences() }
        return stored
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// Everything that touches EventKit. Kept thin: deciding *what* to sync lives in `AppModel`.
@MainActor
final class CalendarService {
    enum Access: Equatable {
        case notDetermined, denied, restricted, writeOnly, full

        var canWrite: Bool { self == .writeOnly || self == .full }
        var canRead: Bool { self == .full }
    }

    private var store = EKEventStore()

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .full
        case .authorized: .full
        @unknown default: .denied
        }
    }

    // MARK: Permission

    /// Needed to read busy time. Asked for only when the creator turns that feature on.
    func requestFullAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { store = EKEventStore() } // Start fresh so the new permission is picked up.
        return granted
    }

    /// Enough to add a booking to the calendar, and no more. This is what clients are asked for.
    func requestWriteOnlyAccess() async -> Bool {
        let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        if granted { store = EKEventStore() }
        return granted
    }

    // MARK: Calendars

    func calendars() -> [CalendarInfo] {
        guard access.canRead else { return [] }
        return store.calendars(for: .event)
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    allowsModifications: calendar.allowsContentModifications,
                    isNoisy: calendar.type == .birthday || calendar.type == .subscription
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func defaultBusyCalendarIDs() -> Set<String> {
        Set(calendars().filter { !$0.isNoisy }.map(\.id))
    }

    func defaultDestinationCalendarID() -> String? {
        store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    // MARK: Reading busy time

    /// Merged busy intervals, with no titles, locations or attendees: just start and end.
    func busyIntervals(from start: Date, to end: Date, calendarIDs: Set<String>, includeAllDay: Bool) -> [DateInterval] {
        guard access.canRead, end > start else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var intervals: [DateInterval] = []
        for event in store.events(matching: predicate) where Self.blocksTime(event, includeAllDay: includeAllDay) {
            let clippedStart = max(event.startDate, start)
            let clippedEnd = min(event.endDate, end)
            if clippedEnd > clippedStart {
                intervals.append(DateInterval(start: clippedStart, end: clippedEnd))
            }
        }
        return IntervalMath.merge(intervals)
    }

    private static func blocksTime(_ event: EKEvent, includeAllDay: Bool) -> Bool {
        if event.status == .canceled { return false }
        if event.isAllDay && !includeAllDay { return false }
        if event.availability == .free { return false }
        // Bookings we wrote ourselves are already known to the server; counting them again would
        // keep a slot blocked after the booking is cancelled.
        if event.url?.scheme == AppConfig.urlScheme { return false }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
            return false
        }
        return true
    }

    // MARK: Writing bookings

    /// Adds `booking` to the calendar and returns the event's identifier.
    func addEvent(for booking: Booking, asCreator: Bool, calendarID: String?) throws -> String {
        let event = EKEvent(eventStore: store)
        // With write-only access the store can't look calendars up by id, so fall back to the default.
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) }
        event.calendar = (chosen?.allowsContentModifications == true ? chosen : nil) ?? store.defaultCalendarForNewEvents

        event.title = asCreator
            ? "\(booking.packageName): \(booking.clientName.isEmpty ? "Client" : booking.clientName)"
            : "\(booking.packageName) with \(booking.creatorName)"
        event.startDate = booking.startAt
        event.endDate = booking.endAt
        event.timeZone = booking.timeZone
        event.notes = booking.notes.isEmpty ? nil : booking.notes
        event.url = URL(string: "\(AppConfig.urlScheme)://booking/\(booking.id.uuidString.lowercased())")
        event.addAlarm(EKAlarm(relativeOffset: -3600))
        event.addAlarm(EKAlarm(relativeOffset: -86_400))

        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    // MARK: Writing team events

    /// Adds a team event to the calendar and returns the event's identifier. The link back into the app is what keeps
    /// the busy-time reader from counting it again (the server already counts an event that blocks bookings).
    func addEvent(for event: TeamEvent, calendarID: String?) throws -> String {
        let created = EKEvent(eventStore: store)
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) }
        created.calendar = (chosen?.allowsContentModifications == true ? chosen : nil) ?? store.defaultCalendarForNewEvents
        fill(created, from: event)
        try store.save(created, span: .thisEvent, commit: true)
        return created.eventIdentifier ?? ""
    }

    /// Brings an event already in the calendar up to date. False when it can't be found (the person removed it).
    func updateEvent(identifier: String, for event: TeamEvent) throws -> Bool {
        guard access.canRead, !identifier.isEmpty, let existing = store.event(withIdentifier: identifier) else { return false }
        fill(existing, from: event)
        try store.save(existing, span: .thisEvent, commit: true)
        return true
    }

    private func fill(_ target: EKEvent, from event: TeamEvent) {
        target.title = event.title
        target.location = event.location.isEmpty ? nil : event.location
        let about = [event.organizationName.isEmpty ? nil : "\(event.organizationName) team event", event.notes.isEmpty ? nil : event.notes]
            .compactMap { $0 }.joined(separator: "\n\n")
        target.notes = about.isEmpty ? nil : about
        target.isAllDay = event.allDay
        target.startDate = event.startsAt
        // An all-day event runs to the end of its last day, so it ends a moment before the midnight it is stored with.
        target.endDate = event.allDay ? event.endsAt.addingTimeInterval(-1) : event.endsAt
        target.url = URL(string: "\(AppConfig.urlScheme)://event/\(event.id.uuidString.lowercased())")
        target.alarms = event.allDay ? [] : [EKAlarm(relativeOffset: -900)]
    }

    /// Removes a previously added event. Needs full access to find it again; with write-only
    /// access this quietly does nothing.
    func removeEvent(identifier: String) throws {
        guard access.canRead, !identifier.isEmpty, let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }
}

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

    /// Removes a previously added event. Needs full access to find it again; with write-only
    /// access this quietly does nothing.
    func removeEvent(identifier: String) throws {
        guard access.canRead, !identifier.isEmpty, let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }
}

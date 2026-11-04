import EventKit
import Foundation

extension AppModel {
    func updateCalendarPrefs(_ change: (inout CalendarPreferences) -> Void) {
        var updated = calendarPrefs
        change(&updated)
        calendarPrefs = updated
        updated.save()
    }

    func refreshCalendarAccess() {
        calendarAccess = calendar.access
    }

    // MARK: - Turning features on and off

    /// Asks for full calendar access (needed to read busy time) and starts syncing.
    func enableBlockBusyTimes() async -> Bool {
        if !calendar.access.canRead {
            _ = await calendar.requestFullAccess()
        }
        calendarAccess = calendar.access
        guard calendarAccess.canRead else { return false }

        let defaults = calendar.defaultBusyCalendarIDs()
        updateCalendarPrefs { prefs in
            prefs.blockBusyTimes = true
            if prefs.busyCalendarIDs.isEmpty { prefs.busyCalendarIDs = defaults }
        }
        await syncBusyTime()
        return true
    }

    func disableBlockBusyTimes() async {
        updateCalendarPrefs { prefs in
            prefs.blockBusyTimes = false
            prefs.lastBusySync = nil
        }
        // Take the imported time off the server too, so clients can book those hours again.
        if let userID = session?.userID {
            try? await backend.replaceBusyBlocks([], for: userID)
        }
    }

    /// Adds confirmed bookings to the calendar automatically. Needs only write access.
    func enableAddBookingsToCalendar() async -> Bool {
        if !calendar.access.canWrite {
            _ = await calendar.requestWriteOnlyAccess()
        }
        calendarAccess = calendar.access
        guard calendarAccess.canWrite else { return false }

        let destination = calendar.defaultDestinationCalendarID()
        updateCalendarPrefs { prefs in
            prefs.addBookingsToCalendar = true
            if prefs.destinationCalendarID == nil { prefs.destinationCalendarID = destination }
        }
        await syncBookingEvents()
        return true
    }

    func disableAddBookingsToCalendar() {
        updateCalendarPrefs { $0.addBookingsToCalendar = false }
    }

    /// Adds the team events that are for this person to the calendar too. Needs full access, because keeping them in step
    /// means finding them again to change or remove them.
    func enableAddTeamEventsToCalendar() async -> Bool {
        if !calendar.access.canRead {
            _ = await calendar.requestFullAccess()
        }
        calendarAccess = calendar.access
        guard calendarAccess.canRead else { return false }

        let destination = calendar.defaultDestinationCalendarID()
        updateCalendarPrefs { prefs in
            prefs.addTeamEventsToCalendar = true
            if prefs.destinationCalendarID == nil { prefs.destinationCalendarID = destination }
        }
        await syncTeamEvents()
        return true
    }

    /// Stops adding them, and takes the ones this app added back out, so the calendar is as it was.
    func disableAddTeamEventsToCalendar() {
        for mark in calendarPrefs.teamEventMarks.values {
            try? calendar.removeEvent(identifier: mark.eventID)
        }
        updateCalendarPrefs { prefs in
            prefs.addTeamEventsToCalendar = false
            prefs.teamEventMarks = [:]
        }
    }

    // MARK: - Syncing

    func syncCalendar() async {
        calendarAccess = calendar.access
        await syncBusyTime()
        await syncBookingEvents()
        await syncTeamEvents()
    }

    /// Uploads merged busy intervals from the chosen calendars. Never titles, places or people.
    func syncBusyTime() async {
        guard let userID = session?.userID, profile != nil,
              calendarPrefs.blockBusyTimes, calendar.access.canRead
        else { return }

        let now = Date()
        let days = min(availability?.maxAdvanceDays ?? 180, 365)
        let blocks = calendar.busyIntervals(
            from: now,
            to: now.addingTimeInterval(Double(days) * 86_400),
            calendarIDs: calendarPrefs.busyCalendarIDs,
            includeAllDay: calendarPrefs.includeAllDayEvents
        )
        do {
            try await backend.replaceBusyBlocks(blocks, for: userID)
            updateCalendarPrefs { $0.lastBusySync = Date() }
        } catch {
            // Not worth interrupting someone for; the next sync will try again.
        }
    }

    /// Adds events for new confirmed bookings and removes events for cancelled ones.
    func syncBookingEvents() async {
        guard calendarPrefs.addBookingsToCalendar, calendar.access.canWrite,
              let userID = session?.userID
        else { return }

        let now = Date()
        // The shoots that are the person's: their own, and the company jobs given to them.
        for booking in bookings where booking.isProviderFor(userID) {
            let existing = calendarPrefs.eventIDs[booking.id]
            if booking.status == .confirmed, booking.endAt > now, existing == nil {
                if let eventID = try? calendar.addEvent(
                    for: booking, asCreator: true, calendarID: calendarPrefs.destinationCalendarID
                ) {
                    updateCalendarPrefs { $0.eventIDs[booking.id] = eventID }
                }
            } else if booking.status == .cancelled, existing != nil {
                removeCalendarEvent(for: booking)
            }
        }
    }

    /// Keeps the team events that are for this person in the calendar: adds new ones, brings changed ones up to date, and
    /// removes those that were cancelled or are no longer theirs. Looks six months ahead.
    func syncTeamEvents() async {
        guard calendarPrefs.addTeamEventsToCalendar, calendar.access.canRead, let userID = session?.userID else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(180 * 86_400)
        guard let mine = try? await backend.loadMyTeamEvents(from: now.addingTimeInterval(-86_400), to: horizon, for: userID) else { return }

        var marks = calendarPrefs.teamEventMarks
        for event in mine {
            let fingerprint = Self.fingerprint(of: event)
            if let mark = marks[event.id] {
                guard mark.fingerprint != fingerprint else { continue }
                // If the person deleted it from their calendar themselves, it stays deleted; only the note is brought up to date.
                _ = try? calendar.updateEvent(identifier: mark.eventID, for: event)
                marks[event.id] = TeamEventMark(eventID: mark.eventID, fingerprint: fingerprint, startsAt: event.startsAt, endsAt: event.endsAt)
            } else if event.endsAt > now,
                      let eventID = try? calendar.addEvent(for: event, calendarID: calendarPrefs.destinationCalendarID) {
                marks[event.id] = TeamEventMark(eventID: eventID, fingerprint: fingerprint, startsAt: event.startsAt, endsAt: event.endsAt)
            }
        }
        let seen = Set(mine.map(\.id))
        for (id, mark) in marks where !seen.contains(id) {
            // One that is over is just forgotten. One inside the stretch we looked at that didn't come back was removed.
            if mark.endsAt > now.addingTimeInterval(-86_400), mark.startsAt < horizon {
                try? calendar.removeEvent(identifier: mark.eventID)
            }
            marks[id] = nil
        }
        updateCalendarPrefs { $0.teamEventMarks = marks }
    }

    /// What an event says, for telling when it has changed.
    nonisolated static func fingerprint(of event: TeamEvent) -> String {
        [event.title, event.location, event.notes, event.organizationName, "\(event.startsAt.timeIntervalSince1970)",
         "\(event.endsAt.timeIntervalSince1970)", event.allDay ? "day" : "timed"].joined(separator: "\u{1F}")
    }

    func removeCalendarEvent(for booking: Booking) {
        guard let eventID = calendarPrefs.eventIDs[booking.id] else { return }
        try? calendar.removeEvent(identifier: eventID)
        updateCalendarPrefs { $0.eventIDs[booking.id] = nil }
    }

    /// Adds one booking to the calendar on request. Clients only ever need write access.
    func addToCalendar(_ booking: Booking) async throws {
        if calendar.access == .notDetermined {
            _ = await calendar.requestWriteOnlyAccess()
        }
        calendarAccess = calendar.access
        guard calendarAccess.canWrite else { throw SlateError.calendarAccessDenied }

        let eventID = try calendar.addEvent(
            for: booking,
            asCreator: isMine(booking),
            calendarID: calendarPrefs.destinationCalendarID
        )
        updateCalendarPrefs { $0.eventIDs[booking.id] = eventID }
    }

    func hasCalendarEvent(for booking: Booking) -> Bool {
        calendarPrefs.eventIDs[booking.id] != nil
    }
}

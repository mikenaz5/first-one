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

    // MARK: - Syncing

    func syncCalendar() async {
        calendarAccess = calendar.access
        await syncBusyTime()
        await syncBookingEvents()
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

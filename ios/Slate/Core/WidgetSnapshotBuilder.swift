import Foundation

/// Works out what the home screen widget should show from the person's bookings.
enum WidgetSnapshotBuilder {
    /// The widget's biggest layout lists three.
    static let capacity = 3

    static func make(bookings: [Booking], userID: UUID?, now: Date) -> WidgetSnapshot {
        guard let userID else { return .signedOut }
        let upcoming = bookings
            .filter { ($0.creatorID == userID || $0.clientID == userID) && $0.effectiveStatus(at: now) == .confirmed && $0.endAt > now }
            .sorted { ($0.startAt, $0.id.uuidString) < ($1.startAt, $1.id.uuidString) }
        return WidgetSnapshot(
            state: .signedIn,
            bookings: upcoming.prefix(capacity).map { booking in
                WidgetBooking(
                    id: booking.id, title: booking.packageName, counterpart: counterpart(of: booking, for: userID),
                    startAt: booking.startAt, endAt: booking.endAt, timeZoneID: booking.timeZoneID
                )
            }
        )
    }

    /// Who the booking is with, from this person's side (the same words as the Bookings list).
    static func counterpart(of booking: Booking, for userID: UUID) -> String {
        if booking.creatorID == booking.clientID { return "Test booking (you)" }
        if booking.creatorID == userID {
            let client = booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            return client.isEmpty ? "Client" : "Client: \(client)"
        }
        return "with \(booking.creatorName)"
    }
}

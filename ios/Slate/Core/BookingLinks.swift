import Foundation

/// Finds the creator's name in whatever a client pasted: `slate://book/maya`, `https://slate.example/maya`,
/// `slate.example/maya`, `@maya` or just `maya`.
enum BookingLinkText {
    static func handle(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let link = AppLink(url: url) {
            if case .creatorPage(let handle) = link { return valid(handle) }
            return nil
        }

        var text = trimmed.lowercased()
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let host = AppConfig.bookingLinkHost.lowercased()
        if text.hasPrefix(host + "/") { text = String(text.dropFirst(host.count + 1)) }
        // Only the first piece of the path is the name; drop a trailing slash, query or "@".
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/@ "))
        let first = text.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return valid(first)
    }

    private static func valid(_ handle: String) -> String? {
        let lowered = handle.lowercased()
        return HandleRules.validate(lowered) == nil ? lowered : nil
    }
}

/// A creator a client has booked, for the Creators tab.
struct BookedCreator: Identifiable, Equatable {
    var id: UUID
    var name: String
    var bookingCount: Int
    var lastBookedAt: Date
}

enum BookedCreators {
    /// The creators this person has booked, most recently booked first. Cancelled and lapsed bookings don't count.
    static func list(from bookings: [Booking], clientID: UUID) -> [BookedCreator] {
        var byCreator: [UUID: BookedCreator] = [:]
        for booking in bookings where booking.clientID == clientID && booking.status != .cancelled && booking.status != .expired {
            if var existing = byCreator[booking.creatorID] {
                existing.bookingCount += 1
                if booking.createdAt > existing.lastBookedAt {
                    existing.lastBookedAt = booking.createdAt
                    existing.name = booking.creatorName
                }
                byCreator[booking.creatorID] = existing
            } else {
                byCreator[booking.creatorID] = BookedCreator(
                    id: booking.creatorID, name: booking.creatorName, bookingCount: 1, lastBookedAt: booking.createdAt
                )
            }
        }
        return byCreator.values.sorted { $0.lastBookedAt > $1.lastBookedAt }
    }
}

import Foundation

/// Finding a creator to book by what a client types: a name, a link name or a specialty. The database does this for a
/// real account (`search_creators`); on a device with no server `LocalBackend` follows the same rules, so what shows up
/// is the same.
enum CreatorSearchRules {
    static let minLength = 2
    static let maxLength = 60
    static let defaultLimit = 20
    static let maxLimit = 30

    /// The words with single spaces, or nil when there are too few or too many characters to search for. Spacing
    /// doesn't count toward the length, and case doesn't matter.
    static func clean(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let length = words.filter { !$0.isWhitespace }.count
        return (minLength...maxLength).contains(length) ? words : nil
    }

    /// Whether what was typed is a link rather than something to search for ("slate://book/maya",
    /// "slate.example/maya", "https://…"), so it can open the page straight away.
    static func looksLikeLink(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.contains("://") || text.hasPrefix(AppConfig.bookingLinkHost.lowercased() + "/")
    }

    /// Whether a creator is found by this search. Matches a name (with the words in order), a link name, or a specialty
    /// written with or without spaces ("real estate" finds Real estate).
    static func matches(_ profile: CreatorProfile, query: String) -> Bool {
        guard let words = clean(query) else { return false }
        let spaced = words.lowercased()
        let squeezed = spaced.filter { !$0.isWhitespace }
        if profile.displayName.lowercased().contains(spaced) { return true }
        if profile.handle.lowercased().contains(squeezed) { return true }
        return profile.specialties.contains { $0.rawValue.lowercased().contains(squeezed) }
    }

    /// An exact link name first, then names that start with the words, then the rest by name.
    static func order(_ profiles: [CreatorProfile], query: String) -> [CreatorProfile] {
        let spaced = (clean(query) ?? "").lowercased()
        let squeezed = spaced.filter { !$0.isWhitespace }
        func rank(_ profile: CreatorProfile) -> Int {
            if profile.handle.lowercased() == squeezed { return 0 }
            if profile.displayName.lowercased().hasPrefix(spaced) { return 1 }
            return 2
        }
        return profiles.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func clamped(limit: Int) -> Int { min(max(limit, 1), maxLimit) }
}

/// What a client sees of their own money and contracts, worked out from what the backend sent.
enum ClientActivity {
    /// What the person has paid, less what came back to them. Only payments that went through count.
    static func netPaidCents(_ payments: [Payment]) -> Int {
        payments.reduce(0) { total, payment in
            guard payment.status == .succeeded else { return total }
            return payment.kind == .refund ? total - payment.amountCents : total + payment.amountCents
        }
    }

    /// Bookings that have a signed contract, newest shoot first. A booking that is still held, cancelled or lapsed
    /// doesn't yet (or no longer) have one that counts.
    static func contractedBookings(_ bookings: [Booking], clientID: UUID) -> [Booking] {
        bookings
            .filter { $0.clientID == clientID && ($0.status == .confirmed || $0.status == .completed) }
            .sorted { $0.startAt > $1.startAt }
    }

    /// Payments newest first, for the history list.
    static func history(_ payments: [Payment]) -> [Payment] {
        payments.sorted { ($0.paidAt ?? $0.createdAt) > ($1.paidAt ?? $1.createdAt) }
    }
}

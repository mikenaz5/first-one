import Foundation

/// How a company is doing over a stretch of time, worked out from the bookings a person can see. Pure, so it is tested
/// without a screen. Money here is the bookings' totals; what Stripe actually collected is on each booking.
struct CompanyReport: Equatable {
    /// One line per person, and one for bookings nobody has been given yet.
    struct Line: Identifiable, Equatable {
        /// Nil for the line of bookings that wait for a person.
        var memberID: UUID?
        var name: String
        /// Confirmed and completed bookings that start in the range.
        var bookings: Int
        var completed: Int
        /// The total of their completed bookings.
        var earnedCents: Int
        /// Their share of what they earned, when the company splits payouts: each booking's share was fixed when it was
        /// given to them. Zero otherwise.
        var owedCents: Int

        var id: String { memberID?.uuidString ?? "waiting" }
    }

    var currencyCode: String
    /// Confirmed and completed bookings that start in the range.
    var booked: Int
    var completed: Int
    var cancelled: Int
    /// Confirmed and not over yet.
    var upcoming: Int
    /// The total of the booked bookings (confirmed and completed).
    var bookedCents: Int
    /// The total of the completed ones.
    var earnedCents: Int
    var owedCents: Int
    var lines: [Line]

    static func make(
        bookings: [Booking], names: [UUID: String], range: DateInterval, now: Date, splits: Bool, currencyCode: String = "USD"
    ) -> CompanyReport {
        var booked = 0, completed = 0, cancelled = 0, upcoming = 0
        var bookedCents = 0, earnedCents = 0, owedCents = 0
        var byPerson: [UUID?: Line] = [:]

        for booking in bookings where range.start <= booking.startAt && booking.startAt < range.end {
            switch booking.effectiveStatus(at: now) {
            case .cancelled:
                cancelled += 1
                continue
            case .held, .expired:
                continue
            case .confirmed, .completed:
                break
            }
            let done = booking.status == .completed
            let owed = (splits && done) ? booking.totalCents * (booking.assigneeShareBps ?? 0) / 10_000 : 0

            booked += 1
            bookedCents += booking.totalCents
            if done {
                completed += 1
                earnedCents += booking.totalCents
                owedCents += owed
            } else if booking.endAt > now {
                upcoming += 1
            }

            var line = byPerson[booking.assignedTo] ?? Line(
                memberID: booking.assignedTo, name: booking.assignedTo.flatMap { names[$0] } ?? "A teammate",
                bookings: 0, completed: 0, earnedCents: 0, owedCents: 0
            )
            line.bookings += 1
            if done {
                line.completed += 1
                line.earnedCents += booking.totalCents
                line.owedCents += owed
            }
            byPerson[booking.assignedTo] = line
        }

        // Most earned first, then the busiest, then by name; the line of bookings nobody has yet comes last.
        let lines = byPerson.values.sorted { lhs, rhs in
            if (lhs.memberID == nil) != (rhs.memberID == nil) { return rhs.memberID == nil }
            if lhs.earnedCents != rhs.earnedCents { return lhs.earnedCents > rhs.earnedCents }
            if lhs.bookings != rhs.bookings { return lhs.bookings > rhs.bookings }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.map { line -> Line in
            guard line.memberID == nil else { return line }
            var waiting = line
            waiting.name = "Needs a person"
            return waiting
        }

        return CompanyReport(
            currencyCode: currencyCode, booked: booked, completed: completed, cancelled: cancelled, upcoming: upcoming,
            bookedCents: bookedCents, earnedCents: earnedCents, owedCents: owedCents, lines: lines
        )
    }
}

/// The stretches of time a report can cover.
enum ReportRange: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .thisYear: "This year"
        }
    }

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        switch self {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 30 * 86_400)
        case .lastMonth:
            let anchor = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.dateInterval(of: .month, for: anchor) ?? DateInterval(start: anchor, duration: 30 * 86_400)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now) ?? DateInterval(start: now, duration: 365 * 86_400)
        }
    }
}

import Foundation

// MARK: - Booking

enum BookingStatus: String, Codable, Hashable {
    case held, confirmed, cancelled, completed, expired

    /// Whether the booking occupies the creator's calendar.
    var blocksTime: Bool { self == .held || self == .confirmed }

    var title: String {
        switch self {
        case .held: "On hold"
        case .confirmed: "Confirmed"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        case .expired: "Expired"
        }
    }
}

/// An add-on as it was when booked. Later edits to the package don't change old bookings.
struct BookedAddOn: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var priceCents: Int
    var extraMinutes: Int
}

struct Booking: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var creatorID: UUID
    var clientID: UUID?
    var creatorName: String
    var clientName: String
    var packageID: UUID?
    var packageName: String
    var addOns: [BookedAddOn]
    var startAt: Date
    /// End of the shoot itself.
    var endAt: Date
    /// End of the shoot plus the creator's buffer. This is the range no other booking may overlap.
    var blockedUntil: Date
    var timeZoneID: String
    var currencyCode: String
    var totalCents: Int
    var depositCents: Int
    var status: BookingStatus
    var notes: String
    var createdAt: Date

    var balanceCents: Int { max(0, totalCents - depositCents) }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var durationMinutes: Int { Int(endAt.timeIntervalSince(startAt) / 60) }
    var blockedRange: DateInterval { DateInterval(start: startAt, end: max(blockedUntil, startAt)) }

    func isUpcoming(at now: Date) -> Bool { status == .confirmed && endAt > now }

    func canCancel(at now: Date) -> Bool { status.blocksTime && startAt > now }

    var accessibilitySummary: String {
        "\(packageName), \(status.title), \(startAt.formatted(date: .complete, time: .shortened))"
    }
}

/// What a client sends to book. Prices are never included: the backend recomputes them.
struct BookingRequest: Equatable {
    var creatorID: UUID
    var packageID: UUID
    var addOnIDs: [UUID]
    var startAt: Date
    var notes: String
}

/// Everything a client sees at a creator's booking link.
struct PublicCreatorPage: Equatable {
    var profile: CreatorProfile
    var portfolio: [PortfolioItem]
    /// Only published packages.
    var packages: [ServicePackage]
}

extension PublicCreatorPage: Identifiable {
    var id: UUID { profile.id }
}

// MARK: - Price summary

struct PriceSummary: Equatable {
    struct Line: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        let cents: Int
    }

    var currencyCode: String
    var lines: [Line]
    var totalCents: Int
    /// Due when booking. Never more than the total.
    var depositCents: Int
    var durationMinutes: Int
    var turnaroundDays: Int

    var balanceCents: Int { totalCents - depositCents }

    /// The one pricing rule. The local backend, the SQL function and the booking screen all follow it:
    /// total = package price + chosen add-ons; deposit = the package's deposit, capped at the total.
    static func make(package: ServicePackage, addOns: [AddOn]) -> PriceSummary {
        var lines = [
            Line(
                id: package.id.uuidString,
                title: package.name,
                detail: DurationText.short(minutes: package.durationMinutes),
                cents: package.priceCents
            ),
        ]
        for addOn in addOns {
            lines.append(Line(id: addOn.id.uuidString, title: addOn.name, detail: detail(for: addOn), cents: addOn.priceCents))
        }
        let total = lines.reduce(0) { $0 + $1.cents }
        return PriceSummary(
            currencyCode: package.currencyCode,
            lines: lines,
            totalCents: total,
            depositCents: min(package.depositCents, total),
            durationMinutes: package.durationMinutes(with: addOns),
            turnaroundDays: package.turnaroundDays(with: addOns)
        )
    }

    private static func detail(for addOn: AddOn) -> String? {
        var parts: [String] = []
        if addOn.extraMinutes > 0 { parts.append("+\(DurationText.short(minutes: addOn.extraMinutes))") }
        if addOn.turnaroundDeltaDays < 0 {
            parts.append("\(DurationText.turnaround(days: -addOn.turnaroundDeltaDays)) sooner")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

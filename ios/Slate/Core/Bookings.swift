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
    /// While a deposit is owed, the time is held until this moment. Nil once the deposit is paid.
    var holdExpiresAt: Date? = nil
    /// When the creator said the work was delivered, which is when the balance becomes due.
    var deliveredAt: Date? = nil
    var cancelledAt: Date? = nil
    var cancelledByID: UUID? = nil
    /// The policy the client agreed to, kept with the booking so later package edits can't change a refund.
    var cancellationPolicy: CancellationPolicy = .moderate

    var balanceCents: Int { max(0, totalCents - depositCents) }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var durationMinutes: Int { Int(endAt.timeIntervalSince(startAt) / 60) }
    var blockedRange: DateInterval { DateInterval(start: startAt, end: max(blockedUntil, startAt)) }

    /// A hold that ran out counts as expired the moment it does, even before the server tidies it up.
    func effectiveStatus(at now: Date) -> BookingStatus {
        if status == .held, let holdExpiresAt, holdExpiresAt <= now { return .expired }
        return status
    }

    /// How long the client has left to pay the deposit. Nil when nothing is held.
    func holdRemaining(at now: Date) -> TimeInterval? {
        guard effectiveStatus(at: now) == .held, let holdExpiresAt else { return nil }
        return holdExpiresAt.timeIntervalSince(now)
    }

    var isDelivered: Bool { deliveredAt != nil }

    /// Not finished yet: a held or confirmed booking, whether or not the shoot has happened.
    func isOpen(at now: Date) -> Bool {
        let current = effectiveStatus(at: now)
        return current == .held || current == .confirmed
    }

    func isUpcoming(at now: Date) -> Bool { isOpen(at: now) && endAt > now }

    /// The shoot is over but the booking isn't: the creator still has to deliver, or the client still has to pay.
    func needsFollowUp(at now: Date) -> Bool { effectiveStatus(at: now) == .confirmed && endAt <= now }

    func canCancel(at now: Date) -> Bool { effectiveStatus(at: now).blocksTime && startAt > now }

    /// A creator can mark the work delivered once the shoot has started, if they haven't already.
    func canMarkDelivered(at now: Date) -> Bool { status == .confirmed && deliveredAt == nil && startAt <= now }

    var accessibilitySummary: String {
        "\(packageName), \(status.title), \(startAt.formatted(date: .complete, time: .shortened))"
    }
}

extension Booking {
    /// Bookings saved before payments existed lack the newer fields; give them sensible values instead of
    /// failing to load (which would make a creator's bookings disappear).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        creatorID = try c.decode(UUID.self, forKey: .creatorID)
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        creatorName = try c.decode(String.self, forKey: .creatorName)
        clientName = try c.decode(String.self, forKey: .clientName)
        packageID = try c.decodeIfPresent(UUID.self, forKey: .packageID)
        packageName = try c.decode(String.self, forKey: .packageName)
        addOns = try c.decode([BookedAddOn].self, forKey: .addOns)
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decode(Date.self, forKey: .endAt)
        blockedUntil = try c.decode(Date.self, forKey: .blockedUntil)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        totalCents = try c.decode(Int.self, forKey: .totalCents)
        depositCents = try c.decode(Int.self, forKey: .depositCents)
        status = try c.decode(BookingStatus.self, forKey: .status)
        notes = try c.decode(String.self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        holdExpiresAt = try c.decodeIfPresent(Date.self, forKey: .holdExpiresAt)
        deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        cancelledByID = try c.decodeIfPresent(UUID.self, forKey: .cancelledByID)
        cancellationPolicy = try c.decodeIfPresent(CancellationPolicy.self, forKey: .cancellationPolicy) ?? .moderate
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

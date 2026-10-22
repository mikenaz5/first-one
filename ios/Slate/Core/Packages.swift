import Foundation

// MARK: - Add-ons

enum AddOnKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case extraTime, drone, rush, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extraTime: "Extra time"
        case .drone: "Drone footage"
        case .rush: "Rush delivery"
        case .custom: "Custom add-on"
        }
    }

    var symbol: String {
        switch self {
        case .extraTime: "clock.badge.plus"
        case .drone: "airplane"
        case .rush: "bolt.fill"
        case .custom: "plus.circle"
        }
    }

    /// Starting values when a creator picks this kind in the editor.
    var defaultName: String {
        switch self {
        case .extraTime: "Extra hour"
        case .drone: "Drone footage"
        case .rush: "Rush delivery"
        case .custom: ""
        }
    }

    var defaultExtraMinutes: Int { self == .extraTime ? 60 : 0 }
    var defaultTurnaroundDeltaDays: Int { self == .rush ? -3 : 0 }
}

struct AddOn: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var kind: AddOnKind
    var name: String
    var priceCents: Int
    /// Extra shoot time. It lengthens the booking and so blocks more of the creator's calendar.
    var extraMinutes: Int
    /// Change to delivery time. Negative means faster (rush); never below one day overall.
    var turnaroundDeltaDays: Int

    init(
        id: UUID = UUID(),
        kind: AddOnKind,
        name: String? = nil,
        priceCents: Int = 0,
        extraMinutes: Int? = nil,
        turnaroundDeltaDays: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.defaultName
        self.priceCents = priceCents
        self.extraMinutes = extraMinutes ?? kind.defaultExtraMinutes
        self.turnaroundDeltaDays = turnaroundDeltaDays ?? kind.defaultTurnaroundDeltaDays
    }
}

// MARK: - Package

struct ServicePackage: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var creatorID: UUID
    var name: String
    var summary: String
    var category: Specialty?
    var priceCents: Int
    var currencyCode: String
    var durationMinutes: Int
    var deliverables: [String]
    var turnaroundDays: Int
    /// Fixed amount due at booking. Add-ons are settled in the balance.
    var depositCents: Int
    var addOns: [AddOn]
    /// Hidden packages are drafts: only the creator sees them.
    var isPublished: Bool
    var position: Int
    var createdAt: Date
    var updatedAt: Date
    /// The contract a client signs when they book. A package can't be published without one.
    var contractTemplateID: UUID? = nil
    var cancellationPolicy: CancellationPolicy = .moderate
    var usageRights: UsageRights = .personal

    var balanceCents: Int { max(0, priceCents - depositCents) }

    var depositPercent: Int {
        guard priceCents > 0 else { return 0 }
        return Int((Double(depositCents) / Double(priceCents) * 100).rounded())
    }

    func addOns(withIDs ids: Set<UUID>) -> [AddOn] {
        addOns.filter { ids.contains($0.id) }
    }

    /// Shoot length including any extra-time add-ons.
    func durationMinutes(with chosen: [AddOn]) -> Int {
        durationMinutes + chosen.reduce(0) { $0 + $1.extraMinutes }
    }

    /// Delivery time after add-ons such as rush. Never less than one day.
    func turnaroundDays(with chosen: [AddOn]) -> Int {
        max(1, turnaroundDays + chosen.reduce(0) { $0 + $1.turnaroundDeltaDays })
    }

    var accessibilitySummary: String {
        var parts = [name, Money.format(priceCents, code: currencyCode), DurationText.short(minutes: durationMinutes)]
        parts.append("delivered in \(DurationText.turnaround(days: turnaroundDays))")
        if depositCents > 0 { parts.append("deposit \(Money.format(depositCents, code: currencyCode))") }
        return parts.joined(separator: ", ")
    }
}

extension ServicePackage {
    /// Packages saved before contracts existed have no contract fields; give them sensible defaults
    /// instead of failing to load (which would make a creator's packages disappear).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        creatorID = try container.decode(UUID.self, forKey: .creatorID)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        category = try container.decodeIfPresent(Specialty.self, forKey: .category)
        priceCents = try container.decode(Int.self, forKey: .priceCents)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        deliverables = try container.decode([String].self, forKey: .deliverables)
        turnaroundDays = try container.decode(Int.self, forKey: .turnaroundDays)
        depositCents = try container.decode(Int.self, forKey: .depositCents)
        addOns = try container.decode([AddOn].self, forKey: .addOns)
        isPublished = try container.decode(Bool.self, forKey: .isPublished)
        position = try container.decode(Int.self, forKey: .position)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        contractTemplateID = try container.decodeIfPresent(UUID.self, forKey: .contractTemplateID)
        cancellationPolicy = try container.decodeIfPresent(CancellationPolicy.self, forKey: .cancellationPolicy) ?? .moderate
        usageRights = try container.decodeIfPresent(UsageRights.self, forKey: .usageRights) ?? .personal
    }
}

// MARK: - Rules

enum PackageRules {
    static let nameLength = 2...60
    static let summaryLimit = 500
    static let deliverableLimit = 12
    static let deliverableLength = 80
    static let addOnLimit = 8
    static let durationRange = 15...1440
    static let durationStep = 15
    static let turnaroundRange = 1...90
    static let maxPriceCents = 100_000_000
    static let maxAddOnMinutes = 480

    enum Problem: Equatable, Hashable {
        case nameLength
        case summaryTooLong
        case priceInvalid
        case durationInvalid
        case turnaroundInvalid
        case depositTooHigh
        case tooManyDeliverables
        case deliverableTooLong
        case tooManyAddOns
        case addOnNameMissing
        case addOnPriceInvalid
        case addOnTimeInvalid
        case contractMissing

        var message: String {
            switch self {
            case .nameLength: "Name it with \(PackageRules.nameLength.lowerBound) to \(PackageRules.nameLength.upperBound) characters."
            case .summaryTooLong: "Keep the description under \(PackageRules.summaryLimit) characters."
            case .priceInvalid: "Enter a price above zero."
            case .durationInvalid: "Choose a duration between 15 minutes and 24 hours."
            case .turnaroundInvalid: "Turnaround must be between 1 and 90 days."
            case .depositTooHigh: "The deposit can't be more than the price."
            case .tooManyDeliverables: "Up to \(PackageRules.deliverableLimit) deliverables."
            case .deliverableTooLong: "Keep each deliverable under \(PackageRules.deliverableLength) characters."
            case .tooManyAddOns: "Up to \(PackageRules.addOnLimit) add-ons."
            case .addOnNameMissing: "Give every add-on a name."
            case .addOnPriceInvalid: "Add-on prices can't be negative."
            case .addOnTimeInvalid: "Extra time must be between 0 and \(PackageRules.maxAddOnMinutes / 60) hours."
            case .contractMissing: "Choose a contract so clients can sign when they book, or hide this package."
            }
        }
    }

    static func problems(in package: ServicePackage) -> [Problem] {
        var found: [Problem] = []
        let trimmedName = package.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameLength.contains(trimmedName.count) { found.append(.nameLength) }
        if package.summary.count > summaryLimit { found.append(.summaryTooLong) }
        if package.priceCents <= 0 || package.priceCents > maxPriceCents { found.append(.priceInvalid) }
        if !durationRange.contains(package.durationMinutes) || package.durationMinutes % durationStep != 0 {
            found.append(.durationInvalid)
        }
        if !turnaroundRange.contains(package.turnaroundDays) { found.append(.turnaroundInvalid) }
        if package.depositCents < 0 || package.depositCents > package.priceCents { found.append(.depositTooHigh) }
        if package.deliverables.count > deliverableLimit { found.append(.tooManyDeliverables) }
        if package.deliverables.contains(where: { $0.count > deliverableLength }) { found.append(.deliverableTooLong) }
        if package.addOns.count > addOnLimit { found.append(.tooManyAddOns) }
        if package.isPublished && package.contractTemplateID == nil { found.append(.contractMissing) }
        for addOn in package.addOns {
            for problem in problems(in: addOn) where !found.contains(problem) { found.append(problem) }
        }
        return found
    }

    static func problems(in addOn: AddOn) -> [Problem] {
        var found: [Problem] = []
        if addOn.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(.addOnNameMissing) }
        if addOn.priceCents < 0 || addOn.priceCents > maxPriceCents { found.append(.addOnPriceInvalid) }
        if addOn.extraMinutes < 0 || addOn.extraMinutes > maxAddOnMinutes { found.append(.addOnTimeInvalid) }
        return found
    }
}

// MARK: - Money

enum Money {
    static var defaultCurrencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    static func decimal(cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    /// Rounds to the nearest cent.
    static func cents(from decimal: Decimal) -> Int {
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// "$2,400" for whole amounts, "$2,400.50" otherwise.
    static func format(_ cents: Int, code: String) -> String {
        let style = Decimal.FormatStyle.Currency(code: code)
        let amount = decimal(cents: cents)
        return cents % 100 == 0
            ? amount.formatted(style.precision(.fractionLength(0)))
            : amount.formatted(style)
    }
}

// MARK: - Text

enum DurationText {
    /// "8 hr", "1 hr, 30 min", "45 min" in the person's language.
    static func short(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "3 days", "1 week", "2 weeks".
    static func turnaround(days: Int) -> String {
        if days >= 7, days % 7 == 0 {
            let weeks = days / 7
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        return days == 1 ? "1 day" : "\(days) days"
    }
}

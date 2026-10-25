import Foundation

// MARK: - Cancellation policy

/// How much a client gets back if they cancel. Chosen per package, written into the contract,
/// and used to work out refunds. Cancellations by the creator are always refunded in full.
enum CancellationPolicy: String, Codable, CaseIterable, Identifiable, Hashable {
    case flexible, moderate, strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flexible: "Flexible"
        case .moderate: "Moderate"
        case .strict: "Strict"
        }
    }

    /// Short description for pickers.
    var summary: String {
        switch self {
        case .flexible: "Full refund up to 24 hours before, 50% after"
        case .moderate: "Full refund up to 7 days before, 50% up to 48 hours before"
        case .strict: "50% refund up to 14 days before, none after"
        }
    }

    struct Tier: Equatable {
        /// Applies when the shoot is at least this many hours away.
        let minHoursBefore: Int
        let refundPercent: Int
    }

    /// Most generous first. The first tier whose threshold is met applies.
    var tiers: [Tier] {
        switch self {
        case .flexible: [Tier(minHoursBefore: 24, refundPercent: 100), Tier(minHoursBefore: 0, refundPercent: 50)]
        case .moderate: [Tier(minHoursBefore: 168, refundPercent: 100), Tier(minHoursBefore: 48, refundPercent: 50), Tier(minHoursBefore: 0, refundPercent: 0)]
        case .strict: [Tier(minHoursBefore: 336, refundPercent: 50), Tier(minHoursBefore: 0, refundPercent: 0)]
        }
    }

    /// Share of the amount paid that a *client* cancellation refunds, given how long until the shoot.
    func refundPercent(hoursBefore: Double) -> Int {
        let hours = max(0, hoursBefore)
        return tiers.first { hours >= Double($0.minHoursBefore) }?.refundPercent ?? 0
    }

    /// The exact words that go into the contract. The SQL function `contract_policy_text` must match.
    var contractText: String {
        switch self {
        case .flexible:
            "Flexible. If the Client cancels at least 24 hours before the shoot, the Client receives a full refund of the amounts paid. If the Client cancels later, the Client receives a 50% refund. If the Creator cancels, the Client receives a full refund."
        case .moderate:
            "Moderate. If the Client cancels at least 7 days before the shoot, the Client receives a full refund of the amounts paid. If the Client cancels at least 48 hours before the shoot, the Client receives a 50% refund. After that, no refund is due. If the Creator cancels, the Client receives a full refund."
        case .strict:
            "Strict. If the Client cancels at least 14 days before the shoot, the Client receives a 50% refund of the amounts paid. After that, no refund is due. If the Creator cancels, the Client receives a full refund."
        }
    }
}

// MARK: - Usage rights

enum UsageRights: String, Codable, CaseIterable, Identifiable, Hashable {
    case personal, personalSocial, commercial, fullTransfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: "Personal use"
        case .personalSocial: "Personal and social media"
        case .commercial: "Commercial use"
        case .fullTransfer: "Full rights transfer"
        }
    }

    var summary: String {
        switch self {
        case .personal: "Prints, albums and sharing with family and friends"
        case .personalSocial: "Personal use plus posting on the client's own social media"
        case .commercial: "The client may use the work to promote their business"
        case .fullTransfer: "Copyright passes to the client once paid in full"
        }
    }

    /// The exact words that go into the contract. The SQL function `contract_rights_text` must match.
    var contractText: String {
        switch self {
        case .personal:
            "Personal use. The Client may use the deliverables for personal, non-commercial purposes, such as prints, albums and sharing with family and friends. The Creator keeps the copyright and may show the work in their portfolio and promotion."
        case .personalSocial:
            "Personal and social media use. The Client may use the deliverables for personal, non-commercial purposes and may post them on the Client's own social media accounts, crediting the Creator. The Creator keeps the copyright and may show the work in their portfolio and promotion."
        case .commercial:
            "Commercial use. The Client may use the deliverables to promote the Client's own business, including on websites, social media and advertising. The Client may not resell the deliverables or license them to others. The Creator keeps the copyright and may show the work in their portfolio and promotion."
        case .fullTransfer:
            "Full rights transfer. Copyright in the deliverables passes to the Client once the Client has paid in full. The Creator may still show the work in their portfolio and promotion unless the Client asks otherwise in writing."
        }
    }
}

// MARK: - Placeholders

/// Everything a template can refer to as `{{token}}`. This list is closed: the editor, the
/// renderer and the SQL function all use exactly these.
enum ContractField: String, CaseIterable, Identifiable, Hashable {
    case clientName = "client_name"
    case creatorName = "creator_name"
    case packageName = "package_name"
    case bookingDate = "booking_date"
    case bookingTime = "booking_time"
    case timeZone = "time_zone"
    case duration = "duration"
    case deliverables = "deliverables"
    case addOns = "add_ons"
    case price = "price"
    case deposit = "deposit"
    case balance = "balance"
    case turnaround = "turnaround"
    case deliveryDate = "delivery_date"
    case cancellationPolicy = "cancellation_policy"
    case usageRights = "usage_rights"
    case clientNotes = "client_notes"

    var id: String { rawValue }

    var token: String { "{{\(rawValue)}}" }

    var title: String {
        switch self {
        case .clientName: "Client name"
        case .creatorName: "Creator name"
        case .packageName: "Package"
        case .bookingDate: "Shoot date"
        case .bookingTime: "Shoot time"
        case .timeZone: "Time zone"
        case .duration: "Duration"
        case .deliverables: "Deliverables"
        case .addOns: "Add-ons"
        case .price: "Total price"
        case .deposit: "Deposit"
        case .balance: "Balance"
        case .turnaround: "Turnaround"
        case .deliveryDate: "Delivery date"
        case .cancellationPolicy: "Cancellation policy"
        case .usageRights: "Usage rights"
        case .clientNotes: "Client notes"
        }
    }

    /// A believable value, for the editor's preview.
    var sample: String {
        switch self {
        case .clientName: "Alex Rivera"
        case .creatorName: "Maya Chen Photography"
        case .packageName: "Wedding day coverage"
        case .bookingDate: "Saturday, June 12, 2027"
        case .bookingTime: "10:00 AM – 6:00 PM"
        case .timeZone: "America/Chicago"
        case .duration: "8 hours"
        case .deliverables: "• 400 edited photos\n• Online gallery for 12 months"
        case .addOns: "• Second photographer (+$600)"
        case .price: "$3,200"
        case .deposit: "$800"
        case .balance: "$2,400"
        case .turnaround: "21 days"
        case .deliveryDate: "Saturday, July 3, 2027"
        case .cancellationPolicy: CancellationPolicy.moderate.contractText
        case .usageRights: UsageRights.personalSocial.contractText
        case .clientNotes: "Ceremony at the lake house."
        }
    }

    /// A template must mention these, or the contract wouldn't say who, what, when or for how much.
    static let required: [ContractField] = [.clientName, .creatorName, .packageName, .bookingDate, .price, .cancellationPolicy]
}

// MARK: - Templates

enum ContractKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case photography, videography, freelance, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photography: "Photography"
        case .videography: "Videography"
        case .freelance: "General freelance"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .photography: "camera"
        case .videography: "video"
        case .freelance: "briefcase"
        case .custom: "doc.text"
        }
    }
}

struct ContractClause: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

extension ContractClause {
    /// The server only requires a title and body, so a section written elsewhere may have no id.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
    }
}

struct ContractTemplate: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var creatorID: UUID
    var title: String
    var kind: ContractKind
    var clauses: [ContractClause]
    /// Goes up whenever the wording changes. Signed contracts keep the version they were signed on.
    var version: Int
    var createdAt: Date
    var updatedAt: Date
}

enum ContractRules {
    static let titleLength = 2...80
    static let clauseLimit = 30
    static let clauseTitleLength = 1...80
    static let clauseBodyLimit = 3000
    static let templateLimit = 20

    enum Problem: Equatable, Hashable {
        case title
        case noClauses
        case tooManyClauses
        case clauseTitle
        case clauseBody
        case clauseBodyTooLong
        case unknownPlaceholder(String)
        case missingRequired(ContractField)

        var message: String {
            switch self {
            case .title: "Give the contract a title of \(ContractRules.titleLength.lowerBound) to \(ContractRules.titleLength.upperBound) characters."
            case .noClauses: "Add at least one section."
            case .tooManyClauses: "Use at most \(ContractRules.clauseLimit) sections."
            case .clauseTitle: "Every section needs a heading."
            case .clauseBody: "Every section needs some text."
            case .clauseBodyTooLong: "Keep each section under \(ContractRules.clauseBodyLimit) characters."
            case .unknownPlaceholder(let token): "{{\(token)}} isn't a field Slate Pro knows. Pick one from the Insert menu."
            case .missingRequired(let field): "Mention \(field.title.lowercased()) somewhere ({{\(field.rawValue)}}) so the contract is complete."
            }
        }
    }

    static func problems(in template: ContractTemplate) -> [Problem] {
        var found: [Problem] = []
        if !titleLength.contains(template.title.trimmingCharacters(in: .whitespacesAndNewlines).count) { found.append(.title) }
        if template.clauses.isEmpty { found.append(.noClauses) }
        if template.clauses.count > clauseLimit { found.append(.tooManyClauses) }

        for clause in template.clauses {
            if !clauseTitleLength.contains(clause.title.trimmingCharacters(in: .whitespacesAndNewlines).count), !found.contains(.clauseTitle) {
                found.append(.clauseTitle)
            }
            let body = clause.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty, !found.contains(.clauseBody) { found.append(.clauseBody) }
            if clause.body.count > clauseBodyLimit, !found.contains(.clauseBodyTooLong) { found.append(.clauseBodyTooLong) }
        }

        let used = ContractRenderer.tokens(in: template)
        for token in used where ContractField(rawValue: token) == nil {
            let problem = Problem.unknownPlaceholder(token)
            if !found.contains(problem) { found.append(problem) }
        }
        for field in ContractField.required where !used.contains(field.rawValue) {
            found.append(.missingRequired(field))
        }
        return found
    }
}

// MARK: - Rendered contract

struct ContractSection: Identifiable, Codable, Equatable, Hashable {
    var title: String
    var body: String
    var id: String { title + "\u{0}" + body }
}

/// A template with every placeholder filled in. Nothing in here changes once it is signed.
struct RenderedContract: Codable, Equatable, Hashable {
    var title: String
    var sections: [ContractSection]
    var templateID: UUID
    var templateVersion: Int

    /// The exact text that is hashed, signed and printed. Backends must produce it identically.
    var text: String {
        var parts = [title]
        for (index, section) in sections.enumerated() {
            parts.append("\(index + 1). \(section.title)\n\(section.body)")
        }
        return parts.joined(separator: "\n\n")
    }

    var documentHash: String { Hashing.sha256Hex(text) }
}

// MARK: - Signatures

enum SignerRole: String, Codable, Hashable {
    case creator, client

    var title: String { self == .creator ? "Creator" : "Client" }
}

enum SignatureMethod: String, Codable, CaseIterable, Identifiable, Hashable {
    case typed, drawn
    /// The creator's saved signature, applied under their standing authorization.
    case onFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typed: "Type"
        case .drawn: "Draw"
        case .onFile: "On file"
        }
    }
}

/// The wording a signer agrees to. Bump `version` if it ever changes; signatures record which one they saw.
enum SigningConsent {
    static let version = 1
    static let text = "By tapping Sign, I agree to this contract and to sign it electronically. My typed or drawn signature has the same effect as a handwritten one."
    static let creatorAuthorization = "I authorize Slate Pro to apply this signature to the contracts for my packages when clients book, and I agree to those contracts."
}

/// A signature as the person gave it, before the server stamps it.
struct SignatureInput: Equatable {
    var documentHash: String
    var signedName: String
    var method: SignatureMethod
    var imagePNG: Data?
    var consentVersion: Int = SigningConsent.version
    var device: String = SignatureInput.currentDeviceDescription

    static var currentDeviceDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Slate Pro iOS app, OS \(version.majorVersion).\(version.minorVersion)"
    }
}

struct ContractSignature: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var role: SignerRole
    var userID: UUID?
    var signedName: String
    var method: SignatureMethod
    var imagePNG: Data?
    var signedAt: Date
    var consentVersion: Int
    var device: String
    /// For a company's contract: the company this person signed for, and the title they signed with.
    var onBehalfOf: String? = nil
    var signerTitle: String? = nil
}

enum ContractStatus: String, Codable, Hashable {
    /// Signed by the client, waiting for payment before the creator's signature is applied.
    case pending
    case executed
    case voided

    var title: String {
        switch self {
        case .pending: "Awaiting payment"
        case .executed: "Signed by both"
        case .voided: "Void"
        }
    }
}

struct Contract: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var bookingID: UUID
    var creatorID: UUID
    var clientID: UUID?
    var templateID: UUID?
    var templateVersion: Int
    var title: String
    var sections: [ContractSection]
    var documentHash: String
    var status: ContractStatus
    var signatures: [ContractSignature]
    var createdAt: Date
    var executedAt: Date?
    /// For a company's contract: the company's legal name, and the person authorised to sign for it. Fixed when the
    /// client signs, so later changes to who signs never touch a contract already made.
    var providerLegalName: String? = nil
    var countersignerID: UUID? = nil
    var countersignerName: String? = nil
    var countersignerTitle: String? = nil

    func signature(for role: SignerRole) -> ContractSignature? {
        signatures.first { $0.role == role }
    }
}

/// The creator's saved signature.
struct CreatorSignature: Codable, Equatable {
    var signedName: String
    var method: SignatureMethod
    var imagePNG: Data?
    var updatedAt: Date
}

/// What a client sees before signing, and the hash they sign.
struct ContractPreview: Equatable {
    var contract: RenderedContract
    var documentHash: String { contract.documentHash }
}

/// A booking together with its contract.
struct SignedBooking: Equatable {
    var booking: Booking
    var contract: Contract
}

// MARK: - Signature rules

enum SignatureRules {
    static let nameLength = 2...80
    static let maxImageBytes = 300_000
    private static let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isPNG(_ data: Data) -> Bool {
        data.count > pngHeader.count && Array(data.prefix(pngHeader.count)) == pngHeader
    }

    /// A signature someone can give themselves: a name, typed or drawn. `onFile` is only ever
    /// applied by the server from a creator's saved signature, never accepted from a client.
    static func isValid(name: String, method: SignatureMethod, imagePNG: Data?) -> Bool {
        guard nameLength.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { return false }
        switch method {
        case .typed:
            return true
        case .drawn:
            guard let imagePNG, imagePNG.count <= maxImageBytes else { return false }
            return isPNG(imagePNG)
        case .onFile:
            return false
        }
    }

    static func isValid(_ input: SignatureInput) -> Bool {
        isValid(name: input.signedName, method: input.method, imagePNG: input.imagePNG)
    }

    static func isValid(_ signature: CreatorSignature) -> Bool {
        isValid(name: signature.signedName, method: signature.method, imagePNG: signature.imagePNG)
    }
}

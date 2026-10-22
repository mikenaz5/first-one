import Foundation

// MARK: - Rules

/// What a delivery may be: a link to the final files, and a short note. Mirrors `delivery_url_clean()` and the note
/// limit in SQL; `SlateTests/Fixtures/delivery_rules.json` is checked by both test suites.
enum DeliveryRules {
    static let linkMaxLength = 2048
    static let noteMaxLength = 500

    enum LinkProblem: Equatable {
        case empty
        /// Doesn't start with https://.
        case notSecure
        /// Something in it can't be part of a link (spaces, quotes, non-ASCII characters, a stray `%`), or the address
        /// isn't a real-looking host (a username or password in it, a bare IP address, "localhost").
        case invalid
        case tooLong
    }

    private static let trimmed: Set<Unicode.Scalar> = [" ", "\n", "\t", "\r"]
    /// RFC 3986's reserved and unreserved characters, apart from letters, digits and `%` (which has its own rule).
    private static let linkPunctuation: Set<Unicode.Scalar> = Set("._~:/?#[]@!$&'()*+,;=-".unicodeScalars)

    /// The link as it will be stored, or nil if it can't be used. Trimmed; https only; every character from the URI
    /// character set (a `%` only as part of `%XX`); a real-looking host with an optional port; no username or password.
    static func cleanLink(_ text: String) -> String? {
        let scalars = trim(Array(text.unicodeScalars))
        return validate(scalars) == nil ? string(scalars) : nil
    }

    /// Why this text can't be shared, or nil if it can. For telling the creator what to fix.
    static func linkProblem(in text: String) -> LinkProblem? {
        let scalars = trim(Array(text.unicodeScalars))
        return validate(scalars)
    }

    /// The address to open, for a stored link.
    static func url(for link: String) -> URL? {
        cleanLink(link).flatMap { URL(string: $0) }
    }

    /// The note tidied the way messages are, or nil when there is nothing left of it.
    static func cleanNote(_ text: String) -> String? {
        let cleaned = MessageRules.clean(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func noteIsTooLong(_ text: String) -> Bool {
        MessageRules.length(of: MessageRules.clean(text)) > noteMaxLength
    }

    // MARK: Checks

    private static func trim(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0
        var end = scalars.count
        while start < end, trimmed.contains(scalars[start]) { start += 1 }
        while end > start, trimmed.contains(scalars[end - 1]) { end -= 1 }
        return Array(scalars[start..<end])
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func validate(_ scalars: [Unicode.Scalar]) -> LinkProblem? {
        if scalars.isEmpty { return .empty }
        if scalars.count > linkMaxLength { return .tooLong }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                guard index + 2 < scalars.count, isHex(scalars[index + 1]), isHex(scalars[index + 2]) else { return .invalid }
                index += 3
                continue
            }
            guard isLetterOrDigit(scalar) || linkPunctuation.contains(scalar) else { return .invalid }
            index += 1
        }

        // Everything left is ASCII, so lowercasing is safe and letter case never matters below.
        let text = Array(string(scalars).lowercased().unicodeScalars)
        let scheme = Array("https://".unicodeScalars)
        guard text.count >= scheme.count, Array(text[0..<scheme.count]) == scheme else { return .notSecure }
        let authority = Array(text[scheme.count...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        return isHost(authority) ? nil : .invalid
    }

    /// Dotted names with a letter in the last part, and an optional port: no bare IP addresses, no "localhost",
    /// no username or password. Matches `^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9](:[0-9]{1,5})?$`.
    private static func isHost(_ authority: [Unicode.Scalar]) -> Bool {
        var host = authority
        if let colon = authority.firstIndex(of: ":") {
            let port = authority[(colon + 1)...]
            guard (1...5).contains(port.count), port.allSatisfy({ isDigit($0) }) else { return false }
            host = Array(authority[..<colon])
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map { Array($0) }
        guard labels.count >= 2 else { return false }
        for label in labels.dropLast() {
            guard (1...63).contains(label.count), isAlphanumeric(label[0]), isAlphanumeric(label[label.count - 1]),
                  label.allSatisfy({ isAlphanumeric($0) || $0 == "-" }) else { return false }
        }
        let last = labels[labels.count - 1]
        return last.count >= 2 && isLetter(last[0]) && isAlphanumeric(last[last.count - 1]) && last.allSatisfy { isAlphanumeric($0) || $0 == "-" }
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }
    private static func isLetter(_ s: Unicode.Scalar) -> Bool { (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x41 && s.value <= 0x5A) }
    private static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool { isLetter(s) || isDigit(s) }
    private static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool { isLetterOrDigit(s) }
    private static func isHex(_ s: Unicode.Scalar) -> Bool {
        isDigit(s) || (s.value >= 0x61 && s.value <= 0x66) || (s.value >= 0x41 && s.value <= 0x46)
    }
}

// MARK: - Where a delivery stands

/// A booking's delivery in one glance: what has happened, what the viewer can do, and what comes next.
struct DeliverySummary: Equatable {
    enum Stage: Equatable {
        /// The shoot has started and no files have been shared.
        case readyToShare
        /// Shared; the client hasn't confirmed they have everything.
        case awaitingConfirmation
        case received
    }

    var stage: Stage
    var headline: String
    var detail: String
    var symbol: String
    var tone: PaymentSummary.Tone
    /// What the creator shared. Nil until they do.
    var link: String?
    var note: String?
    var sharedAt: Date?
    var receivedAt: Date?
    /// The creator can share, or replace the link they shared.
    var canShare: Bool
    /// The client can confirm they have the files.
    var canConfirm: Bool

    /// Nil when delivery has nothing to say yet: the booking isn't confirmed, or the shoot hasn't started.
    static func make(booking: Booking, viewer: PaymentSummary.Viewer, now: Date) -> DeliverySummary? {
        guard booking.status == .confirmed || booking.status == .completed else { return nil }
        let money = Money.format(booking.balanceCents, code: booking.currencyCode)
        let clientName = booking.clientName.trimmed.nonEmpty
        let creatorName = booking.creatorName.trimmed.nonEmpty
        let client = clientName ?? "the client"
        let clientFirst = clientName ?? "The client"
        let creatorFirst = creatorName ?? "Your creator"

        func summary(
            _ stage: Stage, _ headline: String, _ detail: String, _ symbol: String, _ tone: PaymentSummary.Tone
        ) -> DeliverySummary {
            DeliverySummary(
                stage: stage, headline: headline, detail: detail, symbol: symbol, tone: tone,
                link: booking.deliveryURL, note: booking.deliveryNote, sharedAt: booking.deliveredAt, receivedAt: booking.receiptConfirmedAt,
                canShare: viewer == .creator && booking.canShareDelivery(at: now),
                canConfirm: viewer == .client && booking.canConfirmReceipt
            )
        }

        if booking.receiptConfirmedAt != nil {
            switch viewer {
            case .creator:
                let tail = booking.status == .confirmed && booking.balanceCents > 0 ? " They can now pay the remaining \(money)." : ""
                return summary(.received, "Files received", "\(clientFirst) confirmed they have the final files.\(tail)", "checkmark.seal.fill", .success)
            case .client:
                return summary(.received, "Files received", "You confirmed you have the final files.", "checkmark.seal.fill", .success)
            }
        }
        if booking.deliveredAt != nil {
            switch viewer {
            case .creator:
                return summary(.awaitingConfirmation, "Files shared",
                               "Waiting for \(client) to confirm they have everything. You can replace the link until they do.",
                               "shippingbox", .neutral)
            case .client:
                let tail = booking.balanceCents > 0 ? "The remaining \(money) is due after you confirm." : "Nothing more is due."
                return summary(.awaitingConfirmation, "Your files are ready",
                               "Open the link and check everything is there, then confirm. \(tail)", "shippingbox.fill", .warning)
            }
        }
        guard booking.status == .confirmed, booking.startAt <= now else { return nil }
        switch viewer {
        case .creator:
            let tail = booking.balanceCents > 0 ? "then pays the remaining \(money)" : "and the booking is complete"
            return summary(.readyToShare, "Ready to deliver",
                           "Share a link to the final files. \(clientFirst) confirms they have them, \(tail).", "shippingbox", .warning)
        case .client:
            return summary(.readyToShare, "Waiting for your files",
                           "\(creatorFirst) will share a link to the final files when they're ready.", "shippingbox", .neutral)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}

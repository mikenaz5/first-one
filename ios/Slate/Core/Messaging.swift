import Foundation

// MARK: - Messages

/// What a system line carries so the app can word it. The keys match the JSON the database writes.
struct MessageEventData: Codable, Equatable, Hashable {
    var amountCents: Int?
    var balanceCents: Int?
    var refundCents: Int?
    var currency: String?
    var byCreator: Bool?
    /// A delivery line: the link was replaced rather than shared for the first time.
    var revised: Bool?
    /// A review line: the stars given.
    var rating: Int?
    var packageName: String?
    var startAt: Date?
    var timeZone: String?
}

/// One line in a booking's conversation: something a person wrote, or something that happened to the booking.
/// The conversation doubles as the booking's history, so both kinds live in one list.
struct Message: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case text, system
    }

    /// What happened. The database writes these from the booking's own changes, so nobody can type one.
    enum Event: String, Codable {
        case booked
        case contractSigned = "contract_signed"
        case depositPaid = "deposit_paid"
        case deliveryShared = "delivery_shared"
        case receiptConfirmed = "receipt_confirmed"
        case balancePaid = "balance_paid"
        case reviewed
        case cancelled
    }

    var id: UUID
    var bookingID: UUID
    /// Nil for system lines, and for a person who has since deleted their account.
    var senderID: UUID?
    var kind: Kind
    /// What the person wrote. Empty for system lines.
    var body: String
    var event: Event?
    var data: MessageEventData
    /// Made by the app when sending, so sending again after a dropped connection doesn't post it twice.
    var clientMessageID: UUID?
    var createdAt: Date

    func isFrom(_ userID: UUID?) -> Bool {
        kind == .text && senderID != nil && senderID == userID
    }
}

/// A conversation in the Messages list: the latest line and how many of the other person's messages are unread.
struct ConversationSummary: Identifiable, Equatable, Hashable {
    var bookingID: UUID
    var last: Message
    var unreadCount: Int

    var id: UUID { bookingID }
}

/// A message the person has sent that the server hasn't confirmed yet, shown in the thread right away.
struct PendingMessage: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        case failed(String)
    }

    /// Doubles as the `clientMessageID`, so sending it again can't post it twice.
    var id: UUID
    var body: String
    var createdAt: Date
    var state: State
}

/// How a conversation on screen takes in what the server returns.
enum ConversationMerge {
    /// Existing lines plus incoming ones, each message once (by id; the newer copy wins), in time order. Lines with the
    /// same time keep the order they were first seen in, because stored times can be whole seconds.
    static func merge(_ existing: [Message], _ incoming: [Message]) -> [Message] {
        var combined = existing
        for message in incoming {
            if let index = combined.firstIndex(where: { $0.id == message.id }) {
                combined[index] = message
            } else {
                combined.append(message)
            }
        }
        return combined.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map { $0.element }
    }

    /// Pending messages that the server has now confirmed (it returned them, by their client id) are done.
    static func settle(_ pending: [PendingMessage], against messages: [Message]) -> [PendingMessage] {
        let confirmed = Set(messages.compactMap(\.clientMessageID))
        return pending.filter { !confirmed.contains($0.id) }
    }

    /// How far back to look when asking for what's new: a little before the newest line, so one that committed
    /// late (with an earlier time) is still picked up. Repeats are removed by `merge`.
    static func cursor(for messages: [Message]) -> Date? {
        messages.map(\.createdAt).max().map { $0.addingTimeInterval(-5) }
    }
}

// MARK: - Rules

/// What a message may be. Mirrors `message_clean` and the length limit in SQL; `notification_rules.json` is
/// checked by both test suites.
enum MessageRules {
    static let maxLength = 2000
    /// The database refuses more than this from one person in a minute.
    static let sendsPerMinute = 20

    enum Problem: Equatable {
        case empty, tooLong
    }

    private static let trimmed: Set<Unicode.Scalar> = [" ", "\n", "\t"]

    /// Line breaks as LF, control characters removed (tab and line feed stay), and no spaces or line breaks
    /// around it. Works on Unicode scalars, because Swift treats "\r\n" as one character and SQL does not.
    static func clean(_ text: String) -> String {
        let input = Array(text.unicodeScalars)
        var output: [Unicode.Scalar] = []
        var index = 0
        while index < input.count {
            let scalar = input[index]
            index += 1
            switch scalar.value {
            case 0x0D:
                if index < input.count, input[index].value == 0x0A { continue } // The LF that follows is kept instead.
                output.append("\n")
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
                continue
            default:
                output.append(scalar)
            }
        }
        while let first = output.first, trimmed.contains(first) { output.removeFirst() }
        while let last = output.last, trimmed.contains(last) { output.removeLast() }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }

    /// Length the way the database counts it: Unicode code points.
    static func length(of cleaned: String) -> Int { cleaned.unicodeScalars.count }

    /// Why this text can't be sent, or nil if it can.
    static func problem(with text: String) -> Problem? {
        let cleaned = clean(text)
        if cleaned.isEmpty { return .empty }
        return length(of: cleaned) > maxLength ? .tooLong : nil
    }

    /// Characters left before the limit, once the text is tidied.
    static func remaining(in text: String) -> Int {
        maxLength - length(of: clean(text))
    }
}

// MARK: - Wording

/// How system lines and previews read. System lines carry facts, not sentences, so this is the one place that words them.
enum ConversationText {
    static func systemLine(_ message: Message, booking: Booking?, viewerID: UUID?) -> String {
        let viewerIsCreator = booking.map { $0.creatorID == viewerID } ?? false
        let viewerIsClient = booking.map { $0.clientID == viewerID } ?? false
        let client = booking?.clientName.nonEmpty ?? "The client"
        let creator = booking?.creatorName.nonEmpty ?? "The creator"
        let currency = message.data.currency ?? booking?.currencyCode ?? "USD"
        func money(_ cents: Int?) -> String { ContractFormat.money(cents: cents ?? 0, code: currency) }

        switch message.event {
        case .booked:
            let package = message.data.packageName ?? booking?.packageName ?? "a package"
            let when = (message.data.startAt ?? booking?.startAt).map {
                " for \(NoticeFormat.shootTime($0, in: timeZone(message, booking)))"
            } ?? ""
            return viewerIsClient ? "You booked \(package)\(when)." : "\(client) booked \(package)\(when)."
        case .contractSigned:
            return "The contract is signed by both of you."
        case .depositPaid:
            let amount = money(message.data.amountCents)
            return viewerIsClient ? "You paid the \(amount) deposit." : "\(client) paid the \(amount) deposit."
        case .balancePaid:
            let amount = money(message.data.amountCents)
            return viewerIsClient ? "You paid the \(amount) balance. All done." : "\(client) paid the \(amount) balance. All done."
        case .deliveryShared:
            let revised = message.data.revised ?? false
            if viewerIsCreator {
                return revised ? "You updated the link to the final files." : "You shared the final files with \(client)."
            }
            return revised
                ? "\(creator) updated the link to the final files."
                : "\(creator) shared the final files. Open the booking to confirm you have them."
        case .receiptConfirmed:
            let balance = message.data.balanceCents ?? 0
            if viewerIsClient {
                return balance > 0
                    ? "You confirmed you have the final files. The balance of \(money(balance)) is now due."
                    : "You confirmed you have the final files. All done."
            }
            return balance > 0
                ? "\(client) confirmed they have the final files. The balance of \(money(balance)) is now due."
                : "\(client) confirmed they have the final files. All done."
        case .reviewed:
            let stars = message.data.rating.map { "\($0)-star " } ?? ""
            return viewerIsClient ? "You left a \(stars)review." : "\(client) left a \(stars)review."
        case .cancelled:
            let refund = message.data.refundCents ?? 0
            let byCreator = message.data.byCreator ?? false
            if byCreator {
                if viewerIsCreator {
                    return refund > 0 ? "You cancelled this booking. \(client) is being refunded \(money(refund))." : "You cancelled this booking."
                }
                return refund > 0 ? "\(creator) cancelled this booking. You'll be refunded \(money(refund))." : "\(creator) cancelled this booking."
            }
            if viewerIsClient {
                return refund > 0 ? "You cancelled this booking. \(money(refund)) is on its way back to you." : "You cancelled this booking."
            }
            return refund > 0 ? "\(client) cancelled this booking. \(money(refund)) is being refunded to them." : "\(client) cancelled this booking."
        case nil:
            return ""
        }
    }

    /// The line under a conversation's title in the list.
    static func preview(of message: Message, booking: Booking?, viewerID: UUID?) -> String {
        switch message.kind {
        case .text:
            let flat = message.body.replacingOccurrences(of: "\n", with: " ")
            return message.isFrom(viewerID) ? "You: \(flat)" : flat
        case .system:
            return systemLine(message, booking: booking, viewerID: viewerID)
        }
    }

    private static func timeZone(_ message: Message, _ booking: Booking?) -> TimeZone {
        message.data.timeZone.flatMap(TimeZone.init(identifier:)) ?? booking?.timeZone ?? .current
    }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

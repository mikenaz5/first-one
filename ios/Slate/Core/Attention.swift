import Foundation

/// Something a person has to do about one of their bookings, for the "Needs attention" card on Home.
struct AttentionItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// Client: a held booking is waiting for its deposit.
        case payDeposit
        /// Creator: the shoot is over and no files have been shared.
        case shareFiles
        /// Client: files were shared and need confirming.
        case confirmFiles
        /// Client: confirmed, and a balance is owed.
        case payBalance
    }

    var kind: Kind
    var bookingID: UUID
    var title: String
    var detail: String
    var symbol: String
    /// What the list is ordered by: the shoot's start.
    var date: Date

    var id: String { "\(kind.rawValue)-\(bookingID.uuidString)" }
}

enum AttentionList {
    /// Everything this person needs to act on, most urgent first: unpaid deposits (a hold runs out), then the rest by
    /// the date of the shoot. On-device a person can book their own package, and then both roles apply.
    static func make(bookings: [Booking], userID: UUID, now: Date) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for booking in bookings {
            let status = booking.effectiveStatus(at: now)
            let money = Money.format(booking.balanceCents, code: booking.currencyCode)

            if booking.clientID == userID {
                if status == .held {
                    items.append(AttentionItem(
                        kind: .payDeposit, bookingID: booking.id, title: "Pay the deposit",
                        detail: "\(booking.packageName) with \(name(booking.creatorName, "your creator")). Your time is held until you do.",
                        symbol: "creditcard", date: booking.startAt
                    ))
                }
                if status == .confirmed, booking.canConfirmReceipt {
                    items.append(AttentionItem(
                        kind: .confirmFiles, bookingID: booking.id, title: "Confirm you have your files",
                        detail: "\(booking.packageName) from \(name(booking.creatorName, "your creator"))",
                        symbol: "shippingbox.fill", date: booking.startAt
                    ))
                }
                if status == .confirmed, booking.receiptConfirmedAt != nil, booking.balanceCents > 0 {
                    items.append(AttentionItem(
                        kind: .payBalance, bookingID: booking.id, title: "Pay the balance",
                        detail: "\(money) for \(booking.packageName)",
                        symbol: "creditcard", date: booking.startAt
                    ))
                }
            }
            if booking.isProviderFor(userID), booking.needsFollowUp(at: now), booking.deliveredAt == nil {
                items.append(AttentionItem(
                    kind: .shareFiles, bookingID: booking.id, title: "Share the final files",
                    detail: "\(booking.packageName) for \(name(booking.clientName, "your client"))",
                    symbol: "shippingbox", date: booking.startAt
                ))
            }
        }
        return items.sorted { lhs, rhs in
            let lhsFirst = lhs.kind == .payDeposit
            let rhsFirst = rhs.kind == .payDeposit
            if lhsFirst != rhsFirst { return lhsFirst }
            return (lhs.date, lhs.id) < (rhs.date, rhs.id)
        }
    }

    private static func name(_ value: String, _ fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

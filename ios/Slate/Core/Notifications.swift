import Foundation

// MARK: - Settings

/// What a person wants to hear about. Everything is on until they say otherwise.
struct NotificationPreferences: Codable, Equatable, Hashable {
    var bookings = true
    var contracts = true
    var payments = true
    var messages = true
    var reminders = true

    subscript(category: NotificationCategory) -> Bool {
        get {
            switch category {
            case .bookings: bookings
            case .contracts: contracts
            case .payments: payments
            case .messages: messages
            case .reminders: reminders
            }
        }
        set {
            switch category {
            case .bookings: bookings = newValue
            case .contracts: contracts = newValue
            case .payments: payments = newValue
            case .messages: messages = newValue
            case .reminders: reminders = newValue
            }
        }
    }
}

enum NotificationCategory: String, CaseIterable, Identifiable {
    case bookings, contracts, payments, messages, reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookings: "Bookings"
        case .contracts: "Contracts"
        case .payments: "Payments"
        case .messages: "Messages"
        case .reminders: "Shoot reminders"
        }
    }

    var detail: String {
        switch self {
        case .bookings: "New bookings, cancellations, final files shared or received, and reviews."
        case .contracts: "When a contract is signed by both of you."
        case .payments: "Deposits and balances received."
        case .messages: "New messages in a booking's conversation."
        case .reminders: "A day before and two hours before each shoot."
        }
    }

    var systemImage: String {
        switch self {
        case .bookings: "calendar.badge.plus"
        case .contracts: "signature"
        case .payments: "creditcard"
        case .messages: "bubble.left.and.bubble.right"
        case .reminders: "bell"
        }
    }
}

// MARK: - Devices

/// Which of Apple's push servers a build talks to: Xcode builds use the sandbox, TestFlight and the App Store use production.
enum PushEnvironment: String, Codable, Equatable {
    case sandbox, production

    static var current: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

enum DeviceToken {
    /// The lowercase hex the database stores.
    static func hex(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Reminders

enum ReminderRules {
    /// Minutes before a shoot. `notification_rules.json` holds the same numbers for the database.
    static let leadMinutes = [1440, 120]
    /// iOS keeps at most 64 pending local notifications; stay under that and leave room for others.
    static let maxPending = 50
    static let identifierPrefix = "slate.reminder."
}

/// One reminder to schedule on the device.
struct PlannedReminder: Identifiable, Equatable, Hashable {
    var id: String
    var bookingID: UUID
    var fireDate: Date
    var title: String
    var body: String
}

/// Which shoot reminders to schedule on the device. Used when no server sends them (on-device mode); with a server
/// the database queues them and `send-push` delivers them, so the app must not schedule its own as well.
///
/// The rules match `enqueue_due_reminders` in SQL: confirmed bookings that haven't started, reminded a day and two
/// hours before, only if the booking was made before the reminder time.
enum ReminderPlanner {
    static func plan(
        bookings: [Booking], userID: UUID, now: Date, enabled: Bool = true, limit: Int = ReminderRules.maxPending
    ) -> [PlannedReminder] {
        guard enabled else { return [] }
        var planned: [PlannedReminder] = []
        for booking in bookings where booking.involves(userID) {
            guard booking.effectiveStatus(at: now) == .confirmed, booking.startAt > now else { continue }
            let other = booking.isProviderFor(userID) ? booking.clientName : booking.creatorName
            for lead in ReminderRules.leadMinutes {
                let fire = booking.startAt.addingTimeInterval(-Double(lead) * 60)
                guard fire > now, booking.createdAt < fire else { continue }
                let (title, body) = wording(booking: booking, other: other, leadMinutes: lead, at: fire)
                planned.append(PlannedReminder(
                    id: "\(ReminderRules.identifierPrefix)\(booking.id.uuidString.lowercased()).\(lead).\(Int(booking.startAt.timeIntervalSince1970))",
                    bookingID: booking.id,
                    fireDate: fire,
                    title: title,
                    body: body
                ))
            }
        }
        return Array(planned.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
    }

    /// The same words `send-push` uses for server reminders.
    static func wording(booking: Booking, other: String, leadMinutes: Int, at moment: Date) -> (title: String, body: String) {
        let zone = booking.timeZone
        let time = NoticeFormat.clock(booking.startAt, in: zone)
        let package = booking.packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "your booking" : booking.packageName
        let trimmedOther = other.trimmingCharacters(in: .whitespacesAndNewlines)
        let withWho = trimmedOther.isEmpty ? package : "\(package) with \(trimmedOther)"
        if leadMinutes >= 720 {
            let label = NoticeFormat.dayLabel(booking.startAt, relativeTo: moment, in: zone)
            switch label {
            case "tomorrow": return ("Shoot tomorrow", "\(withWho) at \(time)")
            case "today": return ("Shoot today", "\(withWho) at \(time)")
            default: return ("Shoot coming up", "\(withWho) on \(label) at \(time)")
            }
        }
        let hours = max(1, Int((Double(leadMinutes) / 60).rounded()))
        return ("Shoot in \(hours) hour\(hours == 1 ? "" : "s")", "\(withWho) at \(time)")
    }
}

// MARK: - Dates for notifications

/// Locale-free date wording for notifications, so they read the same on every device and from the server.
enum NoticeFormat {
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// "10:00 AM"
    static func clock(_ date: Date, in zone: TimeZone) -> String {
        ContractFormat.time(date, in: zone)
    }

    /// "Sat, Nov 14"
    static func shortDate(_ date: Date, in zone: TimeZone) -> String {
        let calendar = calendar(zone)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        return "\(weekdays[(parts.weekday ?? 1) - 1]), \(months[(parts.month ?? 1) - 1]) \(parts.day ?? 1)"
    }

    /// "Sat, Nov 14 at 10:00 AM"
    static func shootTime(_ date: Date, in zone: TimeZone) -> String {
        "\(shortDate(date, in: zone)) at \(clock(date, in: zone))"
    }

    /// "today", "tomorrow", or "Sat, Nov 14", counted in calendar days in the shoot's zone.
    static func dayLabel(_ date: Date, relativeTo now: Date, in zone: TimeZone) -> String {
        let calendar = calendar(zone)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return shortDate(date, in: zone)
        }
    }
}

// MARK: - Links

/// Where a `slate://` link goes. Used for links from outside the app, calendar events and notification taps.
enum AppLink: Equatable {
    case creatorPage(handle: String)
    case booking(UUID?)
    case messages(UUID?)
    case stripeReturn

    init?(url: URL) {
        guard url.scheme == AppConfig.urlScheme, let host = url.host else { return nil }
        let last = url.lastPathComponent
        switch host {
        case "book":
            let handle = last.lowercased()
            guard !handle.isEmpty, handle != "/" else { return nil }
            self = .creatorPage(handle: handle)
        case "booking":
            self = .booking(UUID(uuidString: last))
        case "messages":
            self = .messages(UUID(uuidString: last))
        case "stripe":
            self = .stripeReturn
        default:
            return nil
        }
    }

    static func bookingURL(_ id: UUID) -> URL? { URL(string: "\(AppConfig.urlScheme)://booking/\(id.uuidString.lowercased())") }
    static func messagesURL(_ id: UUID) -> URL? { URL(string: "\(AppConfig.urlScheme)://messages/\(id.uuidString.lowercased())") }
}

/// Reads where a tapped notification should go. Remote pushes and local reminders both carry `slate.url`.
enum NotificationRouting {
    static let infoKey = "slate"

    static func url(fromUserInfo userInfo: [AnyHashable: Any]) -> URL? {
        guard let slate = userInfo[infoKey] as? [String: Any], let text = slate["url"] as? String else { return nil }
        return URL(string: text)
    }
}

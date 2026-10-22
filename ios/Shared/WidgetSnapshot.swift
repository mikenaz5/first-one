import Foundation

// Shared between the app and the home screen widget (both targets compile this file), so it imports nothing
// from the app. The app writes a `WidgetSnapshot` whenever its bookings change; the widget only reads it.

/// One booking as the widget shows it.
struct WidgetBooking: Codable, Equatable, Identifiable {
    var id: UUID
    /// The package, e.g. "Wedding day".
    var title: String
    /// Who it is with, from the signed-in person's side: "with Dana Lens", "Client: Sam".
    var counterpart: String
    var startAt: Date
    var endAt: Date
    var timeZoneID: String

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
}

/// What the app tells the widget.
struct WidgetSnapshot: Codable, Equatable {
    enum State: String, Codable {
        case signedOut, signedIn
    }

    var state: State
    /// Upcoming confirmed bookings, soonest first.
    var bookings: [WidgetBooking]

    static let signedOut = WidgetSnapshot(state: .signedOut, bookings: [])

    /// The moments the widget should redraw by itself, soonest first, starting with `now`: whenever a booking
    /// finishes (it drops off) and at the next midnight in a booking's own time zone (so "Tomorrow" becomes "Today").
    func refreshDates(from now: Date) -> [Date] {
        var dates: Set<Date> = [now]
        for booking in upcoming(at: now) {
            dates.insert(booking.endAt)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = booking.timeZone
            if let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime),
               midnight < booking.endAt {
                dates.insert(midnight)
            }
        }
        return dates.sorted()
    }

    /// The bookings still ahead at a moment: one whose shoot has finished drops off.
    func upcoming(at date: Date) -> [WidgetBooking] {
        bookings.filter { $0.endAt > date }.sorted { ($0.startAt, $0.id.uuidString) < ($1.startAt, $1.id.uuidString) }
    }
}

// MARK: - Storage

/// The file the app and the widget share, inside the App Group's container.
enum WidgetStore {
    static let fileName = "next-bookings.json"
    /// Used when the build doesn't say which group it belongs to. `Config/App.xcconfig` sets `APP_GROUP_ID`, and both
    /// targets' Info.plists carry it as `SlateAppGroup`.
    static let fallbackGroupID = "group.com.example.slate"

    static var groupID: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "SlateAppGroup") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return fallbackGroupID }
        return value
    }

    /// The App Group's folder, or nil when this build isn't signed with the group (a simulator build without
    /// signing, or a team that hasn't registered it). Then there is simply no widget data, and nothing else breaks.
    static var sharedDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func write(_ snapshot: WidgetSnapshot, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    static func read(from directory: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: - Wording

enum WidgetDay: Equatable {
    case today, tomorrow, later
}

/// Dates for the widget. Days are counted in the shoot's own time zone, and times are shown there too, so a shoot in
/// another city reads the way it will happen. Wording follows the person's language and clock settings.
enum WidgetFormat {
    static func day(of date: Date, relativeTo now: Date, in zone: TimeZone) -> WidgetDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        default: return .later
        }
    }

    /// "Today", "Tomorrow", or "Sat, Nov 14".
    static func dayText(of date: Date, relativeTo now: Date, in zone: TimeZone) -> String {
        switch day(of: date, relativeTo: now, in: zone) {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .later: date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// "10:00 AM"
    static func timeText(_ date: Date, in zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    /// "10:00 AM – 11:30 AM"
    static func timeRange(start: Date, end: Date, in zone: TimeZone) -> String {
        "\(timeText(start, in: zone)) – \(timeText(end, in: zone))"
    }
}

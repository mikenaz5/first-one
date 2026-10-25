import SwiftUI
import WidgetKit

// The home screen and lock screen widget: the next booking at a glance. It only reads what the app wrote
// (`WidgetSnapshot`, in the App Group); it never talks to a server. Tapping it opens the booking in the app.

@main
struct SlateWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextBookingWidget()
    }
}

struct NextBookingWidget: Widget {
    static let kind = "NextBooking"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NextBookingProvider()) { entry in
            NextBookingView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Next booking")
        .description("Your next shoot: when it is and who it is with.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Timeline

struct NextBookingEntry: TimelineEntry {
    let date: Date
    let state: WidgetSnapshot.State
    /// What is still ahead at `date`, soonest first.
    let bookings: [WidgetBooking]
}

struct NextBookingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextBookingEntry {
        let start = Date().addingTimeInterval(26 * 3600)
        let sample = WidgetBooking(
            id: UUID(), title: "Portrait session", counterpart: "with Dana Lens",
            startAt: start, endAt: start.addingTimeInterval(3600), timeZoneID: TimeZone.current.identifier
        )
        return NextBookingEntry(date: Date(), state: .signedIn, bookings: [sample])
    }

    func getSnapshot(in context: Context, completion: @escaping (NextBookingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries(from: load(), now: Date())[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextBookingEntry>) -> Void) {
        let now = Date()
        // The app asks for a new timeline whenever its bookings change; this one covers the time in between.
        completion(Timeline(entries: entries(from: load(), now: now), policy: .after(now.addingTimeInterval(6 * 3600))))
    }

    private func load() -> WidgetSnapshot {
        guard let directory = WidgetStore.sharedDirectory, let snapshot = WidgetStore.read(from: directory) else { return .signedOut }
        return snapshot
    }

    /// One entry now, and one each time the picture changes, so the widget moves on by itself.
    func entries(from snapshot: WidgetSnapshot, now: Date) -> [NextBookingEntry] {
        snapshot.refreshDates(from: now).map { date in
            NextBookingEntry(date: date, state: snapshot.state, bookings: snapshot.upcoming(at: date))
        }
    }
}

// MARK: - Views

struct NextBookingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextBookingEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: Home screen

    private var small: some View {
        Group {
            if let next = entry.bookings.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next up").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).textCase(.uppercase)
                    Text(WidgetFormat.dayText(of: next.startAt, relativeTo: entry.date, in: next.timeZone))
                        .font(.title3.weight(.bold))
                    Text(WidgetFormat.timeText(next.startAt, in: next.timeZone))
                        .font(.headline)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(next.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(next.counterpart).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(Self.link(to: next))
            } else {
                empty
            }
        }
    }

    private var medium: some View {
        Group {
            if entry.bookings.isEmpty {
                empty
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coming up").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).textCase(.uppercase)
                    ForEach(entry.bookings.prefix(3)) { booking in
                        Link(destination: Self.link(to: booking)) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(booking.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(booking.counterpart).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(WidgetFormat.dayText(of: booking.startAt, relativeTo: entry.date, in: booking.timeZone))
                                        .font(.caption.weight(.semibold))
                                    Text(WidgetFormat.timeText(booking.startAt, in: booking.timeZone))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: entry.state == .signedOut ? "person.crop.circle" : "calendar")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(entry.state == .signedOut ? "Sign in to Slate Pro" : "No upcoming bookings")
                .font(.subheadline.weight(.semibold))
            Text(entry.state == .signedOut ? "Open the app to see your next shoot." : "New bookings appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock screen

    private var rectangular: some View {
        Group {
            if let next = entry.bookings.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text("\(WidgetFormat.dayText(of: next.startAt, relativeTo: entry.date, in: next.timeZone)), \(WidgetFormat.timeText(next.startAt, in: next.timeZone))")
                        .font(.caption)
                        .monospacedDigit()
                    Text(next.counterpart).font(.caption).lineLimit(1).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(Self.link(to: next))
            } else {
                Text(entry.state == .signedOut ? "Sign in to Slate Pro" : "No upcoming bookings")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var inline: some View {
        Group {
            if let next = entry.bookings.first {
                Text("\(next.title) · \(WidgetFormat.dayText(of: next.startAt, relativeTo: entry.date, in: next.timeZone)) \(WidgetFormat.timeText(next.startAt, in: next.timeZone))")
                    .widgetURL(Self.link(to: next))
            } else {
                Text("No upcoming bookings")
            }
        }
    }

    /// Where tapping a booking goes: `slate://booking/<id>`, which the app already handles for notifications.
    static func link(to booking: WidgetBooking) -> URL {
        URL(string: "slate://booking/\(booking.id.uuidString.lowercased())") ?? URL(string: "slate://")!
    }
}

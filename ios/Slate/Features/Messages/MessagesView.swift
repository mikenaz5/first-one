import SwiftUI

/// Messages tab: one conversation per booking, newest first.
struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.messagesPath) {
            Group {
                if model.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Each booking gets its own conversation with your client. It opens as soon as someone books.")
                    }
                } else {
                    list
                }
            }
            .slatePageBackground()
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { id in
                ConversationView(bookingID: id)
            }
            .refreshable { await model.refreshConversations() }
        }
        .task(id: scenePhase) {
            // Keep the list fresh while it's showing.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshConversations()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.conversations) { summary in
                NavigationLink(value: summary.bookingID) {
                    ConversationRow(summary: summary)
                }
                .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
                .swipeActions(edge: .leading) {
                    if summary.unreadCount > 0 {
                        Button("Read", systemImage: "envelope.open") {
                            Task { await model.markConversationRead(summary.bookingID) }
                        }
                        .tint(.accentColor)
                    }
                }
                .contextMenu {
                    if summary.unreadCount > 0 {
                        Button("Mark as read", systemImage: "envelope.open") {
                            Task { await model.markConversationRead(summary.bookingID) }
                        }
                    }
                    Button("Open booking", systemImage: "calendar") { model.openBooking(summary.bookingID) }
                }
            }

            if model.isLocalBackend {
                Section {
                    Label(
                        "Messages stay on this phone. Sign in as the other person here to see their side.",
                        systemImage: "iphone"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }
                    .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .motionSafe(.slateSmooth, value: model.conversations.map(\.bookingID))
    }
}

// MARK: - Row

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let summary: ConversationSummary

    private var booking: Booking? { model.booking(withID: summary.bookingID) }
    private var name: String { booking.map(model.counterpartName(for:)) ?? "Conversation" }
    private var unread: Bool { summary.unreadCount > 0 }

    private var preview: String {
        ConversationText.preview(of: summary.last, booking: booking, viewerID: model.session?.userID)
    }

    var body: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: name, url: nil, size: Metrics.avatarS)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                AdaptiveStack(spacing: Space.s) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(unread ? Color.accentColor : Color.secondary)
                }
                if let booking {
                    Text(booking.packageName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(unread ? Color.primary : Color.secondary)
                    .fontWeight(unread ? .semibold : .regular)
                    .lineLimit(2)
            }

            if unread {
                Text("\(summary.unreadCount)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Color.slateOnAccent)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xxs)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .motionSafe(.slateSnappy, value: summary.unreadCount)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(booking?.packageName ?? ""). \(unread ? "\(summary.unreadCount) unread. " : "")\(preview)")
    }

    /// "10:42 AM" today, "Yesterday", or the date.
    private var timestamp: String {
        let date = summary.last.createdAt
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

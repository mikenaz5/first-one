import Foundation

extension AppModel {
    // MARK: - What to show

    var unreadMessageCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    func conversation(for bookingID: UUID) -> ConversationSummary? {
        conversations.first { $0.bookingID == bookingID }
    }

    func booking(withID id: UUID) -> Booking? {
        bookings.first { $0.id == id }
    }

    /// Whether this booking has a conversation that can still be written to.
    func canMessage(_ booking: Booking) -> Bool {
        booking.clientID != nil && booking.effectiveStatus(at: clock()) != .expired
    }

    /// The other person in a booking, from the signed-in person's side.
    func counterpartName(for booking: Booking) -> String {
        if booking.creatorID == booking.clientID { return "Test booking (you)" }
        if isProviderSide(booking) {
            return booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Client" : booking.clientName
        }
        return booking.creatorName
    }

    // MARK: - Loading

    func refreshConversations() async {
        await conversationSync.run()
    }

    /// The work behind `refreshConversations`, which `CoalescedWork` runs one at a time.
    func refreshConversationsOnce() async {
        guard let session else { return }
        if let latest = try? await backend.loadConversations(for: session.userID) {
            conversations = latest
        }
        await notifications.setBadge(unreadMessageCount)
    }

    /// Marks a conversation read, on screen straight away and on the server.
    func markConversationRead(_ bookingID: UUID) async {
        guard let session else { return }
        if let index = conversations.firstIndex(where: { $0.bookingID == bookingID }), conversations[index].unreadCount > 0 {
            conversations[index].unreadCount = 0
        }
        try? await backend.markConversationRead(bookingID: bookingID, for: session.userID)
        await notifications.setBadge(unreadMessageCount)
    }

    /// Something about the bookings changed (a booking was made, paid, cancelled, delivered): keep what depends on
    /// them in step. Reminders are rescheduled, and the conversation list picks up the new line in each thread.
    func bookingsChanged() {
        reminderSync.request()
        conversationSync.request()
        publishWidget()
    }

    /// Tells the home screen widget what is coming up (it redraws only if that changed).
    func publishWidget() {
        widget.publish(WidgetSnapshotBuilder.make(bookings: bookings, userID: session?.userID, now: clock()))
    }

    // MARK: - Opening screens

    func openBooking(_ id: UUID) {
        selectedTab = .bookings
        bookingsPath = [id]
    }

    func openConversation(_ id: UUID) {
        selectedTab = .messages
        messagesPath = [id]
    }
}

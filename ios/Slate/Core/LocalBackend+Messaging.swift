import Foundation

/// Conversations and notification settings for the on-device backend.
///
/// Every booking has one conversation. Text is written by `sendMessage`; the "booked", "deposit paid" and other
/// system lines are added by this backend's own booking, payment and cancellation code, so nobody can type one.
/// Unread counts follow a read marker per person and conversation, kept as "the last message they have read" rather
/// than a time, so two messages in the same second can't be confused.
extension LocalBackend {
    // MARK: - Storage

    struct ReadMark: Codable, Equatable {
        var bookingID: UUID
        var userID: UUID
        var lastMessageID: UUID
    }

    var messagesURL: URL { root.appendingPathComponent("messages.json") }
    private var readMarksURL: URL { root.appendingPathComponent("conversation_reads.json") }
    private func preferencesURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("notification_preferences.json") }

    func readMessages() -> [Message] {
        read([Message].self, from: messagesURL) ?? []
    }

    private func readMarks() -> [ReadMark] {
        read([ReadMark].self, from: readMarksURL) ?? []
    }

    /// Stored dates are whole seconds, so use whole seconds: what this returns then equals what is read back later.
    private var wholeSecondNow: Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    private func partyBooking(_ id: UUID, for userID: UUID, level: ProviderLevel = .view) -> Booking? {
        readBookings().first { $0.id == id && isParty(userID, $0, level) }
    }

    /// Adds a line the system writes when something happens to a booking. Called only from this backend's own changes.
    func appendSystemMessage(_ event: Message.Event, bookingID: UUID, data: MessageEventData = MessageEventData(), at date: Date) throws {
        var messages = readMessages()
        messages.append(Message(
            id: UUID(), bookingID: bookingID, senderID: nil, kind: .system, body: "", event: event,
            data: data, clientMessageID: nil, createdAt: date
        ))
        try write(messages, to: messagesURL)
    }

    // MARK: - Conversations

    private func unreadCount(in conversation: [Message], bookingID: UUID, userID: UUID, marks: [ReadMark]) -> Int {
        let lastRead = marks.first { $0.bookingID == bookingID && $0.userID == userID }?.lastMessageID
        let readIndex = lastRead.flatMap { id in conversation.firstIndex { $0.id == id } }
        let unseen = readIndex.map { conversation[($0 + 1)...] } ?? conversation[...]
        return unseen.filter { $0.kind == .text && $0.senderID != userID }.count
    }

    func loadConversations(for userID: UUID) async throws -> [ConversationSummary] {
        try expireLapsedHolds()
        let now = self.now
        let messages = readMessages()
        let marks = readMarks()
        var found: [(position: Int, summary: ConversationSummary)] = []
        let orgs = readOrganizations()
        for booking in readBookings() where isParty(userID, booking, .view, in: orgs) {
            // A hold that ran out never became a booking.
            if booking.effectiveStatus(at: now) == .expired { continue }
            let conversation = messages.filter { $0.bookingID == booking.id }
            guard let last = conversation.last, let position = messages.lastIndex(where: { $0.id == last.id }) else { continue }
            let unread = unreadCount(in: conversation, bookingID: booking.id, userID: userID, marks: marks)
            found.append((position, ConversationSummary(bookingID: booking.id, last: last, unreadCount: unread)))
        }
        // Newest first; the stored order is the order things happened.
        return found.sorted { $0.position > $1.position }.map(\.summary)
    }

    func loadMessages(bookingID: UUID, since: Date?, for userID: UUID) async throws -> [Message] {
        // Like the database, a stranger just sees nothing.
        guard partyBooking(bookingID, for: userID) != nil else { return [] }
        let conversation = readMessages().filter { $0.bookingID == bookingID }
        guard let since else { return conversation }
        return conversation.filter { $0.createdAt > since }
    }

    func sendMessage(_ body: String, bookingID: UUID, clientMessageID: UUID, from userID: UUID) async throws -> Message {
        try expireLapsedHolds()
        let now = wholeSecondNow
        guard let booking = partyBooking(bookingID, for: userID, level: .manage) else { throw SlateError.bookingNotFound }

        var messages = readMessages()
        // Sending again after a dropped connection returns the message already stored.
        if let existing = messages.first(where: { $0.bookingID == bookingID && $0.senderID == userID && $0.clientMessageID == clientMessageID }) {
            return existing
        }
        // A hold that ran out never became a booking, and a deleted account has nobody to read the reply.
        if booking.effectiveStatus(at: now) == .expired || booking.clientID == nil { throw SlateError.conversationClosed }

        let cleaned = MessageRules.clean(body)
        if cleaned.isEmpty { throw SlateError.invalidMessage }
        if MessageRules.length(of: cleaned) > MessageRules.maxLength { throw SlateError.messageTooLong }

        let recent = messages.filter { $0.kind == .text && $0.senderID == userID && $0.createdAt > now.addingTimeInterval(-60) }.count
        if recent >= MessageRules.sendsPerMinute { throw SlateError.rateLimited }

        let message = Message(
            id: UUID(), bookingID: bookingID, senderID: userID, kind: .text, body: cleaned, event: nil,
            data: MessageEventData(), clientMessageID: clientMessageID, createdAt: now
        )
        messages.append(message)
        try write(messages, to: messagesURL)
        // Writing back means you have read everything before it.
        try setReadMark(bookingID: bookingID, userID: userID, lastMessageID: message.id)
        return message
    }

    func markConversationRead(bookingID: UUID, for userID: UUID) async throws {
        guard partyBooking(bookingID, for: userID) != nil else { throw SlateError.bookingNotFound }
        guard let last = readMessages().last(where: { $0.bookingID == bookingID }) else { return }
        try setReadMark(bookingID: bookingID, userID: userID, lastMessageID: last.id)
    }

    private func setReadMark(bookingID: UUID, userID: UUID, lastMessageID: UUID) throws {
        var marks = readMarks()
        if let index = marks.firstIndex(where: { $0.bookingID == bookingID && $0.userID == userID }) {
            marks[index].lastMessageID = lastMessageID
        } else {
            marks.append(ReadMark(bookingID: bookingID, userID: userID, lastMessageID: lastMessageID))
        }
        try write(marks, to: readMarksURL)
    }

    // MARK: - Notification settings

    func loadNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences {
        read(NotificationPreferences.self, from: preferencesURL(userID)) ?? NotificationPreferences()
    }

    func saveNotificationPreferences(_ preferences: NotificationPreferences, for userID: UUID) async throws -> NotificationPreferences {
        try fileManager.createDirectory(at: userDirectory(userID), withIntermediateDirectories: true)
        try write(preferences, to: preferencesURL(userID))
        return preferences
    }

    // MARK: - Devices

    struct RegisteredDevice: Codable, Equatable {
        var token: String
        var environment: PushEnvironment
        var userID: UUID
    }

    private var devicesURL: URL { root.appendingPathComponent("devices.json") }

    /// Who each device token belongs to. Nothing here sends anything; it lets tests see what the app registered.
    func registeredDevices() -> [RegisteredDevice] {
        read([RegisteredDevice].self, from: devicesURL) ?? []
    }

    func registerDevice(token: String, environment: PushEnvironment, for userID: UUID) async throws {
        // A phone someone else used before moves to the new owner, as it does in the database.
        var devices = registeredDevices().filter { $0.token != token }
        devices.append(RegisteredDevice(token: token, environment: environment, userID: userID))
        try write(devices, to: devicesURL)
    }

    func unregisterDevice(token: String) async throws {
        try write(registeredDevices().filter { $0.token != token }, to: devicesURL)
    }
}

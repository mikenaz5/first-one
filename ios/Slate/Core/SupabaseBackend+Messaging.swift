import Foundation
import Supabase

/// Conversations and notifications on Supabase.
///
/// Who may read or write what is decided in the database (`…_messaging_notifications.sql`): people read the
/// conversation on their own bookings, text goes through `send_message`, and system lines are written by triggers on
/// the booking itself. Push notifications are queued there too and sent by the `send-push` Edge Function; this file
/// only registers the device and reads and saves the person's settings.
extension SupabaseBackend {
    var sendsPushFromServer: Bool { true }

    // MARK: - Rows

    private struct MessageRow: Decodable {
        var id: String
        var bookingId: String
        var senderId: String?
        var kind: String
        var body: String
        var event: String?
        var data: MessageEventData
        var clientId: String?
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, kind, body, event, data
            case bookingId = "booking_id"
            case senderId = "sender_id"
            case clientId = "client_id"
            case createdAt = "created_at"
        }

        /// Nil for a line this version of the app doesn't understand (a newer kind of event), which is skipped.
        var message: Message? {
            guard let id = UUID(uuidString: id), let bookingID = UUID(uuidString: bookingId), let kind = Message.Kind(rawValue: kind) else { return nil }
            var event: Message.Event?
            if kind == .system {
                guard let known = self.event.flatMap(Message.Event.init(rawValue:)) else { return nil }
                event = known
            }
            return Message(
                id: id, bookingID: bookingID, senderID: senderId.flatMap(UUID.init(uuidString:)), kind: kind,
                body: body, event: event, data: data, clientMessageID: clientId.flatMap(UUID.init(uuidString:)), createdAt: createdAt
            )
        }
    }

    private struct ConversationRow: Decodable {
        var bookingId: String
        var lastMessageId: String
        var lastKind: String
        var lastEvent: String?
        var lastBody: String
        var lastData: MessageEventData
        var lastSenderId: String?
        var lastAt: Date
        var unreadCount: Int

        enum CodingKeys: String, CodingKey {
            case bookingId = "booking_id"
            case lastMessageId = "last_message_id"
            case lastKind = "last_kind"
            case lastEvent = "last_event"
            case lastBody = "last_body"
            case lastData = "last_data"
            case lastSenderId = "last_sender_id"
            case lastAt = "last_at"
            case unreadCount = "unread_count"
        }

        var summary: ConversationSummary? {
            guard let bookingID = UUID(uuidString: bookingId), let messageID = UUID(uuidString: lastMessageId),
                  let kind = Message.Kind(rawValue: lastKind)
            else { return nil }
            var event: Message.Event?
            if kind == .system {
                guard let known = lastEvent.flatMap(Message.Event.init(rawValue:)) else { return nil }
                event = known
            }
            let last = Message(
                id: messageID, bookingID: bookingID, senderID: lastSenderId.flatMap(UUID.init(uuidString:)), kind: kind,
                body: lastBody, event: event, data: lastData, clientMessageID: nil, createdAt: lastAt
            )
            return ConversationSummary(bookingID: bookingID, last: last, unreadCount: unreadCount)
        }
    }

    private struct ListMessagesParams: Encodable {
        var pBookingId: String
        var pSince: Date?
        var pLimit: Int

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pSince = "p_since"
            case pLimit = "p_limit"
        }
    }

    private struct SendMessageParams: Encodable {
        var pBookingId: String
        var pBody: String
        var pClientId: String

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pBody = "p_body"
            case pClientId = "p_client_id"
        }
    }

    private struct BookingParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct PreferencesParams: Encodable {
        var pPrefs: NotificationPreferences

        enum CodingKeys: String, CodingKey { case pPrefs = "p_prefs" }
    }

    private struct RegisterDeviceParams: Encodable {
        var pToken: String
        var pEnvironment: String

        enum CodingKeys: String, CodingKey {
            case pToken = "p_token"
            case pEnvironment = "p_environment"
        }
    }

    private struct UnregisterDeviceParams: Encodable {
        var pToken: String

        enum CodingKeys: String, CodingKey { case pToken = "p_token" }
    }

    // MARK: - Conversations

    func loadConversations(for userID: UUID) async throws -> [ConversationSummary] {
        // Let go of holds that ran out first, so their conversations don't linger. Best effort.
        try? await expireHolds()
        do {
            let rows: [ConversationRow] = try await client.rpc("list_conversations").execute().value
            return rows.compactMap(\.summary)
        } catch {
            throw Self.mapMessageError(error)
        }
    }

    func loadMessages(bookingID: UUID, since: Date?, for userID: UUID) async throws -> [Message] {
        do {
            let rows: [MessageRow] = try await client
                .rpc("list_messages", params: ListMessagesParams(pBookingId: Self.key(bookingID), pSince: since, pLimit: 200))
                .execute()
                .value
            return rows.compactMap(\.message)
        } catch {
            throw Self.mapMessageError(error)
        }
    }

    func sendMessage(_ body: String, bookingID: UUID, clientMessageID: UUID, from userID: UUID) async throws -> Message {
        do {
            let row: MessageRow = try await client
                .rpc("send_message", params: SendMessageParams(pBookingId: Self.key(bookingID), pBody: body, pClientId: Self.key(clientMessageID)))
                .execute()
                .value
            guard let message = row.message else { throw SlateError.backend("The message came back in a form this version can't read.") }
            return message
        } catch {
            throw Self.mapMessageError(error)
        }
    }

    func markConversationRead(bookingID: UUID, for userID: UUID) async throws {
        do {
            try await client.rpc("mark_conversation_read", params: BookingParams(pBookingId: Self.key(bookingID))).execute()
        } catch {
            throw Self.mapMessageError(error)
        }
    }

    // MARK: - Notification settings and devices

    func loadNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences {
        try await client.rpc("get_notification_preferences").execute().value
    }

    func saveNotificationPreferences(_ preferences: NotificationPreferences, for userID: UUID) async throws -> NotificationPreferences {
        try await client.rpc("save_notification_preferences", params: PreferencesParams(pPrefs: preferences)).execute().value
    }

    func registerDevice(token: String, environment: PushEnvironment, for userID: UUID) async throws {
        try await client
            .rpc("register_device", params: RegisterDeviceParams(pToken: token, pEnvironment: environment.rawValue))
            .execute()
    }

    func unregisterDevice(token: String) async throws {
        try await client.rpc("unregister_device", params: UnregisterDeviceParams(pToken: token)).execute()
    }

    /// The SQL functions raise plain tokens such as `conversation_closed`; turn them into typed errors.
    static func mapMessageError(_ error: Error) -> Error {
        if error is SlateError { return error }
        if "\(error)".contains("not_found") { return SlateError.bookingNotFound }
        return mapBookingError(error)
    }
}

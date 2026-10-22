import Foundation
import Observation

/// One open conversation: the lines loaded so far, what's been sent but not yet confirmed, and the actions.
/// Lives only while its screen is showing, so it can read the thread as soon as it arrives.
@MainActor
@Observable
final class ConversationModel {
    let bookingID: UUID
    private let app: AppModel

    private(set) var messages: [Message] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var hasLoaded = false
    private(set) var loadProblem: String?
    /// Bumped for haptics.
    private(set) var sentCount = 0
    private(set) var failedCount = 0

    init(bookingID: UUID, app: AppModel) {
        self.bookingID = bookingID
        self.app = app
    }

    var userID: UUID? { app.session?.userID }
    var booking: Booking? { app.booking(withID: bookingID) }

    // MARK: - Loading

    /// The whole conversation, then everything it said is marked read.
    func load() async {
        guard let userID else { return }
        do {
            let all = try await app.backend.loadMessages(bookingID: bookingID, since: nil, for: userID)
            take(all)
            loadProblem = nil
            hasLoaded = true
            await app.markConversationRead(bookingID)
        } catch {
            loadProblem = error.localizedDescription
            hasLoaded = true
        }
    }

    /// What's new since the last look. Called every few seconds while the conversation is open.
    func refresh() async {
        guard let userID, hasLoaded else { return }
        guard let latest = try? await app.backend.loadMessages(bookingID: bookingID, since: ConversationMerge.cursor(for: messages), for: userID) else {
            return
        }
        let known = Set(messages.map(\.id))
        let arrived = latest.filter { !known.contains($0.id) }
        guard !arrived.isEmpty else { return }
        take(arrived)
        if arrived.contains(where: { $0.kind == .text && !$0.isFrom(userID) }) {
            await app.markConversationRead(bookingID)
        } else {
            await app.refreshConversations()
        }
    }

    private func take(_ incoming: [Message]) {
        messages = ConversationMerge.merge(messages, incoming)
        pending = ConversationMerge.settle(pending, against: messages)
    }

    // MARK: - Sending

    /// Shows the message in the thread straight away and sends it. Returns false if there's nothing sendable.
    @discardableResult
    func send(_ text: String) async -> Bool {
        guard MessageRules.problem(with: text) == nil else { return false }
        let message = PendingMessage(id: UUID(), body: MessageRules.clean(text), createdAt: Date(), state: .sending)
        pending.append(message)
        await deliver(message)
        return true
    }

    func retry(_ id: UUID) async {
        guard let message = pending.first(where: { $0.id == id }), message.state != .sending else { return }
        await deliver(message)
    }

    func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    private func deliver(_ message: PendingMessage) async {
        guard let userID else { return }
        setState(.sending, for: message.id)
        do {
            // The pending message's id is its client id, so a retry after a dropped connection can't post it twice.
            let stored = try await app.backend.sendMessage(message.body, bookingID: bookingID, clientMessageID: message.id, from: userID)
            take([stored])
            pending.removeAll { $0.id == message.id }
            sentCount += 1
            await app.refreshConversations()
        } catch {
            setState(.failed(error.localizedDescription), for: message.id)
            failedCount += 1
        }
    }

    private func setState(_ state: PendingMessage.State, for id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].state = state
    }
}

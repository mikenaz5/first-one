import SwiftUI

/// A booking's conversation: what people wrote, what happened to the booking, and a box to write in.
struct ConversationView: View {
    @Environment(AppModel.self) private var app
    let bookingID: UUID

    @State private var conversation: ConversationModel?

    var body: some View {
        Group {
            if let conversation {
                ConversationContent(conversation: conversation)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .slatePageBackground()
        .onAppear {
            if conversation == nil { conversation = ConversationModel(bookingID: bookingID, app: app) }
            app.openConversationID = bookingID
        }
        .onDisappear {
            if app.openConversationID == bookingID { app.openConversationID = nil }
        }
    }
}

private struct ConversationContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let conversation: ConversationModel

    @State private var draft = ""
    @FocusState private var focused: Bool

    // MARK: Rows

    private enum Row: Identifiable {
        case stamp(Date)
        case message(Message)
        case pending(PendingMessage)

        var id: String {
            switch self {
            case .stamp(let date): "stamp-\(date.timeIntervalSince1970)"
            case .message(let message): message.id.uuidString
            case .pending(let pending): pending.id.uuidString
            }
        }
    }

    /// A time heading goes in when a day changes or half an hour has passed in silence.
    private var rows: [Row] {
        var result: [Row] = []
        var previous: Date?
        for message in conversation.messages {
            if Self.needsStamp(message.createdAt, after: previous) { result.append(.stamp(message.createdAt)) }
            result.append(.message(message))
            previous = message.createdAt
        }
        for pending in conversation.pending {
            if Self.needsStamp(pending.createdAt, after: previous) { result.append(.stamp(pending.createdAt)) }
            result.append(.pending(pending))
            previous = pending.createdAt
        }
        return result
    }

    static func needsStamp(_ date: Date, after previous: Date?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(date, inSameDayAs: previous) || date.timeIntervalSince(previous) > 30 * 60
    }

    private var booking: Booking? { conversation.booking }
    private var name: String { booking.map(app.counterpartName(for:)) ?? "Conversation" }
    private var isOpen: Bool { booking.map(app.canMessage) ?? true }

    // MARK: Body

    var body: some View {
        let rows = self.rows

        Group {
            if !conversation.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty, let problem = conversation.loadProblem {
                ContentUnavailableView {
                    Label("Can't load this conversation", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(problem)
                } actions: {
                    Button("Try Again") { Task { await conversation.load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                thread(rows)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(name).font(.headline)
                    if let booking {
                        Text(booking.packageName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.openBooking(conversation.bookingID)
                } label: {
                    Image(systemName: "calendar")
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
                .accessibilityLabel("Open booking")
            }
        }
        .task(id: scenePhase) {
            // Read it when it opens, then look for new lines every few seconds while the app is in front.
            guard scenePhase == .active else { return }
            await conversation.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                await conversation.refresh()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: conversation.sentCount)
        .sensoryFeedback(.error, trigger: conversation.failedCount)
    }

    private func thread(_ rows: [Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.s) {
                    ForEach(rows) { row in
                        view(for: row).id(row.id)
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.m)
                .frame(maxWidth: Metrics.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: rows.last?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .slateSnappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func view(for row: Row) -> some View {
        switch row {
        case .stamp(let date):
            Text(Self.stampText(date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)

        case .message(let message):
            switch message.kind {
            case .system:
                SystemLine(text: ConversationText.systemLine(message, booking: booking, viewerID: app.session?.userID), event: message.event)
            case .text:
                let mine = message.isFrom(app.session?.userID)
                Bubble(text: message.body, isMine: mine)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(mine ? "You" : name), \(message.createdAt.formatted(date: .omitted, time: .shortened)): \(message.body)")
            }

        case .pending(let pending):
            VStack(alignment: .trailing, spacing: Space.xs) {
                Bubble(text: pending.body, isMine: true, dimmed: true)
                    .onTapGesture {
                        if case .failed = pending.state { Task { await conversation.retry(pending.id) } }
                    }
                if case .failed(let reason) = pending.state {
                    Label("Not sent. \(reason)", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.slateDanger)
                        .multilineTextAlignment(.trailing)
                    HStack(spacing: Space.l) {
                        Button("Try Again") { Task { await conversation.retry(pending.id) } }
                        Button("Delete", role: .destructive) { conversation.discard(pending.id) }
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: Metrics.minTapTarget)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(pending.state == .sending ? "Sending: \(pending.body)" : "Not sent: \(pending.body)")
        }
    }

    static func stampText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) \(time)"
    }

    // MARK: Composer

    @ViewBuilder
    private var footer: some View {
        if isOpen {
            composer
        } else {
            Label("This conversation is closed.", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                .padding(.horizontal, Space.page)
                .background(.bar)
        }
    }

    private var canSend: Bool { MessageRules.problem(with: draft) == nil }

    private var composer: some View {
        VStack(spacing: Space.xs) {
            if MessageRules.remaining(in: draft) < 200 {
                Text("\(MessageRules.remaining(in: draft))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MessageRules.remaining(in: draft) < 0 ? Color.slateDanger : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("\(MessageRules.remaining(in: draft)) characters left")
            }
            HStack(alignment: .bottom, spacing: Space.s) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .frame(minHeight: Metrics.minTapTarget)
                    .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                    .accessibilityLabel("Message")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.largeTitle)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func send() {
        let text = draft
        guard MessageRules.problem(with: text) == nil else { return }
        draft = ""
        Task { await conversation.send(text) }
    }
}

// MARK: - Pieces

private struct Bubble: View {
    let text: String
    let isMine: Bool
    var dimmed = false

    @State private var copiedCount = 0

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: Space.xxxl) }
            Text(text)
                .font(.body)
                .foregroundStyle(isMine ? Color.slateOnAccent : Color.primary)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                        .fill(isMine ? Color.accentColor : Color.slateCard)
                )
                .opacity(dimmed ? 0.6 : 1)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copiedCount += 1
                    }
                }
            if !isMine { Spacer(minLength: Space.xxxl) }
        }
        .sensoryFeedback(.success, trigger: copiedCount)
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

/// "Deposit paid", "Cancelled": something that happened to the booking, in the middle of the thread.
private struct SystemLine: View {
    let text: String
    let event: Message.Event?

    private var symbol: String {
        switch event {
        case .booked: "calendar.badge.plus"
        case .contractSigned: "signature"
        case .depositPaid, .balancePaid: "creditcard"
        case .deliveryShared: "shippingbox"
        case .receiptConfirmed: "checkmark.seal"
        case .reviewed: "star.fill"
        case .cancelled: "xmark.circle"
        case nil: "info.circle"
        }
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xs)
    }
}

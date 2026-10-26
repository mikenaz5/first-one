import SwiftUI

/// Bookings tab: what's coming up and what's done, for bookings you took and bookings you made.
struct BookingsView: View {
    @Environment(AppModel.self) private var model

    enum Scope: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming"
        case past = "Past"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .upcoming
    @State private var pendingCancel: Booking?
    @State private var calendarMessage: String?
    @State private var assignTarget: Booking?
    @State private var showTeamCalendar = false

    private var upcoming: [Booking] {
        let now = Date()
        return model.visibleBookings.filter { $0.isUpcoming(at: now) }.sorted { $0.startAt < $1.startAt }
    }

    /// The shoot is over but the booking isn't: work to deliver, or a balance to pay.
    private var followUp: [Booking] {
        let now = Date()
        return model.visibleBookings.filter { $0.needsFollowUp(at: now) }.sorted { $0.startAt < $1.startAt }
    }

    private var past: [Booking] {
        let now = Date()
        return model.visibleBookings.filter { !$0.isOpen(at: now) }.sorted { $0.startAt > $1.startAt }
    }

    private var visible: [Booking] { scope == .upcoming ? followUp + upcoming : past }

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $model.bookingsPath) {
            List {
                Section {
                    Picker("Show", selection: $scope.animation(.slateSmooth)) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.page, bottom: Space.s, trailing: Space.page))
                }
                    .listRowBackground(Color.slateCard)

                if scope == .upcoming, model.can(.bookingsAssign), !model.assignmentQueue.isEmpty {
                    Section {
                        ForEach(model.assignmentQueue) { booking in
                            Button { assignTarget = booking } label: { AssignmentQueueRow(booking: booking) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
                        }
                    } header: {
                        Text("Needs a person")
                    } footer: {
                        Text("Nobody has these yet. Choose who takes each one.")
                    }
                        .listRowBackground(Color.slateCard)
                }

                if visible.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(scope == .upcoming ? "No upcoming bookings" : "Nothing here yet",
                                  systemImage: scope == .upcoming ? "calendar" : "clock.arrow.circlepath")
                        } description: {
                            Text(scope == .upcoming
                                 ? "When a client books one of your packages, it shows up here with the date and price."
                                 : "Finished and cancelled bookings are kept here.")
                        }
                        .listRowBackground(Color.clear)
                    }
                        .listRowBackground(Color.slateCard)
                } else {
                    if scope == .upcoming {
                        if !followUp.isEmpty {
                            Section("Needs attention") { rows(followUp) }
                                .listRowBackground(Color.slateCard)
                        }
                        if !upcoming.isEmpty {
                            Section {
                                rows(upcoming)
                            } header: {
                                if !followUp.isEmpty { Text("Upcoming") }
                            }
                                .listRowBackground(Color.slateCard)
                        }
                    } else {
                        Section { rows(past) }
                            .listRowBackground(Color.slateCard)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .motionSafe(.slateSmooth, value: visible.map(\.id))
            .slatePageBackground()
            .navigationTitle("Bookings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AccountButton()
                }
                if model.isCompanyActive, model.can(.calendarViewTeam) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Team calendar", systemImage: "calendar.day.timeline.left") { showTeamCalendar = true }
                    }
                }
            }
            .sheet(item: $assignTarget) { booking in AssignSheet(booking: booking) }
            .sheet(isPresented: $showTeamCalendar) { TeamCalendarSheet() }
            .navigationDestination(for: UUID.self) { id in
                BookingDetailView(bookingID: id)
            }
            .refreshable { await model.refresh() }
            .cancelFlow($pendingCancel)
            .alert("Couldn't add to Calendar", isPresented: Binding(get: { calendarMessage != nil }, set: { if !$0 { calendarMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calendarMessage ?? "")
            }
            .sensoryFeedback(.warning, trigger: model.bookings.filter { $0.status == .cancelled }.count)
        }
    }

    @ViewBuilder
    private func rows(_ items: [Booking]) -> some View {
        ForEach(items) { booking in
            NavigationLink(value: booking.id) {
                BookingRow(
                    booking: booking, isMine: model.isMine(booking), summary: model.paymentSummary(for: booking),
                    assignee: model.isMine(booking) ? model.assigneeName(for: booking) : nil
                )
            }
            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if booking.canCancel(at: Date()), model.canManage(booking) {
                    Button("Cancel", systemImage: "xmark.circle", role: .destructive) { pendingCancel = booking }
                }
            }
            .swipeActions(edge: .leading) {
                if booking.status == .confirmed, !model.hasCalendarEvent(for: booking) {
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") {
                        Task { await addToCalendar(booking) }
                    }
                    .tint(.indigo)
                }
            }
            .contextMenu {
                if booking.status == .confirmed, !model.hasCalendarEvent(for: booking) {
                    Button("Add to Calendar", systemImage: "calendar.badge.plus") {
                        Task { await addToCalendar(booking) }
                    }
                }
                if booking.canCancel(at: Date()), model.canManage(booking) {
                    Button("Cancel booking", systemImage: "xmark.circle", role: .destructive) { pendingCancel = booking }
                }
            }
        }
    }

    private func addToCalendar(_ booking: Booking) async {
        do {
            try await model.addToCalendar(booking)
        } catch {
            calendarMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

struct BookingRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    let booking: Booking
    let isMine: Bool
    var summary: PaymentSummary?
    /// For a company's booking: who has it ("You", a name), when that is known.
    var assignee: String?

    private var formatter: SlotFormatter { SlotFormatter(timeZone: booking.timeZone) }
    private var startDay: CalendarDay { CalendarDay(booking.startAt, calendar: formatter.calendar) }

    private var otherParty: String {
        if booking.creatorID == booking.clientID { return "Test booking (you)" }
        if isMine {
            let client = booking.clientName.isEmpty ? "Client" : "Client: \(booking.clientName)"
            if booking.isWaitingForAssignment { return "\(client) · Needs a person" }
            if let assignee { return "\(client) · \(assignee)" }
            return client
        }
        return "with \(booking.creatorName)"
    }

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(spacing: 0) {
                Text(formatter.monthShort(startDay).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.slateAccentText)
                Text("\(startDay.day)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
            .frame(minWidth: Metrics.dateTileWidth, minHeight: Metrics.dateTileHeight)
            .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(booking.packageName).font(.headline)
                Text("\(formatter.dayName(startDay, relativeTo: Date())) · \(formatter.timeRange(start: booking.startAt, end: booking.endAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(otherParty).font(.footnote).foregroundStyle(.secondary)
                // At accessibility sizes there is no room beside the text, so the status goes under it.
                if typeSize.isAccessibilitySize { status }
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize { status }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(booking.accessibilitySummary). \(otherParty).\(summary.map { " \($0.headline)." } ?? "")")
    }

    @ViewBuilder
    private var status: some View {
        if let summary {
            PaymentStatusChip(summary: summary)
                .multilineTextAlignment(.trailing)
        } else if booking.status != .confirmed {
            Text(booking.status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(booking.status == .cancelled ? Color.slateDanger : Color.secondary)
        }
    }
}

// MARK: - Detail

struct BookingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let bookingID: UUID

    @State private var pendingCancel: Booking?
    @State private var calendarMessage: String?
    @State private var addedToCalendar = false
    /// Bumped when the shoot starts, so the delivery section appears without the person leaving the screen.
    @State private var shootStarted = 0
    @State private var assignTarget: Booking?

    private var booking: Booking? { model.bookings.first { $0.id == bookingID } }

    var body: some View {
        Group {
            if let booking {
                content(booking)
            } else {
                ContentUnavailableView("Booking not found", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle(booking?.packageName ?? "Booking")
        .navigationBarTitleDisplayMode(.inline)
        // What the booking says about a card on file; again when the money or the permissions around it change.
        .task(id: [model.payments.count, model.cardPermissions.count, model.cards.count]) {
            if let booking { await model.refreshCardAccess(for: booking) }
        }
    }

    private func content(_ booking: Booking) -> some View {
        let formatter = SlotFormatter(timeZone: booking.timeZone)
        let money = { (cents: Int) in Money.format(cents, code: booking.currencyCode) }

        return List {
            Section("When") {
                LabeledContent("Date", value: formatter.fullDay(booking.startAt))
                LabeledContent("Time", value: formatter.timeRange(start: booking.startAt, end: booking.endAt))
                if let note = formatter.zoneNote {
                    Label(note, systemImage: "globe").font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Status", value: booking.effectiveStatus(at: Date()).title)
            }
                .listRowBackground(Color.slateCard)

            Section("Payment") {
                PaymentStatusCard(booking: booking)
                    .padding(.vertical, Space.xs)
            }
                .listRowBackground(Color.slateCard)

            SavedCardSection(booking: booking)

            FilesSection(booking: booking, tick: shootStarted)

            DeliverySection(booking: booking, tick: shootStarted)

            ReviewSection(booking: booking)

            Section("Package") {
                LabeledContent("Package", value: booking.packageName)
                ForEach(booking.addOns) { addOn in
                    LabeledContent(addOn.name, value: money(addOn.priceCents))
                }
            }
                .listRowBackground(Color.slateCard)

            Section {
                LabeledContent("Total", value: money(booking.totalCents))
                LabeledContent("Deposit", value: money(booking.depositCents))
                LabeledContent("Balance", value: money(booking.balanceCents))
            } header: {
                Text("Price")
            } footer: {
                Text("The deposit confirms the booking. The balance is due once the final files are delivered and confirmed. \(booking.cancellationPolicy.summary).")
            }
                .listRowBackground(Color.slateCard)

            PaymentHistorySection(booking: booking)

            Section("Contract") {
                NavigationLink {
                    SignedContractView(booking: booking)
                } label: {
                    Label("Signed contract and PDF", systemImage: "doc.text")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            }
                .listRowBackground(Color.slateCard)

            if model.canMessage(booking) {
                Section("Messages") {
                    let unread = model.conversation(for: booking.id)?.unreadCount ?? 0
                    NavigationLink {
                        ConversationView(bookingID: booking.id)
                    } label: {
                        HStack {
                            Label("Message \(model.counterpartName(for: booking))", systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            if unread > 0 {
                                Text("\(unread) new")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.slateAccentText)
                            }
                        }
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                }
                    .listRowBackground(Color.slateCard)
            }

            Section("People") {
                LabeledContent(model.accounts.companies.contains { $0.organizationID == booking.creatorID } ? "Company" : "Creator", value: booking.creatorName)
                LabeledContent("Client", value: booking.clientName.isEmpty ? "Client" : booking.clientName)
                if model.isMine(booking), booking.creatorID != model.session?.userID {
                    LabeledContent("Assigned to", value: booking.isWaitingForAssignment ? "Needs a person" : (model.assigneeName(for: booking) ?? "Nobody"))
                    if model.canAssign(booking), booking.canCancel(at: Date()) {
                        Button(booking.assignedTo == nil ? "Assign…" : "Reassign…") { assignTarget = booking }
                            .frame(minHeight: Metrics.minTapTarget)
                    }
                }
            }
                .listRowBackground(Color.slateCard)

            if !booking.notes.isEmpty {
                Section("Notes") { Text(booking.notes) }
                    .listRowBackground(Color.slateCard)
            }

            Section {
                if booking.status == .confirmed {
                    Button {
                        Task { await addToCalendar(booking) }
                    } label: {
                        Label(
                            addedToCalendar || model.hasCalendarEvent(for: booking) ? "Added to Calendar" : "Add to Calendar",
                            systemImage: addedToCalendar || model.hasCalendarEvent(for: booking) ? "checkmark" : "calendar.badge.plus"
                        )
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                    .disabled(addedToCalendar || model.hasCalendarEvent(for: booking))
                }
                if booking.canCancel(at: Date()), model.canManage(booking) {
                    Button("Cancel booking", role: .destructive) { pendingCancel = booking }
                        .frame(minHeight: Metrics.minTapTarget)
                }
            }
                .listRowBackground(Color.slateCard)
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .sheet(item: $assignTarget) { target in AssignSheet(booking: target) }
        .cancelFlow($pendingCancel)
        .task(id: booking.status) { await model.loadReview(for: booking) }
        // The photos and videos on a booking, again when it changes status or the shoot starts.
        .task(id: [booking.status.rawValue, String(shootStarted)]) {
            guard booking.status == .confirmed || booking.status == .completed, booking.startAt <= model.clock() else { return }
            await model.loadFiles(for: booking.id)
        }
        .task(id: booking.startAt) { await waitForShootToStart(booking) }
        .alert("Couldn't add to Calendar", isPresented: Binding(get: { calendarMessage != nil }, set: { if !$0 { calendarMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: addedToCalendar)
    }

    /// Sleeps until the shoot begins (if it hasn't), then asks the screen to look again.
    private func waitForShootToStart(_ booking: Booking) async {
        let wait = booking.startAt.timeIntervalSince(model.clock())
        guard wait > 0 else { return }
        try? await Task.sleep(for: .seconds(wait + 1))
        if !Task.isCancelled { shootStarted += 1 }
    }

    private func addToCalendar(_ booking: Booking) async {
        do {
            try await model.addToCalendar(booking)
            addedToCalendar = true
        } catch {
            calendarMessage = error.localizedDescription
        }
    }
}

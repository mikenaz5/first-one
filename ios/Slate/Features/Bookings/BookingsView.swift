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
    @State private var path: [UUID] = []
    @State private var pendingCancel: Booking?
    @State private var calendarMessage: String?

    private var upcoming: [Booking] {
        let now = Date()
        return model.bookings.filter { $0.isUpcoming(at: now) }.sorted { $0.startAt < $1.startAt }
    }

    private var past: [Booking] {
        let now = Date()
        return model.bookings.filter { !$0.isUpcoming(at: now) }.sorted { $0.startAt > $1.startAt }
    }

    private var visible: [Booking] { scope == .upcoming ? upcoming : past }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("Show", selection: $scope.animation(.slateSmooth)) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Space.s, leading: Space.page, bottom: Space.s, trailing: Space.page))
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
                } else {
                    Section {
                        ForEach(visible) { booking in
                            NavigationLink(value: booking.id) {
                                BookingRow(booking: booking, isMine: model.isMine(booking))
                            }
                            .listRowInsets(EdgeInsets(top: Space.s, leading: Space.l, bottom: Space.s, trailing: Space.l))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if booking.canCancel(at: Date()) {
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
                                if booking.canCancel(at: Date()) {
                                    Button("Cancel booking", systemImage: "xmark.circle", role: .destructive) { pendingCancel = booking }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Bookings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { id in
                BookingDetailView(bookingID: id)
            }
            .refreshable { await model.refresh() }
            .confirmationDialog(
                "Cancel this booking?",
                isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
                titleVisibility: .visible,
                presenting: pendingCancel
            ) { booking in
                Button("Cancel Booking", role: .destructive) { Task { await model.cancel(booking) } }
                Button("Keep Booking", role: .cancel) {}
            } message: { _ in
                Text("The time opens up for other clients. Refunds aren't connected yet.")
            }
            .alert("Couldn't add to Calendar", isPresented: Binding(get: { calendarMessage != nil }, set: { if !$0 { calendarMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calendarMessage ?? "")
            }
            .sensoryFeedback(.warning, trigger: model.bookings.filter { $0.status == .cancelled }.count)
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
    let booking: Booking
    let isMine: Bool

    private var formatter: SlotFormatter { SlotFormatter(timeZone: booking.timeZone) }
    private var startDay: CalendarDay { CalendarDay(booking.startAt, calendar: formatter.calendar) }

    private var otherParty: String {
        if booking.creatorID == booking.clientID { return "Test booking (you)" }
        if isMine { return booking.clientName.isEmpty ? "Client" : "Client: \(booking.clientName)" }
        return "with \(booking.creatorName)"
    }

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(spacing: 0) {
                Text(formatter.monthShort(startDay).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(startDay.day)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 52, height: 56)
            .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(booking.packageName).font(.headline)
                Text("\(formatter.dayName(startDay, relativeTo: Date())) · \(formatter.timeRange(start: booking.startAt, end: booking.endAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(otherParty).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if booking.status != .confirmed {
                Text(booking.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(booking.status == .cancelled ? Color.slateDanger : Color.secondary)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(booking.accessibilitySummary). \(otherParty)")
    }
}

// MARK: - Detail

struct BookingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let bookingID: UUID

    @State private var confirmCancel = false
    @State private var calendarMessage: String?
    @State private var addedToCalendar = false

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
                LabeledContent("Status", value: booking.status.title)
            }

            Section("Package") {
                LabeledContent("Package", value: booking.packageName)
                ForEach(booking.addOns) { addOn in
                    LabeledContent(addOn.name, value: money(addOn.priceCents))
                }
            }

            Section {
                LabeledContent("Total", value: money(booking.totalCents))
                LabeledContent("Deposit", value: money(booking.depositCents))
                LabeledContent("Balance", value: money(booking.balanceCents))
            } header: {
                Text("Price")
            } footer: {
                Text("Payments and contracts aren't connected yet, so nothing has been charged.")
            }

            Section("People") {
                LabeledContent("Creator", value: booking.creatorName)
                LabeledContent("Client", value: booking.clientName.isEmpty ? "Client" : booking.clientName)
            }

            if !booking.notes.isEmpty {
                Section("Notes") { Text(booking.notes) }
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
                if booking.canCancel(at: Date()) {
                    Button("Cancel booking", role: .destructive) { confirmCancel = true }
                        .frame(minHeight: Metrics.minTapTarget)
                }
            }
        }
        .confirmationDialog("Cancel this booking?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Booking", role: .destructive) { Task { await model.cancel(booking) } }
            Button("Keep Booking", role: .cancel) {}
        } message: {
            Text("The time opens up for other clients. Refunds aren't connected yet.")
        }
        .alert("Couldn't add to Calendar", isPresented: Binding(get: { calendarMessage != nil }, set: { if !$0 { calendarMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: addedToCalendar)
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

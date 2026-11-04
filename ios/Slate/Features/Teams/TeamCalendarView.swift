import SwiftUI

/// Everyone's availability in one place: a week to pick a day from, chips to pick people, and for each person a strip
/// of the day showing when they work, what is taken and what is free. Nobody is ever in two places, so what is free
/// here is what a client can be offered.
struct TeamCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// True when this is in a sheet: opening a booking closes the sheet first.
    var closesOnOpen = false

    private enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    @State private var day = Date()
    @State private var data: TeamCalendar = .empty
    @State private var filter: Set<UUID> = []
    @State private var phase: Phase = .loading
    @State private var assignTarget: Booking?
    @State private var events: [TeamEvent] = []
    @State private var eventTarget: EventTarget?
    @State private var showConnect = false

    /// What the event sheet is for: a new event on the day showing, or one that exists.
    private enum EventTarget: Identifiable {
        case new
        case existing(TeamEvent)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let event): event.id.uuidString
            }
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = data.timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    private var weekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var formatter: SlotFormatter { SlotFormatter(timeZone: data.timeZone) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                weekStrip
                filterChips
                content
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.pageWidth)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
        .navigationTitle("Team calendar")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: weekStart) { await load() }
        .sheet(item: $assignTarget) { booking in AssignSheet(booking: booking) }
        .sheet(item: $eventTarget) { target in
            switch target {
            case .new:
                EventEditorSheet(editing: nil, day: day, timeZone: data.timeZone) { Task { await load() } }
            case .existing(let event) where event.canEdit && model.canAddEvents:
                EventEditorSheet(editing: event, day: day, timeZone: data.timeZone) { Task { await load() } }
            case .existing(let event):
                EventDetailSheet(event: event, timeZone: data.timeZone)
            }
        }
        .navigationDestination(isPresented: $showConnect) { CalendarConnectView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.canAddEvents {
                        Button("Add an event", systemImage: "plus") { eventTarget = .new }
                    }
                    Button("Connect your calendar", systemImage: "link") { showConnect = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                }
                .accessibilityLabel("More")
            }
        }
        .onChange(of: model.assignmentQueue.count) { _, _ in Task { await load() } }
        .motionSafe(.slateSmooth, value: filter)
    }

    // MARK: Header

    private var weekStrip: some View {
        VStack(spacing: Space.s) {
            HStack {
                Button {
                    move(weeks: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Previous week")
                Spacer()
                Text(weekTitle).font(.headline)
                Spacer()
                Button {
                    move(weeks: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Next week")
            }
            HStack(spacing: Space.xs) {
                ForEach(weekDays, id: \.self) { date in
                    DayButton(
                        date: date,
                        calendar: calendar,
                        isSelected: calendar.isDate(date, inSameDayAs: day),
                        isToday: calendar.isDateInToday(date)
                    ) {
                        withAnimation(.slateSnappy) { day = date }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: calendar.startOfDay(for: day))
    }

    private var weekTitle: String {
        guard let first = weekDays.first, let last = weekDays.last else { return "" }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: data.timeZone)
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    private var filterChips: some View {
        FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
            FilterChip(title: "Everyone", isSelected: filter.isEmpty) { filter = [] }
            ForEach(data.members) { member in
                FilterChip(title: member.displayName, isSelected: filter.contains(member.userID)) {
                    if filter.contains(member.userID) { filter.remove(member.userID) } else { filter.insert(member.userID) }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .failed(let message):
            VStack(spacing: Space.m) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        let shown = dayRows
        let axis = MemberDayLayout.axis(for: shown.map(\.layout), timeZone: data.timeZone)

        let dayEvents = events(on: day)
        if !dayEvents.isEmpty || model.canAddEvents {
            eventsCard(dayEvents)
        }

        let waiting = data.unassigned.filter { sameDay($0.startAt) }
        if !waiting.isEmpty {
            waitingCard(waiting)
        }

        if shown.isEmpty {
            ContentUnavailableView {
                Label("No one to show", systemImage: "person.2.slash")
            } description: {
                Text("People who take bookings appear here with their hours and what's booked.")
            }
        } else {
            Legend()
            ForEach(shown) { row in
                MemberDayCard(member: row.member, layout: row.layout, axis: axis, formatter: formatter) { entry in
                    open(entry)
                }
            }
        }
    }

    private struct DayRow: Identifiable {
        let member: MemberCalendar
        let layout: MemberDayLayout
        var id: UUID { member.userID }
    }

    /// The people to draw for the day: those chosen, and only those who take bookings or have one that day.
    private var dayRows: [DayRow] {
        data.filtered(to: filter).members
            .map { DayRow(member: $0, layout: MemberDayLayout.make(member: $0, on: day, timeZone: data.timeZone)) }
            .filter { $0.member.bookable || !$0.layout.bookings.isEmpty }
    }

    /// What is on the team calendar that day besides bookings: meetings, editing days, time off.
    private func eventsCard(_ dayEvents: [TeamEvent]) -> some View {
        let names = Dictionary(model.teamMembers.map { ($0.userID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Label("Events", systemImage: "calendar.badge.clock").font(.headline)
                Spacer(minLength: Space.s)
                if model.canAddEvents {
                    Button {
                        eventTarget = .new
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: Metrics.minTapTarget)
                    }
                    .accessibilityLabel("Add an event")
                }
            }
            if dayEvents.isEmpty {
                Text("Nothing on the calendar this day except bookings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(dayEvents) { event in
                Button {
                    eventTarget = .existing(event)
                } label: {
                    HStack(alignment: .top, spacing: Space.m) {
                        RoundedRectangle(cornerRadius: Radius.s / 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: Space.xs)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(event.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(EventText.short(event, formatter: formatter)).font(.footnote).foregroundStyle(.secondary)
                            Text(event.audience(names: names)).font(.footnote).foregroundStyle(.secondary)
                            if !event.blocksBookings {
                                Text("Clients can still book").font(.caption).foregroundStyle(Color.slateAccentText)
                            }
                        }
                        Spacer(minLength: Space.s)
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    /// The events that touch the day showing.
    private func events(on day: Date) -> [TeamEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let range = DateInterval(start: start, end: end)
        return events.filter { IntervalMath.overlaps($0.interval, range) }
    }

    private func waitingCard(_ waiting: [CalendarBooking]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label("Needs a person", systemImage: "person.badge.plus")
                .font(.headline)
            ForEach(waiting) { entry in
                Button {
                    open(entry)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(entry.packageName ?? "Booking").font(.subheadline.weight(.semibold))
                            Text(formatter.timeRange(start: entry.startAt, end: entry.endAt))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Space.s)
                        if model.can(.bookingsAssign), entry.bookingID != nil {
                            Text("Assign").font(.subheadline.weight(.semibold)).foregroundStyle(Color.slateAccentText)
                        }
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.bookingID == nil)
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    // MARK: Actions

    private func sameDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: day) }

    private func move(weeks: Int) {
        guard let next = calendar.date(byAdding: .weekOfYear, value: weeks, to: day) else { return }
        withAnimation(.slateSnappy) { day = next }
    }

    /// A booking opens in the Bookings tab; one still waiting for a person opens the assignment sheet.
    private func open(_ entry: CalendarBooking) {
        guard let id = entry.bookingID else { return }
        if entry.status != .cancelled, let booking = model.booking(withID: id), booking.assignedTo == nil, model.can(.bookingsAssign) {
            assignTarget = booking
        } else {
            if closesOnOpen { dismiss() }
            model.openBooking(id)
        }
    }

    private func load() async {
        let start = weekStart
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }
        do {
            async let loadedEvents = model.loadTeamEvents(from: start, to: end)
            data = try await model.loadTeamCalendar(from: start, to: end)
            events = (try? await loadedEvents) ?? []
            // People who have left the team drop out of the filter.
            filter = filter.intersection(Set(data.members.map(\.userID)))
            phase = .ready
        } catch {
            if phase != .ready { phase = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Pieces

private struct DayButton: View {
    let date: Date
    let calendar: Calendar
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Text(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.narrow)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.slateOnAccent : Color.secondary)
                Text("\(calendar.component(.day, from: date))")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.slateOnAccent : (isToday ? Color.accentColor : Color.primary))
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget + Space.s)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: calendar.timeZone)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Space.m)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(isSelected ? Color.slateOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.slateFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motionSafe(.slateSnappy, value: isSelected)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: Space.l) {
            key(Color.accentColor.opacity(0.22), "Free")
            key(Color.slateWarning.opacity(0.55), "Busy")
            key(Color.accentColor, "Booked")
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func key(_ color: Color, _ title: String) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: Radius.s / 3, style: .continuous).fill(color).frame(width: Metrics.legendKey, height: Metrics.legendKey)
            Text(title)
        }
    }
}

/// One person's day: who they are, a strip of the day, what is free, and their bookings.
private struct MemberDayCard: View {
    let member: MemberCalendar
    let layout: MemberDayLayout
    let axis: DateInterval?
    let formatter: SlotFormatter
    let onOpen: (CalendarBooking) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                AvatarView(name: member.displayName, url: member.avatarURL, size: Metrics.avatarS)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(member.displayName).font(.headline)
                    Text(member.title.isEmpty ? member.role.title : member.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let axis, layout.working != nil || !layout.bookings.isEmpty {
                DayStrip(layout: layout, axis: axis)
                    .frame(height: Metrics.dayStripHeight)
                    .accessibilityHidden(true)
                HStack {
                    Text(formatter.time(axis.start))
                    Spacer()
                    Text(formatter.time(axis.end))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(layout.working != nil && layout.free.isEmpty ? Color.slateWarning : Color.secondary)

            ForEach(layout.bookings) { entry in
                Button {
                    onOpen(entry)
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: entry.isHidden ? "lock" : "calendar")
                            .foregroundStyle(Color.accentColor)
                            .frame(minWidth: Metrics.iconColumn)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(formatter.timeRange(start: entry.startAt, end: entry.endAt)).font(.subheadline.weight(.semibold))
                            Text(entry.isHidden ? "Booked" : [entry.packageName, entry.clientName].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.isHidden)
                .accessibilityElement(children: .combine)
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        if !member.bookable && member.weekly.isEmpty { return "Doesn't take bookings" }
        guard layout.working != nil else { return "Not working this day" }
        if layout.free.isEmpty { return "Fully booked" }
        let spans = layout.free.map { formatter.timeRange(start: $0.start, end: $0.end) }
        return "Free " + spans.joined(separator: ", ")
    }
}

/// The day as a bar. Light where they work, amber where their time is taken, and solid where a booking is.
private struct DayStrip: View {
    let layout: MemberDayLayout
    let axis: DateInterval

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.slateFill)
                if let working = layout.working {
                    segment(working, width: proxy.size.width, color: Color.accentColor.opacity(0.22))
                }
                ForEach(Array(layout.taken.enumerated()), id: \.offset) { _, span in
                    segment(span, width: proxy.size.width, color: Color.slateWarning.opacity(0.55))
                }
                ForEach(layout.bookings) { entry in
                    segment(
                        DateInterval(start: entry.startAt, end: max(entry.endAt, entry.startAt)),
                        width: proxy.size.width, color: Color.accentColor
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        }
    }

    @ViewBuilder
    private func segment(_ interval: DateInterval, width: CGFloat, color: Color) -> some View {
        let total = axis.duration
        let start = max(interval.start, axis.start)
        let end = min(interval.end, axis.end)
        if total > 0, end > start {
            let x = CGFloat(start.timeIntervalSince(axis.start) / total) * width
            let w = CGFloat(end.timeIntervalSince(start) / total) * width
            Rectangle().fill(color).frame(width: max(w, 2)).offset(x: x)
        }
    }
}

/// A short version of the team calendar for the Bookings tab, in a sheet.
struct TeamCalendarSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TeamCalendarView(closesOnOpen: true)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

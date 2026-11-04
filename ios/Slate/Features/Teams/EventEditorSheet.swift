import SwiftUI

/// Adds an event to the team calendar, or changes or removes one. Times are the company's, wherever the phone is.
struct EventEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The event being changed, or nil for a new one.
    let editing: TeamEvent?
    let timeZone: TimeZone
    /// Called after an event is saved or removed, so the calendar behind can reload.
    var onChange: () -> Void = {}

    @State private var draft: TeamEventDraft
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmDelete = false
    @State private var savedCount = 0

    init(editing: TeamEvent?, day: Date, timeZone: TimeZone, onChange: @escaping () -> Void = {}) {
        self.editing = editing
        self.timeZone = timeZone
        self.onChange = onChange
        if let editing {
            _draft = State(initialValue: TeamEventDraft(editing: editing))
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            _draft = State(initialValue: TeamEventDraft(startsAt: start, endsAt: start.addingTimeInterval(3600)))
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    /// The people to choose from: everyone on the team, the Viewers too.
    private var people: [TeamMember] {
        model.teamMembers.sorted { ($0.displayName.lowercased(), $0.userID.uuidString) < ($1.displayName.lowercased(), $1.userID.uuidString) }
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                whenSection
                whoSection
                bookingsSection
                detailsSection

                if let message = shownProblem ?? failure {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.slateDanger)
                    }
                    .listRowBackground(Color.slateCard)
                }

                if editing != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Remove event", systemImage: "trash")
                                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        }
                        .disabled(saving)
                    }
                    .listRowBackground(Color.slateCard)
                }
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle(editing == nil ? "New event" : "Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(draft.problem != nil || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .confirmationDialog("Remove this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove Event", role: .destructive) { Task { await remove() } }
            } message: {
                Text("It disappears from everyone's team calendar. If it was keeping clients from booking someone, that time is open again.")
            }
            .sensoryFeedback(.success, trigger: savedCount)
        }
        .environment(\.timeZone, timeZone)
        .environment(\.calendar, calendar)
    }

    // MARK: Sections

    private var titleSection: some View {
        Section {
            TextField("Name", text: $draft.title)
                .textInputAutocapitalization(.sentences)
                .frame(minHeight: Metrics.minTapTarget)
        } footer: {
            Text("For example: Team meeting, Editing day, Day off.")
        }
        .listRowBackground(Color.slateCard)
    }

    private var whenSection: some View {
        Section {
            Toggle("All day", isOn: allDay)
                .frame(minHeight: Metrics.minTapTarget)
            if draft.allDay {
                DatePicker("From", selection: firstDay, displayedComponents: .date)
                    .frame(minHeight: Metrics.minTapTarget)
                DatePicker("To", selection: lastDay, in: firstDay.wrappedValue..., displayedComponents: .date)
                    .frame(minHeight: Metrics.minTapTarget)
            } else {
                DatePicker("Starts", selection: $draft.startsAt)
                    .frame(minHeight: Metrics.minTapTarget)
                DatePicker("Ends", selection: $draft.endsAt, in: draft.startsAt...)
                    .frame(minHeight: Metrics.minTapTarget)
            }
        } header: {
            Text("When")
        } footer: {
            Text("In the company's time zone, \(timeZone.localizedName(for: .standard, locale: .current) ?? timeZone.identifier).")
        }
        .listRowBackground(Color.slateCard)
        .onChange(of: draft.startsAt) { old, new in
            // Moving the start moves the end with it, so the length stays what it was.
            guard !draft.allDay else { return }
            draft.endsAt = draft.endsAt.addingTimeInterval(new.timeIntervalSince(old))
        }
    }

    private var whoSection: some View {
        Section {
            Toggle("Whole team", isOn: $draft.everyone)
                .frame(minHeight: Metrics.minTapTarget)
            if !draft.everyone {
                ForEach(people) { member in
                    Button {
                        if draft.memberIDs.contains(member.userID) { draft.memberIDs.remove(member.userID) } else { draft.memberIDs.insert(member.userID) }
                    } label: {
                        HStack(spacing: Space.m) {
                            AvatarView(name: member.displayName, url: member.avatarURL, size: Metrics.avatarS)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(member.displayName).foregroundStyle(.primary)
                                Text(member.title.isEmpty ? member.role.title : member.title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Space.s)
                            if draft.memberIDs.contains(member.userID) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(draft.memberIDs.contains(member.userID) ? [.isButton, .isSelected] : .isButton)
                }
            }
        } header: {
            Text("Who it's for")
        }
        .listRowBackground(Color.slateCard)
    }

    private var bookingsSection: some View {
        Section {
            Toggle("Keep clients from booking them", isOn: $draft.blocksBookings)
                .frame(minHeight: Metrics.minTapTarget)
        } footer: {
            Text(draft.blocksBookings
                 ? "While it lasts, a client can't book anyone this event is for. Bookings already made are not changed."
                 : "It only shows on the calendar. Clients can still book these people during it.")
        }
        .listRowBackground(Color.slateCard)
    }

    private var detailsSection: some View {
        Section {
            TextField("Place", text: $draft.location)
                .frame(minHeight: Metrics.minTapTarget)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...8)
                .frame(minHeight: Metrics.minTapTarget, alignment: .topLeading)
        } header: {
            Text("Details")
        }
        .listRowBackground(Color.slateCard)
    }

    // MARK: Bindings

    /// Turning "All day" on snaps the times to whole days; turning it off gives it back an hour at nine.
    private var allDay: Binding<Bool> {
        Binding(
            get: { draft.allDay },
            set: { on in
                draft.allDay = on
                let first = calendar.startOfDay(for: draft.startsAt)
                if on {
                    draft.startsAt = first
                    let lastDayStart = calendar.startOfDay(for: max(draft.endsAt.addingTimeInterval(-1), draft.startsAt))
                    draft.endsAt = calendar.date(byAdding: .day, value: 1, to: lastDayStart) ?? first.addingTimeInterval(86_400)
                } else {
                    let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: first) ?? first
                    draft.startsAt = start
                    draft.endsAt = start.addingTimeInterval(3600)
                }
            }
        )
    }

    private var firstDay: Binding<Date> {
        Binding(
            get: { calendar.startOfDay(for: draft.startsAt) },
            set: { day in
                let length = draft.endsAt.timeIntervalSince(draft.startsAt)
                draft.startsAt = calendar.startOfDay(for: day)
                draft.endsAt = max(draft.startsAt.addingTimeInterval(length), calendar.date(byAdding: .day, value: 1, to: draft.startsAt) ?? draft.startsAt)
            }
        )
    }

    /// The last day it covers, which is the day before the midnight it ends at.
    private var lastDay: Binding<Date> {
        Binding(
            get: { calendar.startOfDay(for: max(draft.endsAt.addingTimeInterval(-1), draft.startsAt)) },
            set: { day in draft.endsAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day }
        )
    }

    /// Mistakes worth saying out loud before Save: a missing name is plain from the empty field.
    private var shownProblem: String? {
        guard let problem = draft.problem, problem != .noTitle else { return nil }
        return EventRules.message(for: problem)
    }

    // MARK: Actions

    private func save() async {
        saving = true
        failure = nil
        defer { saving = false }
        do {
            try await model.saveTeamEvent(draft)
            savedCount += 1
            onChange()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() async {
        guard let editing else { return }
        saving = true
        defer { saving = false }
        do {
            try await model.deleteTeamEvent(editing)
            onChange()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Reading one

/// An event the person can't change: what it is, when, and who it's for.
struct EventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let event: TeamEvent
    let timeZone: TimeZone

    private var names: [UUID: String] {
        Dictionary(model.teamMembers.map { ($0.userID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.title).font(.title3.weight(.semibold))
                    Label(EventText.when(event, in: timeZone), systemImage: "clock")
                    if !event.location.isEmpty {
                        Label(event.location, systemImage: "mappin.and.ellipse")
                    }
                    Label(event.audience(names: names), systemImage: "person.2")
                    if !event.blocksBookings {
                        Label("Clients can still book during it", systemImage: "calendar.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }
                    if !event.createdByName.isEmpty {
                        Label("Added by \(event.createdByName)", systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.slateCard)

                if !event.notes.isEmpty {
                    Section("Notes") {
                        Text(event.notes)
                    }
                    .listRowBackground(Color.slateCard)
                }
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// How an event's time reads, in the company's time zone.
enum EventText {
    static func when(_ event: TeamEvent, in timeZone: TimeZone) -> String {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone)
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        if event.allDay {
            let last = max(event.endsAt.addingTimeInterval(-1), event.startsAt)
            let first = event.startsAt.formatted(day)
            let end = last.formatted(day)
            return first == end ? "\(first), all day" : "\(first) – \(end), all day"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(event.startsAt, inSameDayAs: event.endsAt) {
            return "\(event.startsAt.formatted(day)), \(event.startsAt.formatted(time)) – \(event.endsAt.formatted(time))"
        }
        return "\(event.startsAt.formatted(day)) \(event.startsAt.formatted(time)) – \(event.endsAt.formatted(day)) \(event.endsAt.formatted(time))"
    }

    /// The shorter line on a day's card.
    static func short(_ event: TeamEvent, formatter: SlotFormatter) -> String {
        event.allDay ? "All day" : formatter.timeRange(start: event.startsAt, end: event.endsAt)
    }
}

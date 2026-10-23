import SwiftUI

struct AvailabilitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var settings: AvailabilitySettings
    @State private var showBlackoutEditor = false
    @State private var isSaving = false
    @State private var saved = false
    @State private var calendarNote: String?

    init(initial: AvailabilitySettings) {
        _settings = State(initialValue: initial)
    }

    private var hasChanges: Bool { settings != (model.availability ?? AvailabilitySettings.closed(timeZone: settings.timeZone)) }

    /// Week days in the order this person's calendar starts the week.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        NavigationStack {
            Form {
                hoursSection
                rulesSection
                timeZoneSection
                blackoutSection
                CalendarSyncSection(note: $calendarNote)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Availability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!settings.isValid || !hasChanges)
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .sensoryFeedback(.success, trigger: saved)
            .sheet(isPresented: $showBlackoutEditor) {
                BlackoutEditorSheet { range in
                    withAnimation(.slateSnappy) {
                        settings.blackouts.append(range)
                        settings.blackouts.sort { $0.start < $1.start }
                    }
                }
            }
            .onAppear { model.refreshCalendarAccess() }
            .onChange(of: scenePhase) { _, phase in
                // The person may have changed the permission in Settings and come back.
                if phase == .active { model.refreshCalendarAccess() }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Working hours

    private var hoursSection: some View {
        Section {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                DayHoursRow(weekday: weekday, settings: $settings)
            }
        } header: {
            Text("Working hours")
        } footer: {
            Text(settings.hasOpenDay
                 ? "Clients can book any start time that fits entirely inside these hours."
                 : "Every day is closed, so nobody can book you right now.")
        }
            .listRowBackground(Color.slateCard)
    }

    private var rulesSection: some View {
        Section {
            Picker("Minimum notice", selection: $settings.minNoticeHours) {
                ForEach(AvailabilitySettings.minNoticeOptions, id: \.self) { hours in
                    Text(AvailabilityLabels.notice(hours: hours)).tag(hours)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Book up to", selection: $settings.maxAdvanceDays) {
                ForEach(AvailabilitySettings.advanceOptions, id: \.self) { days in
                    Text("\(days) days ahead").tag(days)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Gap after each booking", selection: $settings.bufferMinutes) {
                ForEach(AvailabilitySettings.bufferOptions, id: \.self) { minutes in
                    Text(minutes == 0 ? "None" : DurationText.short(minutes: minutes)).tag(minutes)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)

            Picker("Start times every", selection: $settings.slotIntervalMinutes) {
                ForEach(AvailabilitySettings.slotIntervalOptions, id: \.self) { minutes in
                    Text(DurationText.short(minutes: minutes)).tag(minutes)
                }
            }
            .frame(minHeight: Metrics.minTapTarget)
        } header: {
            Text("Booking rules")
        } footer: {
            Text("The gap gives you travel and reset time. Another booking can't start until it's over.")
        }
            .listRowBackground(Color.slateCard)
    }

    private var timeZoneSection: some View {
        Section {
            LabeledContent("Time zone", value: AvailabilityLabels.name(of: settings.timeZone))
                .frame(minHeight: Metrics.minTapTarget)
            if settings.timeZoneID != TimeZone.current.identifier {
                Button("Use this device's time zone (\(AvailabilityLabels.name(of: .current)))") {
                    settings.timeZoneID = TimeZone.current.identifier
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
        } footer: {
            Text("Clients see your open times in this time zone.")
        }
            .listRowBackground(Color.slateCard)
    }

    // MARK: Blackout dates

    private var blackoutSection: some View {
        Section {
            ForEach(settings.blackouts) { range in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(AvailabilityLabels.describe(range))
                    if !range.reason.isEmpty {
                        Text(range.reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            .onDelete { settings.blackouts.remove(atOffsets: $0) }

            Button {
                showBlackoutEditor = true
            } label: {
                Label("Add blackout dates", systemImage: "plus.circle.fill")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
        } header: {
            Text("Blackout dates")
        } footer: {
            Text("Holidays, trips or days off. Nobody can book you on these dates.")
        }
            .listRowBackground(Color.slateCard)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveAvailability(settings)
            saved = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't save your availability")
        }
    }
}

// MARK: - One day's hours

private struct DayHoursRow: View {
    let weekday: Int
    @Binding var settings: AvailabilitySettings

    private var dayName: String { Calendar.current.weekdaySymbols[weekday - 1] }
    private var window: TimeWindow? { settings.window(forWeekday: weekday) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Toggle(dayName, isOn: isOpen)
                .frame(minHeight: Metrics.minTapTarget)

            if window != nil {
                HStack(spacing: Space.m) {
                    DatePicker("Opens", selection: opens, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("\(dayName) opens")
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("Closes", selection: closes, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("\(dayName) closes")
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motionSafe(.slateSnappy, value: window != nil)
    }

    private var isOpen: Binding<Bool> {
        Binding(
            get: { window != nil },
            set: { open in
                settings.weekly.removeAll { $0.weekday == weekday }
                if open {
                    // New days copy the first open day's hours, or default to 9 to 5.
                    let template = settings.weekly.first?.window ?? TimeWindow(startMinute: 9 * 60, endMinute: 17 * 60)
                    settings.weekly.append(DayHours(weekday: weekday, window: template))
                }
            }
        )
    }

    private var opens: Binding<Date> {
        Binding(
            get: { AvailabilityLabels.date(forMinute: window?.startMinute ?? 540) },
            set: { newValue in
                guard var current = window else { return }
                let minute = AvailabilityLabels.minute(of: newValue)
                current.startMinute = min(minute, 1425)
                if current.endMinute <= current.startMinute { current.endMinute = min(1440, current.startMinute + 60) }
                update(current)
            }
        )
    }

    private var closes: Binding<Date> {
        Binding(
            get: { AvailabilityLabels.date(forMinute: (window?.endMinute ?? 1020) % 1440) },
            set: { newValue in
                guard var current = window else { return }
                // 12:00 AM as a closing time means "end of day".
                let minute = AvailabilityLabels.minute(of: newValue)
                current.endMinute = minute == 0 ? 1440 : minute
                if current.endMinute <= current.startMinute { current.startMinute = max(0, current.endMinute - 60) }
                update(current)
            }
        )
    }

    private func update(_ newWindow: TimeWindow) {
        guard let index = settings.weekly.firstIndex(where: { $0.weekday == weekday }) else { return }
        settings.weekly[index].window = newWindow
    }
}

// MARK: - Blackout editor

struct BlackoutEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAdd: (BlackoutRange) -> Void

    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.startOfDay(for: Date())
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $start, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        .frame(minHeight: Metrics.minTapTarget)
                    DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                        .frame(minHeight: Metrics.minTapTarget)
                    TextField("Reason (optional)", text: $reason)
                        .frame(minHeight: Metrics.minTapTarget)
                } footer: {
                    Text("Both dates are included.")
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Blackout dates")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: start) { _, newStart in
                if end < newStart { end = newStart }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        // Calendar dates are taken as shown to the person, not shifted by any time zone.
                        let calendar = Calendar.current
                        onAdd(BlackoutRange(
                            start: CalendarDay(start, calendar: calendar),
                            end: CalendarDay(end, calendar: calendar),
                            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Labels

enum AvailabilityLabels {
    static func notice(hours: Int) -> String {
        switch hours {
        case 0: "No minimum"
        case 1: "1 hour"
        case ..<24: "\(hours) hours"
        case 24: "1 day"
        case 168: "1 week"
        default: hours % 24 == 0 ? "\(hours / 24) days" : "\(hours) hours"
        }
    }

    static func name(of timeZone: TimeZone) -> String {
        timeZone.localizedName(for: .standard, locale: .current) ?? timeZone.identifier
    }

    static func date(forMinute minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(hour: (minute / 60) % 24, minute: minute % 60)) ?? Date()
    }

    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func describe(_ range: BlackoutRange) -> String {
        let calendar = Calendar.current
        func text(_ day: CalendarDay) -> String {
            (day.date(in: calendar) ?? Date()).formatted(.dateTime.month(.abbreviated).day().year())
        }
        return range.start == range.end ? text(range.start) : "\(text(range.start)) – \(text(range.end))"
    }
}

extension CalendarDay {
    /// Local midnight on this day in `calendar` (used for display, not for booking maths).
    func date(in calendar: Calendar) -> Date? {
        date(atMinute: 0, in: calendar)
    }
}

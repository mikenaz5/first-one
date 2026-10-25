import SwiftUI

/// The "Apple Calendar" part of the availability form. Two independent features:
/// reading busy time (so clients can't book over your other commitments) and writing bookings.
struct CalendarSyncSection: View {
    @Environment(AppModel.self) private var model
    @Binding var note: String?

    private var prefs: CalendarPreferences { model.calendarPrefs }
    private var access: CalendarService.Access { model.calendarAccess }

    var body: some View {
        Section {
            Toggle("Block times I'm busy", isOn: blockBusy)
                .frame(minHeight: Metrics.minTapTarget)

            if prefs.blockBusyTimes && access.canRead {
                NavigationLink {
                    BusyCalendarsView()
                } label: {
                    LabeledContent("Calendars", value: "\(prefs.busyCalendarIDs.count) selected")
                        .frame(minHeight: Metrics.minTapTarget)
                }

                Toggle("Count all-day events as busy", isOn: allDay)
                    .frame(minHeight: Metrics.minTapTarget)

                HStack {
                    if let last = prefs.lastBusySync {
                        Text("Synced \(last.formatted(.relative(presentation: .named)))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not synced yet").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync now") { Task { await model.syncBusyTime() } }
                        .font(.subheadline)
                        .frame(minHeight: Metrics.minTapTarget)
                }
            }

            Toggle("Add bookings to my calendar", isOn: addBookings)
                .frame(minHeight: Metrics.minTapTarget)

            if prefs.addBookingsToCalendar, access.canRead {
                Picker("Add to", selection: destination) {
                    ForEach(model.calendar.calendars().filter(\.allowsModifications)) { calendar in
                        Text(calendar.title).tag(String?.some(calendar.id))
                    }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }

            if access == .denied || access == .restricted {
                Button("Open Settings to allow calendar access") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .frame(minHeight: Metrics.minTapTarget)
            }
        } header: {
            Text("Apple Calendar")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let note { Text(note).foregroundStyle(Color.slateWarning) }
                Text("Only start and end times of your busy events are shared, never their titles, places or guests. Busy time is as fresh as the last time Slate Pro synced, which happens when you open the app.")
            }
        }
            .listRowBackground(Color.slateCard)
    }

    // MARK: Bindings

    private var blockBusy: Binding<Bool> {
        Binding(
            get: { prefs.blockBusyTimes },
            set: { on in
                Task {
                    if on {
                        let ok = await model.enableBlockBusyTimes()
                        note = ok ? nil : "Calendar access wasn't granted, so busy times can't be blocked."
                    } else {
                        note = nil
                        await model.disableBlockBusyTimes()
                    }
                }
            }
        )
    }

    private var allDay: Binding<Bool> {
        Binding(
            get: { prefs.includeAllDayEvents },
            set: { on in
                model.updateCalendarPrefs { $0.includeAllDayEvents = on }
                Task { await model.syncBusyTime() }
            }
        )
    }

    private var addBookings: Binding<Bool> {
        Binding(
            get: { prefs.addBookingsToCalendar },
            set: { on in
                Task {
                    if on {
                        let ok = await model.enableAddBookingsToCalendar()
                        note = ok ? nil : "Calendar access wasn't granted, so bookings can't be added."
                    } else {
                        note = nil
                        model.disableAddBookingsToCalendar()
                    }
                }
            }
        )
    }

    private var destination: Binding<String?> {
        Binding(
            get: { prefs.destinationCalendarID },
            set: { id in model.updateCalendarPrefs { $0.destinationCalendarID = id } }
        )
    }
}

/// Choose which calendars count as "busy".
struct BusyCalendarsView: View {
    @Environment(AppModel.self) private var model
    @State private var calendars: [CalendarInfo] = []

    private var grouped: [(source: String, calendars: [CalendarInfo])] {
        Dictionary(grouping: calendars, by: \.sourceTitle)
            .map { (source: $0.key, calendars: $0.value) }
            .sorted { $0.source < $1.source }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.calendars) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(calendar.title)
                                if calendar.isNoisy {
                                    Text("Holidays and birthdays").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(minHeight: Metrics.minTapTarget)
                    }
                }
                    .listRowBackground(Color.slateCard)
            }
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Busy calendars")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { calendars = model.calendar.calendars() }
        .onDisappear { Task { await model.syncBusyTime() } }
        .overlay {
            if calendars.isEmpty {
                ContentUnavailableView("No calendars", systemImage: "calendar", description: Text("Allow calendar access to choose which calendars count as busy."))
            }
        }
    }

    private func binding(for calendar: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { model.calendarPrefs.busyCalendarIDs.contains(calendar.id) },
            set: { on in
                model.updateCalendarPrefs { prefs in
                    if on { prefs.busyCalendarIDs.insert(calendar.id) } else { prefs.busyCalendarIDs.remove(calendar.id) }
                }
            }
        )
    }
}

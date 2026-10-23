import SwiftUI

// Bookings that wait for someone to take them, and the sheet that gives one to a person.

/// One waiting booking: when it is, what it is, and who booked it.
struct AssignmentQueueRow: View {
    let booking: Booking

    private var formatter: SlotFormatter { SlotFormatter(timeZone: booking.timeZone) }
    private var startDay: CalendarDay { CalendarDay(booking.startAt, calendar: formatter.calendar) }

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
                Text(booking.requestedMember ? "Asked for a person who's no longer free" : booking.clientName.isEmpty ? "Client" : "Client: \(booking.clientName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Image(systemName: "person.badge.plus")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose who takes this booking")
    }
}

/// Choose who takes a booking, or who it moves to. Only people free for the whole booking can be chosen.
struct AssignSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let booking: Booking

    @State private var options: [AssignmentOption]?
    @State private var failure: String?
    @State private var working: UUID?
    @State private var done = false

    private var formatter: SlotFormatter { SlotFormatter(timeZone: booking.timeZone) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Service", value: booking.packageName)
                    LabeledContent("When", value: "\(formatter.fullDay(booking.startAt)), \(formatter.timeRange(start: booking.startAt, end: booking.endAt))")
                    if !booking.clientName.isEmpty {
                        LabeledContent("Client", value: booking.clientName)
                    }
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    if let options {
                        if options.isEmpty {
                            Text("There's no one on the team who takes bookings.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(options) { option in
                            Button {
                                Task { await assign(option) }
                            } label: {
                                OptionRow(option: option, isCurrent: booking.assignedTo == option.userID, isWorking: working == option.userID)
                            }
                            .buttonStyle(.plain)
                            .disabled(!option.isFree || working != nil || booking.assignedTo == option.userID)
                        }
                    } else if let failure {
                        VStack(spacing: Space.m) {
                            Text(failure).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                    }
                } header: {
                    Text(booking.assignedTo == nil ? "Give it to" : "Move it to")
                } footer: {
                    Text("Only people who are free for the whole booking, buffer included, can take it.")
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .navigationTitle("Assign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working != nil) }
            }
            .task { await load() }
            .sensoryFeedback(.success, trigger: done)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(working != nil)
    }

    private func load() async {
        failure = nil
        do {
            options = try await model.assignmentOptions(for: booking)
        } catch {
            options = nil
            failure = error.localizedDescription
        }
    }

    private func assign(_ option: AssignmentOption) async {
        working = option.userID
        defer { working = nil }
        do {
            try await model.assign(booking, to: option.userID)
            done = true
            dismiss()
        } catch {
            model.show(error, title: "Couldn't assign")
            await load()
        }
    }
}

private struct OptionRow: View {
    let option: AssignmentOption
    let isCurrent: Bool
    let isWorking: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: option.displayName, url: nil, size: Metrics.avatarS)
                .opacity(option.isFree ? 1 : 0.5)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(option.displayName)
                    .font(.headline)
                    .foregroundStyle(option.isFree ? Color.primary : Color.secondary)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(option.isFree && !isCurrent ? Color.slateSuccess : Color.secondary)
            }
            Spacer(minLength: Space.s)
            if isWorking {
                ProgressView()
            } else if isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if isCurrent { return "Has this booking" }
        if option.isFree { return "Free" }
        return option.reason ?? "Not free"
    }
}

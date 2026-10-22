import SwiftUI

/// Book a package: choose add-ons, a date and a time, review the price, confirm.
///
/// The earliest opening is preselected, so the common path is: tap a package (opens this sheet),
/// then tap Book. Anything else (add-ons, another day) is optional.
struct BookingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var booking: BookingModel
    @State private var showReview = false

    init(creator: CreatorProfile, package: ServicePackage) {
        _booking = State(initialValue: BookingModel(creator: creator, package: package))
    }

    private var canBook: Bool { model.canBook(creatorID: booking.creator.id) }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmed = booking.confirmed {
                    BookingConfirmationView(booking: confirmed, contract: booking.signedContract, onDone: { dismiss() })
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    form
                }
            }
            .navigationTitle(booking.confirmed == nil ? booking.package.name : "Booked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if booking.confirmed == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(booking.isSubmitting)
                    }
                }
            }
            .motionSafe(.slateSmooth, value: booking.confirmed?.id)
            .navigationDestination(isPresented: $showReview) {
                ContractReviewView(booking: booking)
            }
            .onChange(of: booking.confirmed?.id) { _, _ in showReview = false }
            .task {
                if booking.capture.fullName.isEmpty { booking.capture.fullName = model.clientDisplayName }
                await booking.load(using: model)
            }
            .sensoryFeedback(.selection, trigger: booking.selectedSlot?.start)
            .sensoryFeedback(.success, trigger: booking.confirmed?.id)
            .sensoryFeedback(.warning, trigger: booking.notice)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(booking.isSubmitting)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                if !canBook {
                    Banner(text: "This is your own package. Clients book it from your page.", symbol: "person.crop.circle.badge.exclamationmark", tint: .slateWarning)
                }
                if let notice = booking.notice {
                    Banner(text: notice, symbol: "exclamationmark.triangle.fill", tint: .slateWarning)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !booking.package.addOns.isEmpty {
                    addOns
                }

                whenSection

                if booking.phase == .ready {
                    notesField
                }

                PriceSummaryCard(summary: booking.summary)

                Text("Next you'll read and sign a short contract. Deposit payment isn't connected yet, so nothing is charged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .slatePageBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .motionSafe(.slateSmooth, value: booking.notice)
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            AvatarView(name: booking.creator.displayName, url: booking.creator.avatarURL, size: Metrics.avatarS)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("with \(booking.creator.displayName)").font(.headline)
                Text("\(DurationText.short(minutes: booking.summary.durationMinutes)) · delivered in \(DurationText.turnaround(days: booking.summary.turnaroundDays))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Add-ons

    private var addOns: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Add to your booking").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(booking.package.addOns.enumerated()), id: \.element.id) { index, addOn in
                    if index > 0 { Divider().padding(.leading, Space.l) }
                    Toggle(isOn: Binding(
                        get: { booking.selectedAddOnIDs.contains(addOn.id) },
                        set: { _ in withAnimation(.slateSnappy) { booking.toggle(addOn) } }
                    )) {
                        AddOnRow(addOn: addOn, currencyCode: booking.package.currencyCode)
                    }
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.xs)
                }
            }
            .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
    }

    // MARK: When

    @ViewBuilder
    private var whenSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("When").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)

            switch booking.phase {
            case .loading:
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Finding open times…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityElement(children: .combine)

            case .failed(let message):
                VStack(spacing: Space.m) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await booking.load(using: model) } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 120)

            case .noAvailability:
                VStack(spacing: Space.s) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No open times").font(.headline)
                    Text("\(booking.creator.displayName) has no openings for this package right now. Try without add-ons, or check back soon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .card(.outlined)

            case .ready:
                soonestChips
                dayStrip
                timeGrid
                if let note = booking.formatter.zoneNote {
                    Label(note, systemImage: "globe")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var soonestChips: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Soonest available").eyebrow()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(booking.soonest) { slot in
                        let selected = booking.selectedSlot?.start == slot.start
                        Button {
                            withAnimation(.slateSnappy) { booking.select(slot) }
                        } label: {
                            Text(booking.formatter.chipLabel(for: slot.start, relativeTo: booking.referenceDate))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, Space.l)
                                .frame(minHeight: Metrics.minTapTarget)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? Color.accentColor : Color.slateCard, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var dayStrip: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Pick a date").eyebrow()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Space.s) {
                        ForEach(booking.days) { entry in
                            DayChip(
                                day: entry.day,
                                formatter: booking.formatter,
                                slotCount: entry.slots.count,
                                isSelected: booking.selectedDay == entry.day
                            ) {
                                withAnimation(.slateSnappy) { booking.selectDay(entry.day) }
                            }
                            .id(entry.day)
                        }
                    }
                }
                .onChange(of: booking.selectedDay) { _, day in
                    guard let day else { return }
                    withAnimation(.slateSmooth) { proxy.scrollTo(day, anchor: .center) }
                }
            }
        }
    }

    private var timeGrid: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let day = booking.selectedDay, let date = booking.selectedSlot?.start {
                Text(booking.formatter.fullDay(date)).eyebrow()
                    .accessibilityLabel("Times for \(booking.formatter.fullDay(date))")
                    .id(day)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.s)], spacing: Space.s) {
                ForEach(booking.slotsForSelectedDay) { slot in
                    let selected = booking.selectedSlot?.start == slot.start
                    Button {
                        withAnimation(.slateSnappy) { booking.select(slot) }
                    } label: {
                        Text(booking.formatter.time(slot.start))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.accentColor : Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(booking.formatter.time(slot.start)) to \(booking.formatter.time(slot.end))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Anything we should know?").eyebrow()
            TextField("Location, ideas, who's involved (optional)", text: $booking.notes, axis: .vertical)
                .lineLimit(2...5)
                .padding(Space.l)
                .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
    }

    // MARK: Bottom bar

    private var buttonTitle: String {
        guard let slot = booking.selectedSlot else { return "Choose a time" }
        return "Review & sign · \(booking.formatter.chipLabel(for: slot.start, relativeTo: booking.referenceDate))"
    }

    private var bottomBar: some View {
        VStack(spacing: Space.xs) {
            Button {
                showReview = true
            } label: {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(booking.selectedSlot == nil || !canBook || booking.phase != .ready)

            Text("\(Money.format(booking.summary.totalCents, code: booking.summary.currencyCode)) total · \(Money.format(booking.summary.depositCents, code: booking.summary.currencyCode)) deposit")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(.bar)
    }
}

// MARK: - Pieces

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

private struct DayChip: View {
    let day: CalendarDay
    let formatter: SlotFormatter
    let slotCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Text(formatter.weekdayShort(day)).font(.caption.weight(.medium))
                Text("\(day.day)").font(.title3.weight(.semibold)).monospacedDigit()
                if day.day == 1 {
                    Text(formatter.monthDay(day).prefix(3)).font(.caption2)
                }
            }
            .frame(width: 56, height: 68)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(formatter.monthDay(day)), \(slotCount) times available")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Itemised price, then what is due now and what is due later.
struct PriceSummaryCard: View {
    let summary: PriceSummary

    private func money(_ cents: Int) -> String { Money.format(cents, code: summary.currencyCode) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Price").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(summary.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(line.title)
                            if let detail = line.detail {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: Space.m)
                        Text(money(line.cents)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }

                Divider()

                HStack {
                    Text("Total").font(.headline)
                    Spacer()
                    Text(money(summary.totalCents)).font(.headline).monospacedDigit()
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        Label("Due when you book", systemImage: "creditcard")
                        Spacer()
                        Text(money(summary.depositCents)).fontWeight(.semibold).monospacedDigit()
                    }
                    HStack {
                        Label("Due later", systemImage: "calendar")
                        Spacer()
                        Text(money(summary.balanceCents)).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(Space.m)
                .background(Color.slateFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            }
            .card()
        }
        .motionSafe(.slateSmooth, value: summary.totalCents)
    }
}

// MARK: - Confirmation

struct BookingConfirmationView: View {
    @Environment(AppModel.self) private var model

    let booking: Booking
    let contract: Contract?
    let onDone: () -> Void

    @State private var appeared = false
    @State private var calendarState: CalendarState = .idle

    private enum CalendarState: Equatable {
        case idle, adding, added, failed(String)
    }

    private var formatter: SlotFormatter { SlotFormatter(timeZone: booking.timeZone) }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(Color.slateSuccess)
                        .symbolEffect(.bounce, value: appeared)
                        .accessibilityHidden(true)
                    Text("You're booked").font(SlateFont.display).multilineTextAlignment(.center)
                    Text("with \(booking.creatorName)").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, Space.xl)

                VStack(alignment: .leading, spacing: Space.m) {
                    detail("calendar", formatter.fullDay(booking.startAt))
                    detail("clock", formatter.timeRange(start: booking.startAt, end: booking.endAt))
                    detail("camera", booking.packageName)
                    if !booking.addOns.isEmpty {
                        detail("plus.circle", booking.addOns.map(\.name).joined(separator: ", "))
                    }
                    detail("creditcard", "\(Money.format(booking.totalCents, code: booking.currencyCode)) total · \(Money.format(booking.depositCents, code: booking.currencyCode)) deposit")
                    if let note = formatter.zoneNote { detail("globe", note) }
                }
                .card()

                if contract != nil {
                    NavigationLink {
                        SignedContractView(booking: booking)
                    } label: {
                        HStack(spacing: Space.m) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.slateSuccess).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text("Contract signed by both of you").font(.subheadline.weight(.semibold))
                                Text("View it or share the signed PDF").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: Metrics.minTapTarget)
                        .card()
                    }
                    .buttonStyle(PressableTileStyle())
                }

                VStack(spacing: Space.m) {
                    Button {
                        Task { await addToCalendar() }
                    } label: {
                        Group {
                            switch calendarState {
                            case .idle, .failed: Label("Add to Calendar", systemImage: "calendar.badge.plus")
                            case .adding: ProgressView()
                            case .added: Label("Added to Calendar", systemImage: "checkmark")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(calendarState == .adding || calendarState == .added)

                    if case .failed(let message) = calendarState {
                        Text(message).font(.footnote).foregroundStyle(Color.slateWarning).multilineTextAlignment(.center)
                    }

                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
        .onAppear { appeared = true }
        .sensoryFeedback(.success, trigger: calendarState == .added)
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24)
        }
        .accessibilityElement(children: .combine)
    }

    private func addToCalendar() async {
        calendarState = .adding
        do {
            try await model.addToCalendar(booking)
            calendarState = .added
        } catch {
            calendarState = .failed(error.localizedDescription)
        }
    }
}

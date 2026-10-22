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
    /// Grows with the text, so a time like "10:30 AM" never wraps in its button.
    @ScaledMetric(relativeTo: .subheadline) private var slotMinWidth = Metrics.timeSlotMinWidth

    init(creator: CreatorProfile, package: ServicePackage, team: [PublicTeamMember] = [], memberID: UUID? = nil) {
        _booking = State(initialValue: BookingModel(creator: creator, package: package, team: team, memberID: memberID))
    }

    private var canBook: Bool { model.canBook(creatorID: booking.creator.id) }

    private var title: String {
        if booking.confirmed != nil { return "Booked" }
        if booking.heldBooking != nil { return "Pay deposit" }
        return booking.package.name
    }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmed = booking.confirmed {
                    BookingConfirmationView(booking: confirmed, contract: booking.signedContract, onDone: { dismiss() })
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if let held = booking.heldBooking {
                    HeldBookingView(booking: booking, held: held)
                        .transition(.opacity)
                } else {
                    form
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if booking.confirmed == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(booking.heldBooking == nil ? "Cancel" : "Close") { dismiss() }.disabled(booking.isSubmitting)
                    }
                }
            }
            .motionSafe(.slateSmooth, value: booking.confirmed?.id)
            .motionSafe(.slateSmooth, value: booking.heldBooking?.id)
            .navigationDestination(isPresented: $showReview) {
                ContractReviewView(booking: booking)
            }
            .onChange(of: booking.confirmed?.id) { _, _ in showReview = false }
            .onChange(of: booking.heldBooking?.id) { _, _ in showReview = false }
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
                if booking.canChoosePerson {
                    personSection
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

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .slatePageBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .motionSafe(.slateSmooth, value: booking.notice)
    }

    private var footnote: String {
        if booking.summary.depositCents == 0 {
            return "Next you'll read and sign a short contract. No deposit is needed; the full price is due after delivery."
        }
        return model.paymentsAreSimulated
            ? "Next you'll read and sign a short contract, then pay the deposit. Demo mode: the payment is pretend and no card is charged."
            : "Next you'll read and sign a short contract, then pay the deposit with Apple Pay."
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

    // MARK: Who

    /// A company's booking goes to whoever is free, or to the person the client picks.
    private var personSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("With")
            Picker(selection: Binding(
                get: { booking.selectedMemberID },
                set: { id in Task { await booking.selectMember(id, using: model) } }
            )) {
                Text("Anyone available").tag(UUID?.none)
                ForEach(booking.choosableTeam) { person in
                    Text(person.displayName).tag(UUID?.some(person.userID))
                }
            } label: {
                Label("Who", systemImage: "person.2")
            }
            .pickerStyle(.menu)
            .frame(minHeight: Metrics.minTapTarget)
            .padding(.horizontal, Space.l)
            .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            Text(booking.selectedMemberID == nil
                 ? "We'll match you with whoever is free at the time you choose."
                 : "Only this person's open times are shown.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Add-ons

    private var addOns: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader("Add to your booking")
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
            SectionHeader("When")

            switch booking.phase {
            case .loading:
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Finding open times…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)
                .accessibilityElement(children: .combine)

            case .failed(let message):
                VStack(spacing: Space.m) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await booking.load(using: model) } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderCompact)

            case .noAvailability:
                VStack(spacing: Space.s) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .heroSymbol(30, weight: .light)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No open times").font(.headline)
                    Text("\(booking.creator.displayName) has no openings for this package right now. Try without add-ons, or check back soon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.placeholderRegular)
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
                                .foregroundStyle(selected ? Color.slateOnAccent : Color.primary)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: slotMinWidth), spacing: Space.s)], spacing: Space.s) {
                ForEach(booking.slotsForSelectedDay) { slot in
                    let selected = booking.selectedSlot?.start == slot.start
                    Button {
                        withAnimation(.slateSnappy) { booking.select(slot) }
                    } label: {
                        Text(booking.formatter.time(slot.start))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget)
                            .foregroundStyle(selected ? Color.slateOnAccent : Color.primary)
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
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
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
            .frame(minWidth: Metrics.dayChipWidth, minHeight: Metrics.dayChipHeight)
            .foregroundStyle(isSelected ? Color.slateOnAccent : Color.primary)
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
            SectionHeader("Price")

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

    private var paymentLine: String {
        let money = { Money.format($0, code: booking.currencyCode) }
        if booking.depositCents == 0 { return "\(money(booking.totalCents)) due after delivery" }
        if booking.balanceCents == 0 { return "\(money(booking.totalCents)) paid in full" }
        return "\(money(booking.depositCents)) deposit paid · \(money(booking.balanceCents)) due after delivery"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .heroSymbol(76, weight: .regular)
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
                    detail("creditcard", paymentLine)
                    if let note = formatter.zoneNote { detail("globe", note) }
                }
                .card()

                if contract?.status == .executed {
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
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
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
                        .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(calendarState == .adding || calendarState == .added)

                    if case .failed(let message) = calendarState {
                        Text(message).font(.footnote).foregroundStyle(Color.slateWarning).multilineTextAlignment(.center)
                    }

                    Button(action: onDone) {
                        Text("Done").frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: Metrics.readableWidth)
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
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(minWidth: Metrics.iconColumn)
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

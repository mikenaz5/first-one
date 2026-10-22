import SwiftUI

/// Home tab: what to do next, and what's coming up.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var firstName: String {
        model.profile?.displayName.split(separator: " ").first.map(String.init) ?? ""
    }

    private var attention: [AttentionItem] { model.attentionItems }

    private var nextBooking: Booking? {
        let now = Date()
        return model.bookings.filter { $0.isUpcoming(at: now) }.min { $0.startAt < $1.startAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text(firstName.isEmpty ? "Welcome back" : "Hi, \(firstName)")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    if model.packages.isEmpty || model.needsAvailability || !model.hasCreatorSignature
                        || (model.hasPackagesWithDeposit && !model.canTakePayments) {
                        SetupCard()
                    }

                    if model.wantsNotificationPrompt {
                        NotificationsPromptCard()
                            .transition(.opacity)
                    }

                    if let nextBooking {
                        NextBookingCard(booking: nextBooking)
                    }

                    if let completeness = model.completeness, !completeness.isComplete {
                        CompletenessCard(completeness: completeness)
                    }

                    if let profile = model.profile, let url = AppConfig.bookingURL(handle: profile.handle) {
                        LinkCard(url: url, handle: profile.handle)
                    }

                    if !attention.isEmpty {
                        AttentionCard(items: attention)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
            .motionSafe(.slateSmooth, value: attention.map(\.id))
            .motionSafe(.slateSmooth, value: nextBooking?.id)
            .slatePageBackground()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Cards

/// Two things a creator needs before clients can book: a package and some hours.
private struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Get ready for bookings").font(.headline)
            step(
                done: !model.packages.isEmpty,
                title: "Create a package",
                detail: "What you offer, for how much."
            )
            step(
                done: !model.needsAvailability,
                title: "Set your working hours",
                detail: "Clients can only book times you're free."
            )
            step(
                done: model.hasCreatorSignature,
                title: "Add your signature",
                detail: "Applied to each contract so clients can book straight away."
            )
            if model.hasPackagesWithDeposit {
                step(
                    done: model.canTakePayments,
                    title: "Set up payments",
                    detail: "So deposits and balances go straight to you."
                )
            }
            Button {
                model.selectedTab = .services
            } label: {
                Text(setupButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: Metrics.buttonLabelHeight)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .card()
    }

    private var setupButtonTitle: String {
        if model.packages.isEmpty { return "Create a package" }
        if model.needsAvailability { return "Set your hours" }
        if !model.hasCreatorSignature { return "Add your signature" }
        return "Set up payments"
    }

    private func step(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.slateSuccess : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "To do")
    }
}

private struct NextBookingCard: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    var body: some View {
        Button {
            model.selectedTab = .bookings
        } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Next up").eyebrow()
                Text(booking.packageName).font(.title3.weight(.semibold))
                let formatter = SlotFormatter(timeZone: booking.timeZone)
                Label(
                    "\(formatter.fullDay(booking.startAt)) · \(formatter.timeRange(start: booking.startAt, end: booking.endAt))",
                    systemImage: "calendar"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(model.isMine(booking) ? "Client: \(booking.clientName.isEmpty ? "Client" : booking.clientName)" : "with \(booking.creatorName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(PressableTileStyle())
        .accessibilityHint("Opens your bookings")
    }
}

private struct LinkCard: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let handle: String

    private var shareButton: some View {
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(minHeight: Metrics.buttonLabelHeight)
        }
        .buttonStyle(.bordered)
    }

    private var openButton: some View {
        Button {
            if let link = AppConfig.bookingDeepLink(handle: handle) { model.handle(url: link) }
        } label: {
            Label("Open as a client", systemImage: "person.crop.circle.badge.checkmark")
                .frame(minHeight: Metrics.buttonLabelHeight)
        }
        .buttonStyle(.bordered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label("Your booking link", systemImage: "link")
                .font(.headline)
            Text(url.absoluteString)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Web booking pages arrive in a later release, so this link doesn't open yet. Inside the app, your page opens at \(AppConfig.urlScheme)://book/\(handle).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) { shareButton; openButton }
                VStack(alignment: .leading, spacing: Space.s) { shareButton; openButton }
            }
        }
        .card()
    }
}

/// What the person has to do about their bookings: pay, confirm, or deliver. Tapping one opens that booking.
private struct AttentionCard: View {
    @Environment(AppModel.self) private var model
    let items: [AttentionItem]

    private let limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Needs attention")
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(limit).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    Button {
                        model.openBooking(item.bookingID)
                    } label: {
                        HStack(alignment: .top, spacing: Space.m) {
                            Image(systemName: item.symbol)
                                .font(.title3)
                                .foregroundStyle(Color.slateWarning)
                                .frame(minWidth: Metrics.iconColumn)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: Space.s)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, Space.s)
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens the booking")
                }
                if items.count > limit {
                    Divider()
                    Button("See all \(items.count) in Bookings") { model.selectedTab = .bookings }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            }
        }
        .card()
    }
}

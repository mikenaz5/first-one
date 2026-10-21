import SwiftUI

/// Home tab: what to do next, and what's coming up.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var firstName: String {
        model.profile?.displayName.split(separator: " ").first.map(String.init) ?? ""
    }

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

                    if model.packages.isEmpty || model.needsAvailability {
                        SetupCard()
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

                    ComingSoonCard(
                        title: "Needs attention",
                        systemImage: "exclamationmark.bubble",
                        message: "Unsigned contracts, balances due and change requests."
                    )
                }
                .padding(.horizontal, Space.page)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
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
            Button {
                model.selectedTab = .services
            } label: {
                Text(model.packages.isEmpty ? "Create a package" : "Set your hours")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .card()
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
            HStack(spacing: Space.m) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(minHeight: Metrics.minTapTarget - Space.m)
                }
                .buttonStyle(.bordered)

                Button {
                    if let link = AppConfig.bookingDeepLink(handle: handle) { model.handle(url: link) }
                } label: {
                    Label("Open as a client", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(minHeight: Metrics.minTapTarget - Space.m)
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }
}

private struct ComingSoonCard: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .card(.outlined)
        .accessibilityElement(children: .combine)
    }
}

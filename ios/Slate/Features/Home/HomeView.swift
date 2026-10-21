import SwiftUI

/// Home tab. Today it shows the link and profile progress; bookings and attention items come later.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var firstName: String {
        model.profile?.displayName.split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Text(firstName.isEmpty ? "Welcome back" : "Hi, \(firstName)")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    if let completeness = model.completeness, !completeness.isComplete {
                        CompletenessCard(completeness: completeness)
                    }

                    if let profile = model.profile, let url = AppConfig.bookingURL(handle: profile.handle) {
                        LinkCard(url: url)
                    }

                    ComingSoonCard(
                        title: "Today",
                        systemImage: "sun.max",
                        message: "Shoots happening today will show up here."
                    )
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

private struct LinkCard: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label("Your booking link", systemImage: "link")
                .font(.headline)
            Text(url.absoluteString)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Booking pages arrive in the next release, so this link doesn't open yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Label("Share link", systemImage: "square.and.arrow.up")
                    .frame(minHeight: Metrics.minTapTarget - Space.m)
            }
            .buttonStyle(.bordered)
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

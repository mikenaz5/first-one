import SwiftUI

/// Connect Slate Pro to the calendars a person already uses. Two ways, and the screen says what each is good for:
///
///  - A private link other calendar apps subscribe to (Apple Calendar, Google Calendar, Outlook, any app that can). It shows
///    their bookings and the team events that are for them. It needs an online account, and the other app decides how
///    often to look again (Google can take up to a day).
///  - Putting those same things into a calendar on this iPhone (including a Google or Outlook account added in the iPhone's
///    Settings), which is instant and works offline.
struct CalendarConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case loading
        case ready(CalendarLink)
        /// There is no server to serve a link (an account on this phone only).
        case unavailable
        case failed(String)
    }

    @State private var phase = Phase.loading
    @State private var copiedCount = 0
    @State private var resetCount = 0
    @State private var confirmReset = false
    @State private var working = false
    @State private var note: String?

    var body: some View {
        List {
            linkSection
            if !model.isClientOnly {
                CalendarSyncSection(note: $note, title: "On this iPhone")
            }
            accountsSection
        }
        .scrollContentBackground(.hidden)
        .slatePageBackground()
        .navigationTitle("Connect your calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAppear { model.refreshCalendarAccess() }
        .sensoryFeedback(.success, trigger: copiedCount)
        .sensoryFeedback(.success, trigger: resetCount)
        .confirmationDialog("Make a new link?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Make a New Link", role: .destructive) { Task { await reset() } }
        } message: {
            Text("The old link stops working in every calendar that uses it. You'll need to add the new one.")
        }
    }

    // MARK: The link

    @ViewBuilder
    private var linkSection: some View {
        Section {
            switch phase {
            case .loading:
                HStack(spacing: Space.m) {
                    ProgressView()
                    Text("Getting your link…").foregroundStyle(.secondary)
                }
                .frame(minHeight: Metrics.minTapTarget)
            case .unavailable:
                Label("Calendar links need an online account. Use On this iPhone below.", systemImage: "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            case .failed(let message):
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load() } }
                        .frame(minHeight: Metrics.minTapTarget)
                }
            case .ready(let link):
                Button {
                    openURL(link.webcalURL)
                } label: {
                    Label("Add to Apple Calendar", systemImage: "calendar.badge.plus")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                if let google = link.googleURL {
                    Button {
                        openURL(google)
                    } label: {
                        Label("Add to Google Calendar", systemImage: "globe")
                            .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                    }
                }
                Button {
                    UIPasteboard.general.string = link.url.absoluteString
                    copiedCount += 1
                } label: {
                    Label(copiedCount > 0 ? "Copied" : "Copy link (for Outlook and others)", systemImage: "doc.on.doc")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Make a new link…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
                .disabled(working)
            }
        } header: {
            Text("Your calendar link")
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Shows your bookings and the team events that are for you, with names and times and nothing about money or contracts. Anyone who has the link can see them, so keep it to yourself.")
                Text("Other calendar apps look for changes on their own schedule. Apple Calendar checks every so often; Google Calendar can take up to a day to show a change. For changes to show straight away, use On this iPhone.")
            }
        }
        .listRowBackground(Color.slateCard)
    }

    // MARK: Accounts on the phone

    private var accountsSection: some View {
        Section {
            if model.calendarAccess.canRead {
                let groups = Dictionary(grouping: model.calendar.calendars().filter { !$0.isNoisy }, by: \.sourceTitle)
                    .map { (account: $0.key, count: $0.value.count) }
                    .sorted { $0.account.lowercased() < $1.account.lowercased() }
                if groups.isEmpty {
                    Text("No calendars found on this iPhone.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.account) { group in
                    LabeledContent(group.account.isEmpty ? "Other" : group.account, value: group.count == 1 ? "1 calendar" : "\(group.count) calendars")
                        .frame(minHeight: Metrics.minTapTarget)
                }
            } else {
                Button {
                    Task {
                        _ = await model.calendar.requestFullAccess()
                        model.refreshCalendarAccess()
                    }
                } label: {
                    Label("Allow calendar access to see your accounts", systemImage: "lock.open")
                        .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
                }
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Open iPhone Settings", systemImage: "gearshape")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
        } header: {
            Text("Calendar accounts on this iPhone")
        } footer: {
            Text("To use a Google, Outlook or other calendar, add that account in the iPhone's Settings under Calendar, then Accounts. It shows up here and in Add to.")
        }
        .listRowBackground(Color.slateCard)
    }

    // MARK: Actions

    private func load() async {
        phase = .loading
        do {
            if let link = try await model.calendarLink() {
                phase = .ready(link)
            } else {
                phase = .unavailable
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func reset() async {
        working = true
        defer { working = false }
        do {
            if let link = try await model.resetCalendarLink() {
                phase = .ready(link)
                copiedCount = 0
                resetCount += 1
            }
        } catch {
            model.show(error, title: "Couldn't make a new link")
        }
    }
}

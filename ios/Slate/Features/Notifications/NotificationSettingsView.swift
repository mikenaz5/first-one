import SwiftUI
import UIKit

/// Whether notifications are allowed, and which kinds to send.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                statusRow
            } footer: {
                Text(statusFooter)
            }

            Section {
                ForEach(NotificationCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        Label {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(category.title)
                                Text(category.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: category.systemImage).accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: Metrics.minTapTarget)
                }
            } header: {
                Text("Tell me about")
            } footer: {
                if !model.backend.sendsPushFromServer {
                    Text("On this phone Slate can only schedule shoot reminders. The other kinds need a Slate server, which this build isn't connected to.")
                }
            }

            if let problem = model.pushRegistrationProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            // Coming back from Settings, show what the person chose there.
            if scenePhase == .active { await model.refreshNotificationStatus() }
        }
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.notificationPreferences[category] },
            set: { newValue in Task { await model.setNotification(category, enabled: newValue) } }
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.notificationAuthorization {
        case .allowed:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.slateSuccess)
                .frame(minHeight: Metrics.minTapTarget)
        case .notDetermined:
            Button {
                Task { await model.enableNotifications() }
            } label: {
                Label("Turn on notifications", systemImage: "bell.badge")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Label("Allow in Settings", systemImage: "gear")
                    .frame(minHeight: Metrics.minTapTarget, alignment: .leading)
            }
        }
    }

    private var statusFooter: String {
        switch model.notificationAuthorization {
        case .allowed: "You'll hear about the things below, even when Slate is closed."
        case .notDetermined: "Slate asks once. You can change your mind any time in Settings."
        case .denied: "Notifications for Slate are off in Settings. Allow them there to hear about bookings, payments and messages."
        }
    }
}

/// The sheet the Profile menu opens.
struct NotificationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// On Home until the person decides: a reason to say yes before the system asks.
struct NotificationsPromptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label("Never miss a booking", systemImage: "bell.badge")
                .font(.headline)
            Text("Hear about new bookings, signed contracts, payments and messages, and get a reminder before each shoot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.m) {
                Button {
                    Task { await model.enableNotifications() }
                } label: {
                    Text("Turn On").frame(minHeight: Metrics.minTapTarget - Space.m)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    withAnimation(.slateSmooth) { model.dismissNotificationPrompt() }
                } label: {
                    Text("Not Now").frame(minHeight: Metrics.minTapTarget - Space.m)
                }
                .buttonStyle(.bordered)
            }
        }
        .card()
    }
}

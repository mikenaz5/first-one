import AuthenticationServices
import EventKit
import SwiftUI

/// Chooses what to show from the account state, and animates between states.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        ZStack {
            switch model.phase {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .signedOut:
                WelcomeView()
                    .transition(.opacity)
            case .onboarding:
                OnboardingFlow()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            case .ready:
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .loadFailed:
                LoadFailedView()
                    .transition(.opacity)
            }
        }
        .motionSafe(.slateSmooth, value: model.phase)
        .onOpenURL { model.handle(url: $0) }
        .sheet(item: $model.presentedPage) { page in
            ClientPageSheet(page: page)
        }
        .onChange(of: scenePhase) { _, phase in
            // Pick up calendar changes and new bookings whenever the app comes back.
            if phase == .active, model.phase == .ready {
                Task { await model.syncCalendar() }
            }
        }
        .task {
            // Re-sync busy time (after a short pause) whenever the person edits their calendar.
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                try? await Task.sleep(for: .seconds(2))
                await model.syncBusyTime()
            }
        }
        .task { await model.bootstrap() }
        .task {
            // If the person revokes Slate in Settings > Apple Account, sign them out.
            let revoked = NotificationCenter.default.notifications(
                named: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            )
            for await _ in revoked {
                await model.signOut()
            }
        }
        .alert(
            model.alert?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.slateBackground.ignoresSafeArea()
            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Slate")
        }
    }
}

private struct LoadFailedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Can't load your account", systemImage: "wifi.exclamationmark")
        } description: {
            Text(model.loadErrorMessage ?? "Check your connection and try again.")
        } actions: {
            Button("Try Again") {
                Task { await model.retryLoad() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
        }
        .slatePageBackground()
    }
}

/// A creator's page opened from a booking link, on top of whatever the person was doing.
private struct ClientPageSheet: View {
    let page: PublicCreatorPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CreatorPageView(profile: page.profile, portfolio: page.portfolio, packages: page.packages, mode: .client)
                .navigationTitle(page.profile.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

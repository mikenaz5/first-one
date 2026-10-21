import AuthenticationServices
import SwiftUI

/// Chooses what to show from the account state, and animates between states.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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

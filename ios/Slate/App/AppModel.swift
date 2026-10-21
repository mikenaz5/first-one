import AuthenticationServices
import Foundation
import Observation

struct ErrorAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Root app state: who is signed in, their profile and portfolio, and the actions that change them.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case onboarding
        case ready
        /// Signed in, but the account couldn't be loaded. Never fall through to onboarding here:
        /// saving a fresh profile would overwrite the real one.
        case loadFailed
    }

    let backend: any SlateBackend

    private(set) var phase: Phase = .launching
    private(set) var loadErrorMessage: String?
    private(set) var session: AuthSession?
    private(set) var profile: CreatorProfile?
    private(set) var portfolio: [PortfolioItem] = []
    var alert: ErrorAlert?

    init(backend: any SlateBackend) {
        self.backend = backend
    }

    /// True when running on-device with no server configured (enables the demo sign-in in debug builds).
    var isLocalBackend: Bool { backend is LocalBackend }

    var completeness: ProfileCompleteness? {
        profile.map { ProfileCompleteness(profile: $0, portfolioCount: portfolio.count) }
    }

    // MARK: - Launch

    func bootstrap() async {
        guard phase == .launching else { return }
        guard let restored = await backend.restoreSession() else {
            phase = .signedOut
            return
        }
        if let appleUserID = restored.appleUserID, appleUserID != AppConfig.demoAppleUserID {
            let state = await Self.credentialState(for: appleUserID)
            if state == .revoked || state == .notFound {
                try? await backend.signOut()
                phase = .signedOut
                return
            }
        }
        session = restored
        await loadAccount()
    }

    private static func credentialState(for userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - Sign in / out

    func signIn(with credential: AppleCredential) async {
        do {
            let newSession = try await backend.signInWithApple(credential)
            UserDefaults.standard.set(credential.userID, forKey: AppConfig.appleUserIDKey)
            session = newSession
            await loadAccount()
        } catch {
            show(error, title: "Couldn't sign in")
        }
    }

    /// Debug-only shortcut for the simulator and previews (needs the local backend).
    func signInAsDemo() async {
        var name = PersonNameComponents()
        name.givenName = "Maya"
        name.familyName = "Chen"
        let credential = AppleCredential(
            userID: AppConfig.demoAppleUserID,
            identityToken: "demo",
            rawNonce: "",
            fullName: name,
            email: "maya@example.com"
        )
        await signIn(with: credential)
    }

    func signOut() async {
        do {
            try await backend.signOut()
        } catch {
            show(error, title: "Couldn't sign out")
            return
        }
        clearAccount()
    }

    func deleteAccount() async {
        do {
            try await backend.deleteAccount()
        } catch {
            show(error, title: "Couldn't delete your account")
            return
        }
        clearAccount()
    }

    private func clearAccount() {
        UserDefaults.standard.removeObject(forKey: AppConfig.appleUserIDKey)
        session = nil
        profile = nil
        portfolio = []
        phase = .signedOut
    }

    // MARK: - Account data

    private func loadAccount() async {
        guard let session else { return }
        do {
            profile = try await backend.loadProfile(for: session.userID)
            portfolio = try await backend.loadPortfolio(for: session.userID)
            loadErrorMessage = nil
            updatePhase()
        } catch {
            loadErrorMessage = error.localizedDescription
            phase = .loadFailed
        }
    }

    func retryLoad() async {
        phase = .launching
        await loadAccount()
    }

    func refresh() async {
        guard let session else { return }
        do {
            profile = try await backend.loadProfile(for: session.userID)
            portfolio = try await backend.loadPortfolio(for: session.userID)
        } catch {
            show(error, title: "Couldn't refresh")
        }
    }

    private func updatePhase() {
        if session == nil {
            phase = .signedOut
        } else if profile?.isComplete == true {
            phase = .ready
        } else {
            phase = .onboarding
        }
    }

    func isHandleAvailable(_ handle: String) async throws -> Bool {
        guard let session else { throw SlateError.notSignedIn }
        return try await backend.isHandleAvailable(handle, excluding: session.userID)
    }

    // MARK: - Profile

    /// Saves the profile, then uploads any portfolio picks. A portfolio failure doesn't undo the
    /// profile: the person lands in the app and can retry from their profile.
    func completeOnboarding(draft: ProfileDraft, portfolio newItems: [NewPortfolioItem]) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let toSave = draft.makeProfile(id: session.userID, existing: profile)
        profile = try await backend.saveProfile(toSave, avatarJPEG: draft.avatarJPEG)

        if !newItems.isEmpty {
            do {
                portfolio = try await backend.addPortfolioItems(newItems, for: session.userID)
            } catch {
                show(error, title: "Some portfolio items didn't upload")
            }
        }
        updatePhase()
    }

    func updateProfile(from draft: ProfileDraft) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let toSave = draft.makeProfile(id: session.userID, existing: profile)
        profile = try await backend.saveProfile(toSave, avatarJPEG: draft.avatarJPEG)
    }

    // MARK: - Portfolio

    func addPortfolio(_ items: [NewPortfolioItem]) async {
        guard let session, !items.isEmpty else { return }
        do {
            portfolio = try await backend.addPortfolioItems(items, for: session.userID)
        } catch {
            show(error, title: "Couldn't add to your portfolio")
        }
    }

    func deletePortfolioItem(_ item: PortfolioItem) async {
        guard let session else { return }
        do {
            portfolio = try await backend.deletePortfolioItem(item.id, for: session.userID)
        } catch {
            show(error, title: "Couldn't delete")
        }
    }

    func movePortfolioItemToFront(_ item: PortfolioItem) async {
        guard let session else { return }
        do {
            portfolio = try await backend.movePortfolioItemToFront(item.id, for: session.userID)
        } catch {
            show(error, title: "Couldn't reorder")
        }
    }

    // MARK: - Errors

    func show(_ error: Error, title: String) {
        // Cancelling the Apple sheet isn't an error worth shouting about.
        if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
        alert = ErrorAlert(title: title, message: error.localizedDescription)
    }
}

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
    /// Shows the payment sheet. Apple Pay with a real server; an instant pretend one on-device.
    let authorizer: any PaymentAuthorizer
    /// The system's notification center, or a stand-in for tests and previews.
    let notifications: any NotificationCenterClient

    private(set) var phase: Phase = .launching
    private(set) var loadErrorMessage: String?
    private(set) var session: AuthSession?
    private(set) var profile: CreatorProfile?
    private(set) var portfolio: [PortfolioItem] = []
    var alert: ErrorAlert?

    // Scheduling state. Internal (not private(set)) because the extensions in
    // AppModel+Packages / +Booking / +Calendar update it from their own files.
    var packages: [ServicePackage] = []
    var availability: AvailabilitySettings?
    var bookings: [Booking] = []
    var contractTemplates: [ContractTemplate] = []
    var creatorSignature: CreatorSignature?
    /// Signed contracts already fetched, by booking, so screens don't wait on the network twice.
    var contractsByBooking: [UUID: Contract] = [:]
    /// Deposits, balances and refunds on this person's bookings, as the backend recorded them.
    var payments: [Payment] = []
    /// A creator's Stripe account, if they have one. Only meaningful for creators.
    var paymentAccount: PaymentAccount?
    var isPaying = false
    var calendarPrefs = CalendarPreferences.load()
    var calendarAccess: CalendarService.Access = .notDetermined
    /// Which tab is showing. Lives here so deep links can switch tabs.
    var selectedTab: AppTab = .home
    /// What each tab's navigation stack has open (booking ids), so notifications and links can open a screen.
    var bookingsPath: [UUID] = []
    var messagesPath: [UUID] = []
    /// Every conversation the person is part of, newest first.
    var conversations: [ConversationSummary] = []
    /// The conversation on screen, if any. A push about it doesn't need a banner.
    var openConversationID: UUID?
    var notificationPreferences = NotificationPreferences()
    var notificationAuthorization: NotificationAuthorization = .notDetermined
    /// Why Apple wouldn't give this build a push token (usually: the build has no push entitlement). Nil when fine.
    var pushRegistrationProblem: String?
    var notificationPromptDismissed = UserDefaults.standard.bool(forKey: AppConfig.notificationPromptDismissedKey)
    /// The token Apple last gave this device, so it can be forgotten when the person signs out.
    @ObservationIgnored var deviceToken: String?
    /// What "now" is for reminders and for who can still be messaged. Tests set it so they don't depend on the day they run.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Syncing reminders and refreshing conversations each run one at a time (see `CoalescedWork`).
    @ObservationIgnored private(set) var reminderSync: CoalescedWork!
    @ObservationIgnored private(set) var conversationSync: CoalescedWork!
    /// What was started when the account loaded, so tests can wait for it.
    @ObservationIgnored var startupTasks: [Task<Void, Never>] = []
    /// A creator's public page opened from a booking link, shown over the app.
    var presentedPage: PublicCreatorPage?
    @ObservationIgnored var pendingBookingHandle: String?
    let calendar = CalendarService()

    init(
        backend: any SlateBackend,
        authorizer: (any PaymentAuthorizer)? = nil,
        notifications: (any NotificationCenterClient)? = nil
    ) {
        self.backend = backend
        self.authorizer = authorizer ?? PaymentAuthorizerFactory.make(for: backend)
        self.notifications = notifications ?? InertNotificationCenter()
        reminderSync = CoalescedWork { [weak self] in await self?.syncRemindersOnce() }
        conversationSync = CoalescedWork { [weak self] in await self?.refreshConversationsOnce() }
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
        await forgetDevice()
        do {
            try await backend.signOut()
        } catch {
            show(error, title: "Couldn't sign out")
            return
        }
        await clearAccount()
    }

    func deleteAccount() async {
        do {
            try await backend.deleteAccount()
        } catch {
            show(error, title: "Couldn't delete your account")
            return
        }
        await clearAccount()
    }

    private func clearAccount() async {
        UserDefaults.standard.removeObject(forKey: AppConfig.appleUserIDKey)
        session = nil
        profile = nil
        portfolio = []
        packages = []
        availability = nil
        bookings = []
        contractTemplates = []
        creatorSignature = nil
        contractsByBooking = [:]
        payments = []
        paymentAccount = nil
        presentedPage = nil
        pendingBookingHandle = nil
        await resetNotifications()
        CalendarPreferences.clear()
        calendarPrefs = CalendarPreferences()
        phase = .signedOut
    }

    // MARK: - Account data

    private func loadAccount() async {
        guard let session else { return }
        do {
            profile = try await backend.loadProfile(for: session.userID)
            portfolio = try await backend.loadPortfolio(for: session.userID)
            try await loadScheduling(for: session.userID)
            loadErrorMessage = nil
            updatePhase()
            afterAccountLoaded()
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
            try await loadScheduling(for: session.userID)
            Task { await syncCalendar() }
            Task { await settlePendingRefunds() }
            bookingsChanged()
        } catch {
            show(error, title: "Couldn't refresh")
        }
    }

    private func updatePhase() {
        if session == nil {
            phase = .signedOut
        } else if profile?.isComplete == true {
            phase = .ready
            Task { await openPendingBookingLinkIfNeeded() }
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

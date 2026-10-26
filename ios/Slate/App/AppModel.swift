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
    /// Makes the small copy of a photo or video that the client sees. A stand-in for tests.
    let filePreparer: any FilePreparing
    /// Fetches delivered files and saves them to Photos. A stand-in for tests.
    let fileTransfer: any FileTransferring
    /// Shows the payment sheet. Apple Pay with a real server; an instant pretend one on-device.
    let authorizer: any PaymentAuthorizer
    /// The system's notification center, or a stand-in for tests and previews.
    let notifications: any NotificationCenterClient
    /// Tells the home screen widget what the next booking is.
    let widget: any WidgetPublisher

    private(set) var phase: Phase = .launching
    private(set) var loadErrorMessage: String?
    private(set) var session: AuthSession?
    /// The profile and portfolio of the account being shown: the person's own, or a company's.
    var profile: CreatorProfile?
    var portfolio: [PortfolioItem] = []
    var alert: ErrorAlert?

    // Accounts. A person can act as themselves or as any company they work for, the way Apple's apps switch accounts.
    /// The person's own profile. `profile` is the active account's, which is this one unless a company is showing.
    var personalProfile: CreatorProfile?
    /// Every account this person can act as.
    var accounts: AccountList = .empty
    var activeAccount: ActiveAccount = .personal
    /// The company on screen (its settings, this person's role in it, its seats and plan), when one is.
    var organization: Organization?
    /// The numbers behind seats and invites, from the database so they can change without a release.
    var teamConfig: TeamConfig = .standard
    /// What the active company's roles let this person see. Each is empty for a role that can't see it.
    var teamMembers: [TeamMember] = []
    var teamInvites: [OrgInvite] = []
    var assignmentQueue: [Booking] = []
    /// Who offers each shared service. A service with no entry is offered by everyone who takes bookings.
    var packageMembers: [UUID: [UUID]] = [:]
    /// An invite link opened before the person was ready for it.
    @ObservationIgnored var pendingInviteToken: String?
    /// An invite the person is looking at, waiting for them to join or decline.
    var presentedInvite: InviteOffer?

    // Scheduling state. Internal (not private(set)) because the extensions in
    // AppModel+Packages / +Booking / +Calendar update it from their own files.
    var packages: [ServicePackage] = []
    var availability: AvailabilitySettings?
    var bookings: [Booking] = []
    var contractTemplates: [ContractTemplate] = []
    var creatorSignature: CreatorSignature?
    /// Signed contracts already fetched, by booking, so screens don't wait on the network twice.
    var contractsByBooking: [UUID: Contract] = [:]
    /// The review on a booking, by booking, for the two people on it.
    var reviewsByBooking: [UUID: Review] = [:]
    /// A creator's public reviews (newest first) and how they add up, by creator.
    var reviewsByCreator: [UUID: [Review]] = [:]
    var reviewSummaryByCreator: [UUID: ReviewSummary] = [:]
    /// Deposits, balances and refunds on this person's bookings, as the backend recorded them.
    var payments: [Payment] = []
    /// A creator's Stripe account, if they have one. Only meaningful for creators.
    var paymentAccount: PaymentAccount?
    var isPaying = false
    /// The person's own cards (kept by Stripe; the app only shows what identifies them), and the creators they have allowed
    /// to charge one for the balance of a booking.
    var cards: [SavedCard] = []
    var cardPermissions: [CardPermission] = []
    /// What each booking on screen says about a saved-card permission, for the person looking at it.
    var cardAccessByBooking: [UUID: CardAccess] = [:]
    /// Slate Files: what each booking's files look like to this person, the limits, what is being sent, and what is being saved.
    var bookingFiles: [UUID: BookingFiles] = [:]
    var filesConfig: FilesConfig = .standard
    var fileUploads: [UUID: [FileUploadItem]] = [:]
    var fileSaveRuns: [UUID: FileSaveRun] = [:]
    /// "4.2 of 25 GB used" for the account on screen. Nil until asked, and for a client.
    var storageMeter: StorageMeter?
    /// The files the person picked, kept so a failed one can be tried again. Nothing here is shown.
    @ObservationIgnored var pendingPicks: [UUID: (pick: PickedFile, booking: UUID)] = [:]
    /// The space reserved for each picked file that got that far, so a file that fails can give it back.
    @ObservationIgnored var reservedFileIDs: [UUID: UUID] = [:]
    @ObservationIgnored var fileRunsCancelled: Set<UUID> = []
    /// Small pictures of delivered files, kept so scrolling a grid doesn't fetch them again.
    @ObservationIgnored let fileImages = FileImageCache()
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
    /// A booking link opened before the person was signed in. Welcome says so, and the page opens after sign-in.
    var pendingBookingHandle: String?
    /// Where a client is looking for creators (a city). Saved on this device, per person, and nowhere else.
    var clientPlace: ClientPlace?
    let calendar = CalendarService()

    init(
        backend: any SlateBackend,
        authorizer: (any PaymentAuthorizer)? = nil,
        notifications: (any NotificationCenterClient)? = nil,
        widget: (any WidgetPublisher)? = nil,
        filePreparer: (any FilePreparing)? = nil,
        fileTransfer: (any FileTransferring)? = nil
    ) {
        self.backend = backend
        self.filePreparer = filePreparer ?? PreviewMaker()
        self.fileTransfer = fileTransfer ?? FileTransfer()
        self.authorizer = authorizer ?? PaymentAuthorizerFactory.make(for: backend)
        self.notifications = notifications ?? InertNotificationCenter()
        self.widget = widget ?? InertWidgetPublisher()
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

    // MARK: - Email code and client accounts

    /// Emails a sign-in code. On a device with no server nothing is sent: the screen shows the demo code.
    func requestEmailCode(_ email: String) async throws {
        try await backend.requestEmailCode(email)
    }

    /// Signs in with the emailed code. Throws, so the screen can show what was wrong beside the field.
    func signInWithEmailCode(email: String, code: String) async throws {
        let newSession = try await backend.signInWithEmailCode(email: email, code: code)
        UserDefaults.standard.removeObject(forKey: AppConfig.appleUserIDKey)
        session = newSession
        await loadAccount()
    }

    /// Debug-only: a client with no profile, signed in with the demo code, so the client side can be tried alone.
    func signInAsDemoClient() async {
        do {
            try await signInWithEmailCode(email: "sam@example.com", code: EmailCodeRules.demoCode)
            if session?.fullName?.isEmpty ?? true { try await becomeClient(name: "Sam Client") } else { try await becomeClient(name: nil) }
        } catch {
            show(error, title: "Couldn't sign in")
        }
    }

    /// The person is here to book. Saves the name that goes on their contracts if they gave one, and opens the app.
    func becomeClient(name: String?) async throws {
        guard let current = session else { throw SlateError.notSignedIn }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            session = try await backend.updateDisplayName(name)
        } else if (current.fullName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw SlateError.nameRequired
        }
        UserDefaults.standard.set(true, forKey: AppConfig.clientAccountKey(for: current.userID))
        updatePhase()
    }

    /// Someone who has no creator profile and works for no company. They book; they don't sell.
    var isClientOnly: Bool {
        session != nil && personalProfile?.isComplete != true && accounts.companies.isEmpty
    }

    /// Whether this person has said they are a client, or has booked as one.
    private var isClientAccount: Bool {
        guard let id = session?.userID else { return false }
        return UserDefaults.standard.bool(forKey: AppConfig.clientAccountKey(for: id))
            || bookings.contains { $0.clientID == id }
    }

    /// A booking link opened by someone with no account makes a client (no type to choose), once their name is known.
    private func adoptAsClientIfTheyArrivedByLink() {
        guard let session, pendingBookingHandle != nil, personalProfile?.isComplete != true, accounts.companies.isEmpty,
              !(session.fullName ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return }
        UserDefaults.standard.set(true, forKey: AppConfig.clientAccountKey(for: session.userID))
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
        let deleted = session?.userID
        do {
            try await backend.deleteAccount()
        } catch {
            show(error, title: "Couldn't delete your account")
            return
        }
        if let deleted {
            UserDefaults.standard.removeObject(forKey: AppConfig.clientAccountKey(for: deleted))
            UserDefaults.standard.removeObject(forKey: AppConfig.clientPlaceKey(for: deleted))
        }
        await clearAccount()
    }

    private func clearAccount() async {
        UserDefaults.standard.removeObject(forKey: AppConfig.appleUserIDKey)
        session = nil
        profile = nil
        personalProfile = nil
        accounts = .empty
        activeAccount = .personal
        organization = nil
        teamMembers = []
        teamInvites = []
        assignmentQueue = []
        packageMembers = [:]
        presentedInvite = nil
        pendingInviteToken = nil
        portfolio = []
        packages = []
        availability = nil
        bookings = []
        contractTemplates = []
        creatorSignature = nil
        contractsByBooking = [:]
        widget.publish(.signedOut)
        reviewsByBooking = [:]
        reviewsByCreator = [:]
        reviewSummaryByCreator = [:]
        payments = []
        paymentAccount = nil
        cards = []
        cardPermissions = []
        cardAccessByBooking = [:]
        bookingFiles = [:]
        fileUploads = [:]
        fileSaveRuns = [:]
        storageMeter = nil
        pendingPicks = [:]
        reservedFileIDs = [:]
        fileImages.removeAll()
        presentedPage = nil
        pendingBookingHandle = nil
        clientPlace = nil
        await resetNotifications()
        CalendarPreferences.clear()
        calendarPrefs = CalendarPreferences()
        phase = .signedOut
    }

    // MARK: - Account data

    private func loadAccount() async {
        guard let session else { return }
        do {
            personalProfile = try await backend.loadProfile(for: session.userID)
            // Companies are an extra: a failure to list them must not stop the person's own account from opening.
            accounts = (try? await backend.loadAccounts(for: session.userID))
                ?? AccountList(hasPersonalProfile: personalProfile != nil, companies: [])
            teamConfig = (try? await backend.loadTeamConfig()) ?? .standard
            activeAccount = restoredActiveAccount(for: session.userID)
            clientPlace = savedClientPlace(for: session.userID)
            try await loadOwnerData()
            loadErrorMessage = nil
            updatePhase()
            afterAccountLoaded()
        } catch {
            loadErrorMessage = error.localizedDescription
            phase = .loadFailed
        }
    }

    /// The account the person had open last time, if they still belong to it.
    private func restoredActiveAccount(for userID: UUID) -> ActiveAccount {
        let wanted = ActiveAccount(storageValue: UserDefaults.standard.string(forKey: AppConfig.activeAccountKey(for: userID)))
        if case .company(let id) = wanted, accounts.companies.contains(where: { $0.organizationID == id }) { return wanted }
        // Someone who only works for a company opens on it.
        if personalProfile?.isComplete != true, let first = accounts.companies.first { return .company(first.organizationID) }
        return .personal
    }

    /// Loads the active account's profile, portfolio, services, hours, contracts and (for a company) its team.
    /// Bookings, payments and conversations belong to the person and are loaded as theirs: the backend returns what
    /// their role lets them see.
    func loadOwnerData() async throws {
        guard let session else { return }
        switch activeAccount {
        case .personal:
            profile = personalProfile
            organization = nil
        case .company(let id):
            do {
                organization = try await backend.loadOrganization(id, for: session.userID)
            } catch SlateError.notFound {
                // Removed from the company, or it was closed: go back to being yourself.
                activeAccount = .personal
                UserDefaults.standard.set(ActiveAccount.personal.storageValue, forKey: AppConfig.activeAccountKey(for: session.userID))
                accounts = (try? await backend.loadAccounts(for: session.userID)) ?? accounts
                try await loadOwnerData()
                return
            }
            profile = try await backend.loadProfile(for: id)
        }
        let owner = ownerID ?? session.userID
        portfolio = try await backend.loadPortfolio(for: owner)
        try await loadScheduling(owner: owner, user: session.userID)
        if activeAccount.companyID != nil { await loadTeam() }
    }

    func retryLoad() async {
        phase = .launching
        await loadAccount()
    }

    func refresh() async {
        guard let session else { return }
        do {
            personalProfile = try await backend.loadProfile(for: session.userID)
            if let latest = try? await backend.loadAccounts(for: session.userID) { accounts = latest }
            try await loadOwnerData()
            Task { await syncCalendar() }
            Task { await settlePendingRefunds() }
            Task { await loadReviews(for: session.userID) }
            bookingsChanged()
        } catch {
            show(error, title: "Couldn't refresh")
        }
    }

    func updatePhase() {
        adoptAsClientIfTheyArrivedByLink()
        if session == nil {
            phase = .signedOut
        } else if personalProfile?.isComplete == true || !accounts.companies.isEmpty || isClientAccount {
            phase = .ready
            Task { await openPendingBookingLinkIfNeeded() }
            Task { await openPendingInviteIfNeeded() }
        } else {
            phase = .onboarding
            // An invite opened before the account existed is the first thing to show, in place of choosing a type.
            Task { await openPendingInviteIfNeeded() }
        }
    }

    /// Whether a link name is free. For the account on screen its own name counts as free; for one being started
    /// (`forNewAccount`) nothing does.
    func isHandleAvailable(_ handle: String, forNewAccount: Bool = false) async throws -> Bool {
        guard let session else { throw SlateError.notSignedIn }
        return try await backend.isHandleAvailable(handle, excluding: forNewAccount ? UUID() : (ownerID ?? session.userID))
    }

    // MARK: - Profile

    /// Saves the profile, then uploads any portfolio picks. A portfolio failure doesn't undo the
    /// profile: the person lands in the app and can retry from their profile.
    func completeOnboarding(draft: ProfileDraft, portfolio newItems: [NewPortfolioItem]) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let toSave = draft.makeProfile(id: session.userID, existing: personalProfile)
        let saved = try await backend.saveProfile(toSave, avatarJPEG: draft.avatarJPEG)
        personalProfile = saved
        if activeAccount == .personal { profile = saved }

        if !newItems.isEmpty {
            do {
                portfolio = try await backend.addPortfolioItems(newItems, for: session.userID)
            } catch {
                show(error, title: "Some portfolio items didn't upload")
            }
        }
        updatePhase()
    }

    /// Saves the profile on screen: the person's own, or the company's when one is showing.
    func updateProfile(from draft: ProfileDraft) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let toSave = draft.makeProfile(id: ownerID ?? session.userID, existing: profile)
        let saved = try await backend.saveProfile(toSave, avatarJPEG: draft.avatarJPEG)
        profile = saved
        if activeAccount == .personal { personalProfile = saved }
        if activeAccount.companyID != nil { organization = try? await backend.loadOrganization(saved.id, for: session.userID) }
    }

    // MARK: - Portfolio

    func addPortfolio(_ items: [NewPortfolioItem]) async {
        guard let owner = ownerID, !items.isEmpty else { return }
        do {
            portfolio = try await backend.addPortfolioItems(items, for: owner)
        } catch {
            show(error, title: "Couldn't add to your portfolio")
        }
    }

    func deletePortfolioItem(_ item: PortfolioItem) async {
        guard let owner = ownerID else { return }
        do {
            portfolio = try await backend.deletePortfolioItem(item.id, for: owner)
        } catch {
            show(error, title: "Couldn't delete")
        }
    }

    func movePortfolioItemToFront(_ item: PortfolioItem) async {
        guard let owner = ownerID else { return }
        do {
            portfolio = try await backend.movePortfolioItemToFront(item.id, for: owner)
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

import Foundation

/// Everything the app needs from a server. Two implementations ship:
/// `LocalBackend` (on-device, default) and `SupabaseBackend` (real accounts and storage).
protocol SlateBackend {
    // Auth
    func restoreSession() async -> AuthSession?
    func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession
    /// Emails a six-digit sign-in code. Throws `invalidEmail`, `rateLimited`.
    func requestEmailCode(_ email: String) async throws
    /// Signs in with the code, creating a free account for an address that has none. Throws `invalidEmail`, `invalidCode`.
    func signInWithEmailCode(email: String, code: String) async throws -> AuthSession
    /// Saves the name a person goes by on the contracts they sign. Throws `nameRequired`.
    func updateDisplayName(_ name: String) async throws -> AuthSession
    func signOut() async throws
    func deleteAccount() async throws

    // Profile
    func loadProfile(for userID: UUID) async throws -> CreatorProfile?
    func isHandleAvailable(_ handle: String, excluding userID: UUID) async throws -> Bool
    /// Creates or updates the profile. Pass `avatarJPEG` only when the photo changed.
    func saveProfile(_ profile: CreatorProfile, avatarJPEG: Data?) async throws -> CreatorProfile

    // Portfolio
    func loadPortfolio(for userID: UUID) async throws -> [PortfolioItem]
    func addPortfolioItems(_ items: [NewPortfolioItem], for userID: UUID) async throws -> [PortfolioItem]
    func deletePortfolioItem(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem]
    func movePortfolioItemToFront(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem]

    // Packages (the creator's own list, including hidden ones)
    func loadPackages(for creatorID: UUID) async throws -> [ServicePackage]
    func savePackage(_ package: ServicePackage) async throws -> [ServicePackage]
    func deletePackage(_ id: UUID, for creatorID: UUID) async throws -> [ServicePackage]

    // Availability
    func loadAvailability(for creatorID: UUID) async throws -> AvailabilitySettings?
    func saveAvailability(_ settings: AvailabilitySettings, for creatorID: UUID) async throws -> AvailabilitySettings
    /// Replaces all imported calendar busy time. Only start and end times are ever sent.
    func replaceBusyBlocks(_ blocks: [DateInterval], for creatorID: UUID) async throws

    // Clients
    func loadPublicPage(handle: String) async throws -> PublicCreatorPage?
    /// Settings plus blocked time ranges (never other people's booking details).
    func loadSchedule(for creatorID: UUID, from: Date, to: Date) async throws -> CreatorSchedule

    // Bookings
    /// Books and signs in one step: re-checks availability, re-renders the contract itself, checks it matches
    /// what the client signed (`contractChanged` if not), and applies the creator's signature on file.
    /// Throws `slotTaken` / `slotUnavailable`. Trusts nothing in `request` but ids and time.
    func createBooking(_ request: BookingRequest, clientID: UUID, clientName: String, signature: SignatureInput) async throws -> SignedBooking
    func loadBookings(for userID: UUID) async throws -> [Booking]
    /// Cancels, works out the refund from the cancellation policy the client agreed to, and records it.
    /// Call `settleRefunds` afterwards to actually send the money back.
    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> CancellationResult
    /// Gives up holds whose deposit wasn't paid in time, freeing their times.
    func expireHolds() async throws

    // Delivery and reviews
    /// The creator shares a link to the final files (and an optional note). Sharing again replaces them until the
    /// client confirms. Throws `invalidDeliveryLink`, `deliveryNoteTooLong`, `notDeliverable`.
    func shareDelivery(bookingID: UUID, link: String, note: String, by creatorID: UUID) async throws -> Booking
    /// The client says they have the files. This is what makes the balance payable, and it completes a booking with
    /// nothing left to pay. Confirming twice changes nothing. Throws `notDelivered`.
    func confirmReceipt(bookingID: UUID, by clientID: UUID) async throws -> Booking
    /// Leaves the one review a booking can have. Throws `notReviewable`, `invalidRating`, `reviewTooLong`, `alreadyReviewed`.
    func submitReview(bookingID: UUID, rating: Int, body: String, by clientID: UUID) async throws -> Review
    /// The review on a booking, for the two people on it.
    func loadReview(bookingID: UUID, for userID: UUID) async throws -> Review?
    /// A creator's reviews, newest first. With `before`, only those older than that moment.
    func loadReviews(creatorID: UUID, limit: Int, before: Date?) async throws -> [Review]
    func loadReviewSummary(creatorID: UUID) async throws -> ReviewSummary

    // Contracts
    func loadContractTemplates(for creatorID: UUID) async throws -> [ContractTemplate]
    func saveContractTemplate(_ template: ContractTemplate) async throws -> [ContractTemplate]
    func deleteContractTemplate(_ id: UUID, for creatorID: UUID) async throws -> [ContractTemplate]
    func loadCreatorSignature(for creatorID: UUID) async throws -> CreatorSignature?
    func saveCreatorSignature(_ signature: CreatorSignature, for creatorID: UUID) async throws
    /// The contract exactly as it will be signed: filled in by the backend, never by the client.
    func previewContract(_ request: BookingRequest, clientName: String) async throws -> ContractPreview
    func loadContract(bookingID: UUID, for userID: UUID) async throws -> Contract?
    func loadContractPDF(contractID: UUID) async throws -> Data?
    /// Stores the signed PDF for both parties. The first PDF stored wins; later ones are ignored.
    func attachContractPDF(_ data: Data, contractID: UUID) async throws

    // Payments
    /// True on-device: payments are pretend and no money moves. The app says so wherever it matters.
    var paymentsAreSimulated: Bool { get }
    /// Every payment and refund on the bookings this person is part of.
    func loadPayments(for userID: UUID) async throws -> [Payment]
    func loadPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount
    /// Asks Stripe where the creator's account stands and returns where to go to finish, when there is more to do.
    func beginPaymentAccountSetup(for creatorID: UUID) async throws -> PaymentAccountSetup
    func refreshPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount
    /// Opens the payment for a booking's deposit or balance. The amount comes from the booking, never from the caller.
    func preparePayment(bookingID: UUID, kind: PaymentKind, by userID: UUID) async throws -> PaymentIntentInfo
    /// On-device only: completes a payment the way Stripe's webhook would. Throws everywhere else.
    func completeSimulatedPayment(_ paymentID: UUID) async throws
    /// What cancelling now would refund, shown before the person confirms.
    func refundQuote(bookingID: UUID, for userID: UUID) async throws -> RefundQuote
    /// Sends any refunds owed on a booking to the card that paid.
    func settleRefunds(bookingID: UUID) async throws

    // Messages (one conversation per booking)
    /// Every conversation the person is part of, newest first, with unread counts. Bookings whose hold ran out have none.
    func loadConversations(for userID: UUID) async throws -> [ConversationSummary]
    /// A conversation in time order. With `since`, only what came after (the app asks for a little before the last
    /// line it has, and ignores repeats, so a line that committed late is never missed).
    func loadMessages(bookingID: UUID, since: Date?, for userID: UUID) async throws -> [Message]
    /// Sends text. The backend tidies it (`MessageRules.clean`) and returns the stored message; sending the same
    /// `clientMessageID` again returns the first one instead of posting a copy.
    func sendMessage(_ body: String, bookingID: UUID, clientMessageID: UUID, from userID: UUID) async throws -> Message
    /// Marks everything in the conversation as read.
    func markConversationRead(bookingID: UUID, for userID: UUID) async throws

    // Notifications
    /// True when a server queues and sends push notifications, shoot reminders included. Then the app registers its
    /// device and must not schedule its own reminders as well. False on-device, where the app schedules them itself.
    var sendsPushFromServer: Bool { get }
    func loadNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences
    func saveNotificationPreferences(_ preferences: NotificationPreferences, for userID: UUID) async throws -> NotificationPreferences
    /// Remembers this device so the server can push to it. `token` is the lowercase hex APNs gave the app.
    func registerDevice(token: String, environment: PushEnvironment, for userID: UUID) async throws
    func unregisterDevice(token: String) async throws

    /// Whether a creator may book their own packages. True on-device so the flow can be tested alone.
    var allowsSelfBooking: Bool { get }

    // MARK: Companies
    //
    // A company is an owner like a person: its id is its profile id, and packages, contract templates, hours, bookings
    // and the payment account are all found by that id. These methods are about the company itself and its people.
    // Every one is checked against the caller's role (`OrgPermission`); the database does the checking, the app only
    // hides what a role can't use.

    /// The numbers behind seats and invites. They live in the database so they can change without a release.
    func loadTeamConfig() async throws -> TeamConfig
    /// Every account this person can act as: their own, and each company they belong to.
    func loadAccounts(for userID: UUID) async throws -> AccountList
    /// Starts a company from nothing. The person becomes its Owner and gets a minimal profile of their own if they had none.
    func createOrganization(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization
    /// Turns an individual account into a company: services and contract templates move to it, bookings and signed
    /// contracts stay where they are. Throws `profileRequired`, `bookingsInHold`.
    func upgradeToCompany(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization
    /// The other way, for an Owner who is alone with nothing coming up. Throws `teamNotEmpty`, `hasUpcomingBookings`.
    func downgradeToIndividual(organizationID: UUID, by userID: UUID) async throws
    func loadOrganization(_ id: UUID, for userID: UUID) async throws -> Organization
    func updateOrganization(_ id: UUID, with update: OrganizationUpdate, by userID: UUID) async throws -> Organization
    func setSplitEnabled(_ enabled: Bool, organizationID: UUID, by userID: UUID) async throws -> Organization
    /// Names who countersigns company contracts. Throws `signerRoleNotAllowed`, `signatureRequired`.
    func designateSigner(userID: UUID, title: String, organizationID: UUID, by actorID: UUID) async throws -> Organization
    func transferOwnership(organizationID: UUID, to userID: UUID, by actorID: UUID) async throws
    /// Closes a company for good (its signed contracts are kept). Throws `hasUpcomingBookings`.
    func closeOrganization(_ id: UUID, by userID: UUID) async throws

    // Members
    func loadMembers(organizationID: UUID, for userID: UUID) async throws -> [TeamMember]
    func setMemberRole(_ role: OrgRole, memberID: UUID, organizationID: UUID, by userID: UUID) async throws
    func updateMember(_ update: MemberUpdate, memberID: UUID, organizationID: UUID, by userID: UUID) async throws
    /// Sets a member's share of the bookings assigned to them, in basis points. Owner only.
    func setMemberShare(bps: Int, memberID: UUID, organizationID: UUID, by userID: UUID) async throws
    /// Takes someone off the team. Their upcoming bookings go back to the queue. Throws `lastOwner`.
    func removeMember(memberID: UUID, organizationID: UUID, by userID: UUID) async throws
    func leaveOrganization(_ id: UUID, by userID: UUID) async throws
    /// A member's own working hours at this company. Nil means the company's. They can only narrow the company's.
    func saveMyHours(_ hours: [DayHours]?, organizationID: UUID, by userID: UUID) async throws

    // Invites
    func loadInvites(organizationID: UUID, for userID: UUID) async throws -> [OrgInvite]
    /// A single-use invite. The link is returned once and never stored. Throws `seatLimit`, `planInactive`, `invalidRole`.
    func createInvite(role: OrgRole, email: String?, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite
    func revokeInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws
    /// A lost link is replaced, not recovered: the old invite is cancelled and a new one made.
    func resendInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite
    /// What a person sees before joining. One error (`inviteInvalid`) for every bad token, so tokens can't be probed.
    func previewInvite(token: String, for userID: UUID) async throws -> InvitePreview
    /// Joins the company under the invite's role. Throws `inviteInvalid`, `alreadyMember`.
    func acceptInvite(token: String, displayName: String?, by userID: UUID) async throws -> Organization
    /// On-device only: a teammate accepting an invite, so teams can be tried without a second phone. Returns the
    /// teammate's id. Throws everywhere else.
    func completeSimulatedJoin(inviteID: UUID, displayName: String) async throws -> UUID

    // Activity and billing
    func loadActivity(organizationID: UUID, limit: Int, before: Date?, for userID: UUID) async throws -> [ActivityEntry]
    func loadBilling(organizationID: UUID, for userID: UUID) async throws -> BillingOverview
    /// What adding (`delta` > 0) or removing people does to the bill, for the sheet that asks first.
    func previewSeatChange(delta: Int, organizationID: UUID, for userID: UUID) async throws -> SeatPlan
    /// A Stripe-hosted page to start the plan or manage it. Open it in a web authentication session.
    func beginBilling(_ action: BillingAction, organizationID: UUID, by userID: UUID) async throws -> URL

    // Assigning bookings
    /// Bookings waiting for someone, soonest first.
    func loadAssignmentQueue(organizationID: UUID, for userID: UUID) async throws -> [Booking]
    func loadAssignmentOptions(bookingID: UUID, for userID: UUID) async throws -> [AssignmentOption]
    /// Gives a booking to a person (or moves it). Throws `invalidAssignee`, `slotTaken`, `notAssignable`.
    func assignBooking(_ bookingID: UUID, to memberID: UUID, by userID: UUID) async throws -> Booking

    // Calendar and shared services
    /// Everyone's hours, busy time and bookings. Only these people, if `members` isn't empty.
    func loadTeamCalendar(organizationID: UUID, from: Date, to: Date, members: Set<UUID>, for userID: UUID) async throws -> TeamCalendar
    /// For a client choosing a time: the company's rules and each eligible person's hours and busy time. With `memberID`,
    /// only that person.
    func loadTeamSchedule(packageID: UUID, memberID: UUID?, from: Date, to: Date) async throws -> TeamSchedule
    /// The people who offer a package. Empty means everyone who can take bookings.
    func loadPackageMembers(packageID: UUID) async throws -> [UUID]
    func setPackageMembers(_ memberIDs: [UUID], packageID: UUID, by userID: UUID) async throws
}

enum BackendFactory {
    static func make() -> any SlateBackend {
        if let config = AppConfig.supabase {
            return SupabaseBackend(url: config.url, anonKey: config.anonKey)
        }
        return LocalBackend()
    }
}

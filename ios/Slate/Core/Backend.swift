import Foundation

/// Everything the app needs from a server. Two implementations ship:
/// `LocalBackend` (on-device, default) and `SupabaseBackend` (real accounts and storage).
protocol SlateBackend {
    // Auth
    func restoreSession() async -> AuthSession?
    func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession
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
}

enum BackendFactory {
    static func make() -> any SlateBackend {
        if let config = AppConfig.supabase {
            return SupabaseBackend(url: config.url, anonKey: config.anonKey)
        }
        return LocalBackend()
    }
}

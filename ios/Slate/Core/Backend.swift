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
    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> Booking

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

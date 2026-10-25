import Foundation

/// On-device backend. Stores accounts, profiles and media under Application Support so the
/// whole app works with no server. It is also what the unit tests and CI run against.
///
/// Files are referenced by relative name and resolved at load time, because an app's
/// container path can change between launches or updates.
actor LocalBackend: SlateBackend {
    let root: URL
    let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// What "now" is. Tests move it forward to see holds run out.
    let clock: @Sendable () -> Date
    /// Whether to behave as if a server sends push notifications (so the app registers its device and leaves
    /// shoot reminders to the server). Always false in the app; tests turn it on to exercise those paths.
    let sendsPushFromServer: Bool
    /// Seat numbers. The database holds the real ones; tests pass small ones.
    let teamConfig: TeamConfig

    /// Handles that pretend to belong to other people, so the "taken" state is easy to see.
    private let simulatedTakenHandles: Set<String> = ["maya", "demo", "studio", "photo", "video"]

    init(
        root: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }, sendsPushFromServer: Bool = false,
        teamConfig: TeamConfig = .standard
    ) {
        self.clock = clock
        self.sendsPushFromServer = sendsPushFromServer
        self.teamConfig = teamConfig
        let base: URL
        if let root {
            base = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = support.appendingPathComponent("SlateLocal", isDirectory: true)
        }
        self.root = base

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    nonisolated var now: Date { clock() }

    // MARK: - Stored shapes

    struct StoredProfile: Codable {
        var id: UUID
        var handle: String
        var displayName: String
        var bio: String
        var specialties: [Specialty]
        var location: CreatorLocation?
        var avatarFile: String?
        var createdAt: Date
        var updatedAt: Date
        /// Nil in profiles saved before companies existed: a person.
        var kind: ProfileKind? = nil
    }

    private struct StoredItem: Codable {
        var id: UUID
        var kind: PortfolioItem.Kind
        var position: Int
        var caption: String
        var imageFile: String
        var thumbnailFile: String
        var videoFile: String?
        var duration: TimeInterval?
        var aspectRatio: Double
        var createdAt: Date
    }

    // MARK: - Paths

    var sessionURL: URL { root.appendingPathComponent("session.json") }
    var accountsURL: URL { root.appendingPathComponent("accounts.json") }

    func userDirectory(_ userID: UUID) -> URL {
        root.appendingPathComponent(userID.uuidString.lowercased(), isDirectory: true)
    }

    func profileURL(_ userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent("profile.json")
    }

    private func portfolioURL(_ userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent("portfolio.json")
    }

    private func mediaDirectory(_ userID: UUID) -> URL {
        userDirectory(userID).appendingPathComponent("media", isDirectory: true)
    }

    // MARK: - Auth

    func restoreSession() async -> AuthSession? {
        read(AuthSession.self, from: sessionURL)
    }

    func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession {
        var accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        let userID = accounts[credential.userID] ?? UUID()
        accounts[credential.userID] = userID
        try write(accounts, to: accountsURL)

        let name = credential.fullName.map { $0.formatted() }.flatMap { $0.isEmpty ? nil : $0 }
        let previous = read(AuthSession.self, from: sessionURL)
        let stored = storedClient(userID)
        let session = AuthSession(
            userID: userID,
            appleUserID: credential.userID,
            email: credential.email ?? previous?.email ?? stored?.email,
            // Apple only gives the name the first time, so keep the one we have.
            fullName: name ?? previous?.fullName ?? stored?.name
        )
        try write(session, to: sessionURL)
        if let known = session.fullName { try rememberClient(userID, name: known, email: session.email) }
        return session
    }

    func signOut() async throws {
        try? fileManager.removeItem(at: sessionURL)
    }

    func deleteAccount() async throws {
        guard let session = read(AuthSession.self, from: sessionURL) else { throw SlateError.notSignedIn }
        // Like the server: an Owner hands the company over or closes it first.
        if readOrganizations().contains(where: { $0.state != .closed && activeMember($0, session.userID)?.role == .owner }) {
            throw SlateError.lastOwner
        }
        try endAllMemberships(of: session.userID)
        try? fileManager.removeItem(at: userDirectory(session.userID))
        var accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        accounts = accounts.filter { $0.value != session.userID }
        try write(accounts, to: accountsURL)
        try? fileManager.removeItem(at: sessionURL)
    }

    // MARK: - Profile

    func loadProfile(for userID: UUID) async throws -> CreatorProfile? {
        guard let stored = read(StoredProfile.self, from: profileURL(userID)) else { return nil }
        return makeProfile(stored, userID: userID)
    }

    func isHandleAvailable(_ handle: String, excluding userID: UUID) async throws -> Bool {
        try await Task.sleep(for: .milliseconds(120)) // Feel like a network call.
        return !isHandleTaken(handle, excluding: userID)
    }

    func saveProfile(_ profile: CreatorProfile, avatarJPEG: Data?) async throws -> CreatorProfile {
        let userID = profile.id
        try authorizeOwner(userID, .companyEdit)
        guard !isHandleTaken(profile.handle, excluding: userID) else { throw SlateError.handleTaken }

        try fileManager.createDirectory(at: userDirectory(userID), withIntermediateDirectories: true)
        let existing = read(StoredProfile.self, from: profileURL(userID))

        var avatarFile = existing?.avatarFile
        if let avatarJPEG {
            // A new file name each time, so image caches never serve the previous photo.
            let newName = "avatar-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try avatarJPEG.write(to: userDirectory(userID).appendingPathComponent(newName), options: .atomic)
            if let old = avatarFile {
                try? fileManager.removeItem(at: userDirectory(userID).appendingPathComponent(old))
            }
            avatarFile = newName
        }

        let stored = StoredProfile(
            id: userID,
            handle: profile.handle,
            displayName: profile.displayName,
            bio: profile.bio,
            specialties: profile.specialties,
            location: profile.location,
            avatarFile: avatarFile,
            createdAt: existing?.createdAt ?? profile.createdAt,
            updatedAt: Date(),
            kind: existing?.kind ?? (profile.kind == .company ? .company : nil)
        )
        try write(stored, to: profileURL(userID))
        return makeProfile(stored, userID: userID)
    }

    // MARK: - Portfolio

    func loadPortfolio(for userID: UUID) async throws -> [PortfolioItem] {
        makeItems(readItems(userID), userID: userID)
    }

    func addPortfolioItems(_ items: [NewPortfolioItem], for userID: UUID) async throws -> [PortfolioItem] {
        try authorizeOwner(userID, .companyEdit)
        var stored = readItems(userID)
        guard stored.count + items.count <= AppConfig.portfolioLimit else {
            throw SlateError.portfolioFull(limit: AppConfig.portfolioLimit)
        }

        let directory = mediaDirectory(userID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for item in items {
            let stem = item.id.uuidString.lowercased()
            let imageFile = "\(stem).jpg"
            let thumbnailFile = "\(stem)-thumb.jpg"
            try item.imageJPEG.write(to: directory.appendingPathComponent(imageFile), options: .atomic)
            try item.thumbnailJPEG.write(to: directory.appendingPathComponent(thumbnailFile), options: .atomic)

            var videoFile: String?
            if let source = item.videoFile {
                let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
                let name = "\(stem).\(ext)"
                let destination = directory.appendingPathComponent(name)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.removeItem(at: source) // The picker's temp copy is no longer needed.
                videoFile = name
            }

            stored.append(StoredItem(
                id: item.id,
                kind: item.kind,
                position: stored.count,
                caption: item.caption,
                imageFile: imageFile,
                thumbnailFile: thumbnailFile,
                videoFile: videoFile,
                duration: item.duration,
                aspectRatio: item.aspectRatio,
                createdAt: Date()
            ))
        }

        try write(stored, to: portfolioURL(userID))
        return makeItems(stored, userID: userID)
    }

    func deletePortfolioItem(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem] {
        try authorizeOwner(userID, .companyEdit)
        var stored = readItems(userID)
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            return makeItems(stored, userID: userID)
        }
        let removed = stored.remove(at: index)
        let directory = mediaDirectory(userID)
        for file in [removed.imageFile, removed.thumbnailFile, removed.videoFile].compactMap({ $0 }) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
        stored = repacked(stored)
        try write(stored, to: portfolioURL(userID))
        return makeItems(stored, userID: userID)
    }

    func movePortfolioItemToFront(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem] {
        try authorizeOwner(userID, .companyEdit)
        var stored = readItems(userID)
        if let index = stored.firstIndex(where: { $0.id == id }), index != 0 {
            let item = stored.remove(at: index)
            stored.insert(item, at: 0)
            stored = repacked(stored)
            try write(stored, to: portfolioURL(userID))
        }
        return makeItems(stored, userID: userID)
    }

    // MARK: - Helpers

    func isHandleTaken(_ handle: String, excluding userID: UUID) -> Bool {
        if simulatedTakenHandles.contains(handle) { return true }
        let accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        let companies = readOrganizations().map(\.id)
        for other in Set(accounts.values).union(companies) where other != userID {
            if read(StoredProfile.self, from: profileURL(other))?.handle == handle { return true }
        }
        return false
    }

    func makeProfile(_ stored: StoredProfile, userID: UUID) -> CreatorProfile {
        CreatorProfile(
            id: stored.id,
            handle: stored.handle,
            displayName: stored.displayName,
            bio: stored.bio,
            specialties: stored.specialties,
            location: stored.location,
            avatarURL: stored.avatarFile.map { userDirectory(userID).appendingPathComponent($0) },
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            kind: stored.kind ?? .person
        )
    }

    private func readItems(_ userID: UUID) -> [StoredItem] {
        (read([StoredItem].self, from: portfolioURL(userID)) ?? []).sorted { $0.position < $1.position }
    }

    private func makeItems(_ stored: [StoredItem], userID: UUID) -> [PortfolioItem] {
        let directory = mediaDirectory(userID)
        return stored.sorted { $0.position < $1.position }.map { item in
            PortfolioItem(
                id: item.id,
                kind: item.kind,
                position: item.position,
                caption: item.caption,
                imageURL: directory.appendingPathComponent(item.imageFile),
                thumbnailURL: directory.appendingPathComponent(item.thumbnailFile),
                videoURL: item.videoFile.map { directory.appendingPathComponent($0) },
                duration: item.duration,
                aspectRatio: item.aspectRatio,
                createdAt: item.createdAt
            )
        }
    }

    private func repacked(_ items: [StoredItem]) -> [StoredItem] {
        items.enumerated().map { index, item in
            var copy = item
            copy.position = index
            return copy
        }
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

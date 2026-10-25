import Foundation
import Supabase

/// Real accounts, database and file storage on Supabase.
///
/// Schema, Row Level Security and storage buckets live in `supabase/migrations`.
/// Apple sign-in uses the native ID-token flow, so the Apple provider must be enabled in the
/// Supabase dashboard with this app's bundle ID as an authorized client ID.
final class SupabaseBackend: SlateBackend, @unchecked Sendable {
    let client: SupabaseClient

    init(url: URL, anonKey: String) {
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    // MARK: - Rows

    struct ProfileRow: Codable {
        var id: String
        var handle: String
        var displayName: String
        var bio: String
        var specialties: [String]
        var locationName: String?
        var latitude: Double?
        var longitude: Double?
        var travelRadiusKm: Int?
        var avatarPath: String?
        var createdAt: Date?
        var updatedAt: Date?
        /// `person` or `company`. Never sent: the database fixes it when the profile is made and never changes it.
        var kind: String?

        enum CodingKeys: String, CodingKey {
            case id, handle, bio, specialties, latitude, longitude, kind
            case displayName = "display_name"
            case locationName = "location_name"
            case travelRadiusKm = "travel_radius_km"
            case avatarPath = "avatar_path"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    private struct PortfolioRow: Codable {
        var id: String
        var creatorId: String
        var kind: String
        var position: Int
        var caption: String
        var imagePath: String
        var thumbnailPath: String
        var videoPath: String?
        var durationSeconds: Double?
        var aspectRatio: Double
        var createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, kind, position, caption
            case creatorId = "creator_id"
            case imagePath = "image_path"
            case thumbnailPath = "thumbnail_path"
            case videoPath = "video_path"
            case durationSeconds = "duration_seconds"
            case aspectRatio = "aspect_ratio"
            case createdAt = "created_at"
        }
    }

    struct IDRow: Decodable {
        var id: String
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: - Auth

    func restoreSession() async -> AuthSession? {
        guard let session = try? await client.auth.session else { return nil }
        return AuthSession(
            userID: session.user.id,
            appleUserID: UserDefaults.standard.string(forKey: AppConfig.appleUserIDKey),
            email: session.user.email,
            // The name a person goes by is kept with their account, so it survives signing out and in.
            fullName: session.user.userMetadata["full_name"]?.stringValue
        )
    }

    func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession {
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(
                provider: .apple,
                idToken: credential.identityToken,
                nonce: credential.rawNonce
            )
        )
        let given = credential.fullName.map { $0.formatted() }.flatMap { $0.isEmpty ? nil : $0 }
        let kept = session.user.userMetadata["full_name"]?.stringValue
        // Apple only gives the name the first time, so keep it with the account.
        if let given, kept == nil, let clean = EmailCodeRules.cleanName(given) {
            _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(clean)]))
        }
        return AuthSession(
            userID: session.user.id,
            appleUserID: credential.userID,
            email: credential.email ?? session.user.email,
            fullName: kept ?? given
        )
    }

    private struct CreatorSearchParams: Encodable {
        var pQuery: String
        var pLimit: Int

        enum CodingKeys: String, CodingKey {
            case pQuery = "p_query"
            case pLimit = "p_limit"
        }
    }

    func searchCreators(_ query: String, limit: Int) async throws -> [CreatorProfile] {
        guard let words = CreatorSearchRules.clean(query) else { return [] }
        let rows: [ProfileRow] = try await client
            .rpc("search_creators", params: CreatorSearchParams(pQuery: words, pLimit: CreatorSearchRules.clamped(limit: limit)))
            .execute()
            .value
        return try rows.map(makeProfile)
    }

    private struct FeaturedParams: Encodable {
        var pSpecialty: String?
        var pLimit: Int
        var pLat: Double?
        var pLon: Double?

        enum CodingKeys: String, CodingKey {
            case pSpecialty = "p_specialty"
            case pLimit = "p_limit"
            case pLat = "p_lat"
            case pLon = "p_lon"
        }
    }

    /// One row of `featured_creators()`: the columns of a profile, then what a tile needs beside it.
    struct FeaturedRow: Decodable {
        var profile: ProfileRow
        var coverPath: String?
        var startingPriceCents: Int
        var currencyCode: String
        var reviewCount: Int
        var ratingSum: Int
        /// Kilometres from the place the client sent to the creator's city. Null with no place, or no city.
        var distanceKm: Double?

        enum CodingKeys: String, CodingKey {
            case coverPath = "cover_path"
            case startingPriceCents = "starting_price_cents"
            case currencyCode = "currency_code"
            case reviewCount = "review_count"
            case ratingSum = "rating_sum"
            case distanceKm = "distance_km"
        }

        init(from decoder: Decoder) throws {
            profile = try ProfileRow(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
            startingPriceCents = try container.decode(Int.self, forKey: .startingPriceCents)
            currencyCode = try container.decode(String.self, forKey: .currencyCode)
            reviewCount = try container.decode(Int.self, forKey: .reviewCount)
            ratingSum = try container.decode(Int.self, forKey: .ratingSum)
            distanceKm = try container.decodeIfPresent(Double.self, forKey: .distanceKm)
        }
    }

    func featuredCreators(specialty: Specialty?, near: GeoPoint?, limit: Int) async throws -> [FeaturedCreator] {
        // The place is rounded to about a kilometre before it leaves the phone, and the database doesn't keep it.
        let place = near.flatMap { $0.isValid ? $0.rounded() : nil }
        let params = FeaturedParams(
            pSpecialty: specialty?.rawValue, pLimit: FeaturedRules.clamped(limit: limit),
            pLat: place?.latitude, pLon: place?.longitude
        )
        let rows: [FeaturedRow] = try await client
            .rpc("featured_creators", params: params)
            .execute()
            .value
        return try rows.map(makeFeatured)
    }

    func makeFeatured(_ row: FeaturedRow) throws -> FeaturedCreator {
        FeaturedCreator(
            profile: try makeProfile(row.profile),
            coverURL: try row.coverPath.map { try publicURL(bucket: "portfolio", path: $0) },
            startingPriceCents: row.startingPriceCents,
            currencyCode: row.currencyCode,
            reviews: ReviewSummary(count: row.reviewCount, ratingSum: row.ratingSum),
            distanceKm: row.distanceKm
        )
    }

    func requestEmailCode(_ email: String) async throws {
        guard let address = EmailCodeRules.cleanEmail(email) else { throw SlateError.invalidEmail }
        try await client.auth.signInWithOTP(email: address, shouldCreateUser: true)
    }

    func signInWithEmailCode(email: String, code: String) async throws -> AuthSession {
        guard let address = EmailCodeRules.cleanEmail(email) else { throw SlateError.invalidEmail }
        guard let digits = EmailCodeRules.cleanCode(code) else { throw SlateError.invalidCode }
        do {
            let response = try await client.auth.verifyOTP(email: address, token: digits, type: .email)
            return AuthSession(
                userID: response.user.id,
                appleUserID: nil,
                email: response.user.email ?? address,
                fullName: response.user.userMetadata["full_name"]?.stringValue
            )
        } catch let error as AuthError {
            // A wrong, used or expired code all come back as an auth error; a lost connection doesn't.
            _ = error
            throw SlateError.invalidCode
        }
    }

    func updateDisplayName(_ name: String) async throws -> AuthSession {
        guard let clean = EmailCodeRules.cleanName(name) else { throw SlateError.nameRequired }
        let user = try await client.auth.update(user: UserAttributes(data: ["full_name": .string(clean)]))
        return AuthSession(
            userID: user.id,
            appleUserID: UserDefaults.standard.string(forKey: AppConfig.appleUserIDKey),
            email: user.email,
            fullName: clean
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    /// Deletion needs the service role, so it runs in the `delete-account` Edge Function.
    func deleteAccount() async throws {
        try await client.functions.invoke("delete-account")
        try? await client.auth.signOut()
    }

    // MARK: - Profile

    func loadProfile(for userID: UUID) async throws -> CreatorProfile? {
        let rows: [ProfileRow] = try await client
            .from("creator_profiles")
            .select()
            .eq("id", value: Self.key(userID))
            .limit(1)
            .execute()
            .value
        return try rows.first.map(makeProfile)
    }

    /// A creator's public profile, found by the name in their booking link.
    func loadProfile(handle: String) async throws -> CreatorProfile? {
        let rows: [ProfileRow] = try await client
            .from("creator_profiles")
            .select()
            .eq("handle", value: handle)
            .limit(1)
            .execute()
            .value
        return try rows.first.map(makeProfile)
    }

    func isHandleAvailable(_ handle: String, excluding userID: UUID) async throws -> Bool {
        let rows: [IDRow] = try await client
            .from("creator_profiles")
            .select("id")
            .eq("handle", value: handle)
            .neq("id", value: Self.key(userID))
            .limit(1)
            .execute()
            .value
        return rows.isEmpty
    }

    func saveProfile(_ profile: CreatorProfile, avatarJPEG: Data?) async throws -> CreatorProfile {
        let userKey = Self.key(profile.id)

        var avatarPath = try await currentAvatarPath(userKey)
        if let avatarJPEG {
            let newPath = "\(userKey)/avatar-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try await client.storage.from("avatars").upload(
                newPath,
                data: avatarJPEG,
                options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)
            )
            if let old = avatarPath {
                _ = try? await client.storage.from("avatars").remove(paths: [old])
            }
            avatarPath = newPath
        }

        let row = ProfileRow(
            id: userKey,
            handle: profile.handle,
            displayName: profile.displayName,
            bio: profile.bio,
            specialties: profile.specialties.map(\.rawValue),
            locationName: profile.location?.name,
            latitude: profile.location?.latitude,
            longitude: profile.location?.longitude,
            travelRadiusKm: profile.location?.travelRadiusKm,
            avatarPath: avatarPath,
            createdAt: nil,
            updatedAt: nil,
            kind: nil
        )

        do {
            if profile.kind == .company {
                // A company's profile already exists. An upsert would also be checked as if a person were making it, so
                // a company's is only ever updated, and the database decides whether this person may.
                try await client.from("creator_profiles").update(row).eq("id", value: userKey).execute()
            } else {
                try await client.from("creator_profiles").upsert(row, onConflict: "id").execute()
            }
        } catch {
            // 23505 = unique_violation on `handle`.
            if "\(error)".contains("23505") || "\(error)".localizedCaseInsensitiveContains("duplicate key") {
                throw SlateError.handleTaken
            }
            throw error
        }

        guard let saved = try await loadProfile(for: profile.id) else {
            throw SlateError.backend("Your profile was saved but couldn't be loaded.")
        }
        return saved
    }

    private func currentAvatarPath(_ userKey: String) async throws -> String? {
        let rows: [ProfileRow] = try await client
            .from("creator_profiles")
            .select()
            .eq("id", value: userKey)
            .limit(1)
            .execute()
            .value
        return rows.first?.avatarPath
    }

    // MARK: - Portfolio

    func loadPortfolio(for userID: UUID) async throws -> [PortfolioItem] {
        let rows: [PortfolioRow] = try await client
            .from("portfolio_items")
            .select()
            .eq("creator_id", value: Self.key(userID))
            .order("position", ascending: true)
            .execute()
            .value
        return try rows.map(makeItem)
    }

    func addPortfolioItems(_ items: [NewPortfolioItem], for userID: UUID) async throws -> [PortfolioItem] {
        let userKey = Self.key(userID)
        let existing = try await loadPortfolio(for: userID)
        guard existing.count + items.count <= AppConfig.portfolioLimit else {
            throw SlateError.portfolioFull(limit: AppConfig.portfolioLimit)
        }

        let bucket = client.storage.from("portfolio")
        var rows: [PortfolioRow] = []

        for (offset, item) in items.enumerated() {
            let stem = "\(userKey)/\(item.id.uuidString.lowercased())"
            let imagePath = "\(stem).jpg"
            let thumbnailPath = "\(stem)-thumb.jpg"
            let jpegOptions = FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: true)

            try await bucket.upload(imagePath, data: item.imageJPEG, options: jpegOptions)
            try await bucket.upload(thumbnailPath, data: item.thumbnailJPEG, options: jpegOptions)

            var videoPath: String?
            if let file = item.videoFile {
                let ext = file.pathExtension.lowercased()
                let path = "\(stem).\(ext.isEmpty ? "mov" : ext)"
                let type = ext == "mp4" ? "video/mp4" : "video/quicktime"
                try await bucket.upload(
                    path,
                    fileURL: file,
                    options: FileOptions(cacheControl: "31536000", contentType: type, upsert: true)
                )
                try? FileManager.default.removeItem(at: file)
                videoPath = path
            }

            rows.append(PortfolioRow(
                id: item.id.uuidString.lowercased(),
                creatorId: userKey,
                kind: item.kind.rawValue,
                position: existing.count + offset,
                caption: item.caption,
                imagePath: imagePath,
                thumbnailPath: thumbnailPath,
                videoPath: videoPath,
                durationSeconds: item.duration,
                aspectRatio: item.aspectRatio,
                createdAt: nil
            ))
        }

        try await client.from("portfolio_items").insert(rows).execute()
        return try await loadPortfolio(for: userID)
    }

    func deletePortfolioItem(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem] {
        let rows: [PortfolioRow] = try await client
            .from("portfolio_items")
            .select()
            .eq("id", value: Self.key(id))
            .limit(1)
            .execute()
            .value
        if let row = rows.first {
            _ = try? await client.storage.from("portfolio")
                .remove(paths: [row.imagePath, row.thumbnailPath] + [row.videoPath].compactMap { $0 })
            try await client.from("portfolio_items").delete().eq("id", value: Self.key(id)).execute()
        }
        return try await repack(userID: userID)
    }

    func movePortfolioItemToFront(_ id: UUID, for userID: UUID) async throws -> [PortfolioItem] {
        var items = try await loadPortfolio(for: userID)
        guard let index = items.firstIndex(where: { $0.id == id }), index != 0 else { return items }
        let moved = items.remove(at: index)
        items.insert(moved, at: 0)
        try await writePositions(items)
        return try await loadPortfolio(for: userID)
    }

    private func repack(userID: UUID) async throws -> [PortfolioItem] {
        let items = try await loadPortfolio(for: userID)
        try await writePositions(items)
        return try await loadPortfolio(for: userID)
    }

    private func writePositions(_ items: [PortfolioItem]) async throws {
        for (index, item) in items.enumerated() where item.position != index {
            try await client
                .from("portfolio_items")
                .update(["position": index])
                .eq("id", value: Self.key(item.id))
                .execute()
        }
    }

    // MARK: - Mapping

    func publicURL(bucket: String, path: String) throws -> URL {
        try client.storage.from(bucket).getPublicURL(path: path)
    }

    private func makeProfile(_ row: ProfileRow) throws -> CreatorProfile {
        guard let id = UUID(uuidString: row.id) else { throw SlateError.backend("Malformed profile id.") }
        var location: CreatorLocation?
        if let name = row.locationName, let latitude = row.latitude, let longitude = row.longitude {
            location = CreatorLocation(
                name: name,
                latitude: latitude,
                longitude: longitude,
                travelRadiusKm: row.travelRadiusKm ?? TravelRadius.defaultKm
            )
        }
        return CreatorProfile(
            id: id,
            handle: row.handle,
            displayName: row.displayName,
            bio: row.bio,
            specialties: row.specialties.compactMap(Specialty.init(rawValue:)),
            location: location,
            avatarURL: try row.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
            createdAt: row.createdAt ?? Date(),
            updatedAt: row.updatedAt ?? Date(),
            kind: ProfileKind(rawValue: row.kind ?? "person") ?? .person
        )
    }

    private func makeItem(_ row: PortfolioRow) throws -> PortfolioItem {
        guard let id = UUID(uuidString: row.id) else { throw SlateError.backend("Malformed portfolio id.") }
        return PortfolioItem(
            id: id,
            kind: PortfolioItem.Kind(rawValue: row.kind) ?? .photo,
            position: row.position,
            caption: row.caption,
            imageURL: try publicURL(bucket: "portfolio", path: row.imagePath),
            thumbnailURL: try publicURL(bucket: "portfolio", path: row.thumbnailPath),
            videoURL: try row.videoPath.map { try publicURL(bucket: "portfolio", path: $0) },
            duration: row.durationSeconds,
            aspectRatio: row.aspectRatio,
            createdAt: row.createdAt ?? Date()
        )
    }
}

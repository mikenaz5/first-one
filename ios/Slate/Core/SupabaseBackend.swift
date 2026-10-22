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

    private struct ProfileRow: Codable {
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

        enum CodingKeys: String, CodingKey {
            case id, handle, bio, specialties, latitude, longitude
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
            fullName: nil
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
        let name = credential.fullName.map { $0.formatted() }.flatMap { $0.isEmpty ? nil : $0 }
        return AuthSession(
            userID: session.user.id,
            appleUserID: credential.userID,
            email: credential.email ?? session.user.email,
            fullName: name
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
            updatedAt: nil
        )

        do {
            try await client.from("creator_profiles").upsert(row, onConflict: "id").execute()
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

    private func publicURL(bucket: String, path: String) throws -> URL {
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
            updatedAt: row.updatedAt ?? Date()
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

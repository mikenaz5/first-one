import Foundation

extension LocalBackend {
    /// Creators a client could book (they have a published package), found by name, link name or specialty.
    func searchCreators(_ query: String, limit: Int) async throws -> [CreatorProfile] {
        guard CreatorSearchRules.clean(query) != nil else { return [] }
        await seedSampleCreatorsIfNeeded()
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [CreatorProfile] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let profile = try await loadProfile(for: id),
                  CreatorSearchRules.matches(profile, query: query) else { continue }
            if try await loadPackages(for: id).contains(where: \.isPublished) { found.append(profile) }
        }
        return Array(CreatorSearchRules.order(found, query: query).prefix(CreatorSearchRules.clamped(limit: limit)))
    }
}

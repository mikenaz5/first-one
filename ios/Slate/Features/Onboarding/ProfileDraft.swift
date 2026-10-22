import Foundation
import Observation

/// Editable copy of a profile, shared by onboarding and the Edit Profile sheet.
@MainActor
@Observable
final class ProfileDraft {
    enum HandleStatus: Equatable {
        case idle, checking, available, taken, failed
    }

    var displayName = ""
    var handle = ""
    var bio = ""
    var specialties: [Specialty] = []
    var location: CreatorLocation?
    /// A newly chosen photo. Nil means "keep what's there".
    var avatarJPEG: Data?
    var avatarURL: URL?
    /// True for an account that doesn't exist yet (a company being started). Its link is checked against every
    /// account, including the person's own, because it will be a different one.
    var isNewAccount = false

    var handleStatus: HandleStatus = .idle
    /// The handle we suggested from the name; once the person edits it, we stop overwriting it.
    var handleTouched = false
    @ObservationIgnored private(set) var autoHandle = ""

    init() {}

    init(profile: CreatorProfile) {
        displayName = profile.displayName
        handle = profile.handle
        bio = profile.bio
        specialties = profile.specialties
        location = profile.location
        avatarURL = profile.avatarURL
        handleTouched = true
        autoHandle = ""
    }

    // MARK: Derived

    var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var handleProblem: HandleRules.Problem? { HandleRules.validate(handle) }

    var identityIsValid: Bool {
        !trimmedName.isEmpty
            && handleProblem == nil
            && handleStatus != .taken
            && handleStatus != .checking
    }

    var specialtiesAreValid: Bool { !specialties.isEmpty }
    var canPublish: Bool { identityIsValid && specialtiesAreValid }

    // MARK: Mutations

    /// Suggests a handle from the name until the person types their own.
    func updateSuggestedHandle() {
        guard !handleTouched else { return }
        let suggestion = HandleRules.suggestion(from: displayName)
        autoHandle = suggestion
        handle = suggestion
    }

    /// Call when the handle text changes. Returns true if the text was rewritten.
    @discardableResult
    func normalizeHandle() -> Bool {
        let normalized = HandleRules.normalize(handle)
        if handle != autoHandle { handleTouched = true }
        guard normalized != handle else { return false }
        handle = normalized
        return true
    }

    func isSelected(_ specialty: Specialty) -> Bool { specialties.contains(specialty) }

    /// Toggles a specialty. Returns false when adding would exceed the limit.
    @discardableResult
    func toggle(_ specialty: Specialty) -> Bool {
        if let index = specialties.firstIndex(of: specialty) {
            specialties.remove(at: index)
            return true
        }
        guard specialties.count < AppConfig.maxSpecialties else { return false }
        specialties.append(specialty)
        return true
    }

    func setPlace(name: String, latitude: Double, longitude: Double) {
        let radius = location?.travelRadiusKm ?? TravelRadius.defaultKm
        location = CreatorLocation(name: name, latitude: latitude, longitude: longitude, travelRadiusKm: radius)
    }

    func setTravelRadius(_ km: Int) {
        guard var current = location else { return }
        current.travelRadiusKm = km
        location = current
    }

    func clampBio() {
        if bio.count > AppConfig.bioLimit { bio = String(bio.prefix(AppConfig.bioLimit)) }
    }

    func makeProfile(id: UUID, existing: CreatorProfile?) -> CreatorProfile {
        CreatorProfile(
            id: id,
            handle: handle,
            displayName: trimmedName,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
            specialties: specialties,
            location: location,
            avatarURL: existing?.avatarURL,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            kind: existing?.kind ?? .person
        )
    }
}

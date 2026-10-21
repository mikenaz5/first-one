import Foundation

// MARK: - Specialties

enum Specialty: String, Codable, CaseIterable, Identifiable, Hashable {
    case weddings, events, portraits, family, commercial, realEstate, product
    case fashion, food, music, documentary, social, corporate, aerial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weddings: "Weddings"
        case .events: "Events"
        case .portraits: "Portraits"
        case .family: "Family"
        case .commercial: "Commercial"
        case .realEstate: "Real estate"
        case .product: "Product"
        case .fashion: "Fashion"
        case .food: "Food"
        case .music: "Music"
        case .documentary: "Documentary"
        case .social: "Social content"
        case .corporate: "Corporate"
        case .aerial: "Aerial"
        }
    }

    /// SF Symbol used on chips.
    var symbol: String {
        switch self {
        case .weddings: "heart.fill"
        case .events: "party.popper.fill"
        case .portraits: "person.crop.square.fill"
        case .family: "figure.2.and.child.holdinghands"
        case .commercial: "briefcase.fill"
        case .realEstate: "house.fill"
        case .product: "shippingbox.fill"
        case .fashion: "tshirt.fill"
        case .food: "fork.knife"
        case .music: "music.mic"
        case .documentary: "film.fill"
        case .social: "play.square.stack.fill"
        case .corporate: "building.2.fill"
        case .aerial: "airplane"
        }
    }
}

// MARK: - Location

struct CreatorLocation: Codable, Equatable, Hashable {
    /// City-level label, e.g. "Austin, TX". Never a street address.
    var name: String
    var latitude: Double
    var longitude: Double
    var travelRadiusKm: Int
}

// MARK: - Profile

struct CreatorProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var handle: String
    var displayName: String
    var bio: String
    var specialties: [Specialty]
    var location: CreatorLocation?
    var avatarURL: URL?
    var createdAt: Date
    var updatedAt: Date

    /// The minimum a creator needs before the app treats onboarding as done.
    var isComplete: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && HandleRules.validate(handle) == nil
            && !specialties.isEmpty
    }
}

// MARK: - Portfolio

struct PortfolioItem: Identifiable, Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case photo
        case video
    }

    var id: UUID
    var kind: Kind
    var position: Int
    var caption: String
    /// Full-size image for photos; poster frame for videos.
    var imageURL: URL
    var thumbnailURL: URL
    var videoURL: URL?
    var duration: TimeInterval?
    /// width / height of the media.
    var aspectRatio: Double
    var createdAt: Date

    var isVideo: Bool { kind == .video }

    var accessibilityDescription: String {
        let base: String
        if isVideo {
            base = "Reel" + (duration.flatMap(Self.spokenDuration).map { ", \($0)" } ?? "")
        } else {
            base = "Photo"
        }
        return caption.isEmpty ? base : "\(base), \(caption)"
    }

    /// "1 minute, 15 seconds" in the person's language, for VoiceOver.
    private static func spokenDuration(_ seconds: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds.rounded())
    }
}

enum PortfolioFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case reels = "Reels"

    var id: String { rawValue }

    func matches(_ item: PortfolioItem) -> Bool {
        switch self {
        case .all: true
        case .photos: item.kind == .photo
        case .reels: item.kind == .video
        }
    }
}

/// A picked-and-processed item that has not been saved to a backend yet.
struct NewPortfolioItem: Identifiable, Equatable {
    let id = UUID()
    var kind: PortfolioItem.Kind
    var imageJPEG: Data
    var thumbnailJPEG: Data
    /// Temporary local file for videos.
    var videoFile: URL?
    var duration: TimeInterval?
    var aspectRatio: Double
    var caption = ""
}

// MARK: - Session

struct AuthSession: Codable, Equatable {
    var userID: UUID
    var appleUserID: String?
    var email: String?
    /// Only available the first time a person signs in with Apple.
    var fullName: String?
}

struct AppleCredential {
    var userID: String
    var identityToken: String
    var rawNonce: String
    var fullName: PersonNameComponents?
    var email: String?
}

// MARK: - Completeness

struct ProfileCompleteness {
    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        let isDone: Bool
    }

    static let recommendedPortfolioCount = 3

    let steps: [Step]

    init(profile: CreatorProfile, portfolioCount: Int) {
        steps = [
            Step(id: "photo", title: "Add a profile photo", isDone: profile.avatarURL != nil),
            Step(id: "bio", title: "Write a short bio",
                 isDone: !profile.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            Step(id: "specialties", title: "Choose your specialties", isDone: !profile.specialties.isEmpty),
            Step(id: "location", title: "Set your home base", isDone: profile.location != nil),
            Step(id: "portfolio",
                 title: "Add \(Self.recommendedPortfolioCount) portfolio pieces",
                 isDone: portfolioCount >= Self.recommendedPortfolioCount),
        ]
    }

    var fraction: Double {
        Double(steps.filter(\.isDone).count) / Double(steps.count)
    }

    var isComplete: Bool { steps.allSatisfy(\.isDone) }
    var nextStep: Step? { steps.first { !$0.isDone } }
}

// MARK: - Errors

enum SlateError: LocalizedError, Equatable {
    case notSignedIn
    case invalidCredential
    case handleTaken
    case portfolioFull(limit: Int)
    case videoTooLong(maxSeconds: Int)
    case mediaUnreadable
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "You're signed out. Please sign in again."
        case .invalidCredential:
            "Apple didn't return a usable sign-in credential. Please try again."
        case .handleTaken:
            "That link name is already taken."
        case .portfolioFull(let limit):
            "Your portfolio can hold up to \(limit) pieces."
        case .videoTooLong(let maxSeconds):
            "Reels can be up to \(maxSeconds / 60) minutes long."
        case .mediaUnreadable:
            "That file couldn't be read."
        case .backend(let message):
            message
        }
    }
}

// MARK: - Config

enum AppConfig {
    /// Placeholder host for public booking links (`.example` is reserved and never resolves).
    static let bookingLinkHost = "slate.example"
    static let portfolioLimit = 12
    static let maxVideoSeconds = 120
    static let bioLimit = 280
    static let maxSpecialties = 5

    /// UserDefaults key for the Apple user identifier (used to detect revoked credentials).
    static let appleUserIDKey = "slate.appleUserID"
    /// Fake Apple user identifier used by the debug-only demo sign-in.
    static let demoAppleUserID = "slate.demo"

    static func bookingURL(handle: String) -> URL? {
        URL(string: "https://\(bookingLinkHost)/\(handle)")
    }

    /// Supabase credentials from Info.plist (set via Config/Secrets.xcconfig). Nil means "use LocalBackend".
    static var supabase: (url: URL, anonKey: String)? {
        let info = Bundle.main.infoDictionary
        guard
            let urlString = info?["SupabaseURL"] as? String,
            let anonKey = info?["SupabaseAnonKey"] as? String,
            !urlString.isEmpty, !anonKey.isEmpty,
            let url = URL(string: urlString), url.host != nil
        else { return nil }
        return (url, anonKey)
    }
}

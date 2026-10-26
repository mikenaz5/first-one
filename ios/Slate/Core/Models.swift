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
    /// A person, or a company with a team. A company's id is its organization id.
    var kind: ProfileKind = .person

    init(
        id: UUID, handle: String, displayName: String, bio: String, specialties: [Specialty],
        location: CreatorLocation? = nil, avatarURL: URL? = nil, createdAt: Date, updatedAt: Date,
        kind: ProfileKind = .person
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.specialties = specialties
        self.location = location
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
    }

    /// Profiles saved before companies existed have no `kind`; they are people.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decode(String.self, forKey: .displayName)
        bio = try c.decode(String.self, forKey: .bio)
        specialties = try c.decode([Specialty].self, forKey: .specialties)
        location = try c.decodeIfPresent(CreatorLocation.self, forKey: .location)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        kind = try c.decodeIfPresent(ProfileKind.self, forKey: .kind) ?? .person
    }

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
    case invalidPackage
    case packageUnavailable
    case invalidAvailability
    case slotTaken
    case slotUnavailable
    case cannotBookYourself
    case notCancellable
    case calendarAccessDenied
    case contractChanged
    case contractMissing
    case invalidContract
    case invalidSignature
    case creatorNotReady
    case templateInUse
    case holdExpired
    case paymentsNotReady
    case paymentNotDue
    case alreadyPaid
    case paymentProcessing
    case paymentUnavailable
    case paymentsNotConfigured
    case applePayUnavailable
    case notDeliverable
    case invalidDeliveryLink
    case deliveryNoteTooLong
    case notDelivered
    case notReviewable
    case invalidRating
    case reviewTooLong
    case alreadyReviewed
    case bookingNotFound
    case conversationClosed
    case invalidMessage
    case messageTooLong
    case rateLimited
    case notFound
    case notAllowed
    case invalidInput
    case planInactive
    case seatLimit
    case inviteInvalid
    case alreadyMember
    case lastOwner
    case invalidRole
    case hasUpcomingBookings
    case teamNotEmpty
    case bookingsInHold
    case signatureRequired
    case signerRoleNotAllowed
    case invalidAssignee
    case notAssignable
    case memberUnavailable
    case profileRequired
    case billingUnavailable
    case invalidEmail
    case invalidCode
    case nameRequired
    case tooManyCards(limit: Int)
    case cardNotFound
    case cardExpired
    case noCardAccess
    case noBookingWithCreator
    case cardConsentOutdated
    case cardDeclined
    case cardNeedsApproval
    case filesNotAllowed
    case unsupportedFileType
    case firstDeliveryLocked
    case revisionNotAllowed
    case fileRefused(FileRefusal)
    case uploadIncomplete
    case nothingToDeliver
    case filesNotReady
    case originalsLocked
    case fileTitleTooLong
    case fileUnavailable
    case photosAccessDenied
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
        case .invalidPackage:
            "This package has a problem. Check the fields and try again."
        case .packageUnavailable:
            "This package isn't available anymore."
        case .invalidAvailability:
            "Those availability settings aren't valid."
        case .slotTaken:
            "Someone just booked that time. Please choose another."
        case .slotUnavailable:
            "That time isn't available anymore. Please choose another."
        case .cannotBookYourself:
            "You can't book your own package."
        case .notCancellable:
            "This booking can't be cancelled."
        case .calendarAccessDenied:
            "Calendar access is off. You can allow it in Settings."
        case .contractChanged:
            "The contract changed while you were reading it. Please read it again before signing."
        case .contractMissing:
            "This package doesn't have a contract yet, so it can't be booked."
        case .invalidContract:
            "This contract has a problem. Check the highlighted items and try again."
        case .invalidSignature:
            "Add your signature (your full name, typed or drawn) to continue."
        case .creatorNotReady:
            "This creator hasn't finished setting up their signature, so they can't take bookings yet."
        case .templateInUse:
            "A package still uses this contract. Switch those packages to another contract first."
        case .holdExpired:
            "Your hold on this time ran out before the deposit was paid. Please choose a time again."
        case .paymentsNotReady:
            "This creator hasn't finished setting up payments yet, so they can't take bookings that need a deposit."
        case .paymentNotDue:
            "There's nothing to pay for this booking right now."
        case .alreadyPaid:
            "This has already been paid."
        case .paymentProcessing:
            "Your payment is still being processed. Check back in a moment."
        case .paymentUnavailable:
            "Payments are unavailable right now. Please try again in a moment."
        case .paymentsNotConfigured:
            "This build isn't set up to take payments yet. It needs Stripe and Apple Pay keys; see the README."
        case .applePayUnavailable:
            "Apple Pay isn't set up on this device. Add a card to Wallet and try again."
        case .notDeliverable:
            "Final files can be shared once the shoot has started, and until the client confirms they have them."
        case .invalidDeliveryLink:
            "Paste a link that starts with https:// (for example a Dropbox, Google Drive or WeTransfer share link)."
        case .deliveryNoteTooLong:
            "Notes can be up to \(DeliveryRules.noteMaxLength) characters."
        case .notDelivered:
            "There are no final files to confirm yet."
        case .notReviewable:
            "You can review a booking once the work is delivered, confirmed and paid for."
        case .invalidRating:
            "Choose between one and five stars."
        case .reviewTooLong:
            "Reviews can be up to \(ReviewRules.maxLength.formatted()) characters."
        case .alreadyReviewed:
            "You've already reviewed this booking."
        case .bookingNotFound:
            "That booking couldn't be found."
        case .conversationClosed:
            "This conversation is closed."
        case .invalidMessage:
            "Write something to send."
        case .messageTooLong:
            "Messages can be up to \(MessageRules.maxLength.formatted()) characters."
        case .rateLimited:
            "You're sending messages very quickly. Wait a moment and try again."
        case .notFound:
            "That couldn't be found."
        case .notAllowed:
            "Your role doesn't allow that. Ask an owner or admin of the company."
        case .invalidInput:
            "Something in that isn't valid. Check it and try again."
        case .planInactive:
            "The company's plan isn't active. An owner can fix this under Billing."
        case .seatLimit:
            "The team is full. Remove someone, or an open invite, to make room."
        case .inviteInvalid:
            "This invite is no longer valid. Ask for a new one."
        case .alreadyMember:
            "You're already part of this company."
        case .lastOwner:
            "A company needs an owner. Transfer ownership first."
        case .invalidRole:
            "That isn't a role you can give."
        case .hasUpcomingBookings:
            "They still have upcoming bookings. Move those to someone else first."
        case .teamNotEmpty:
            "Remove the other people from the team first."
        case .bookingsInHold:
            "A booking is waiting for its deposit. Wait for it, or cancel it, first."
        case .signatureRequired:
            "Add a signature first."
        case .signerRoleNotAllowed:
            "That person's role isn't allowed to sign contracts for the company. Change the allowed roles first."
        case .invalidAssignee:
            "That person can't take this booking."
        case .notAssignable:
            "This booking can't be assigned anymore."
        case .memberUnavailable:
            "That person isn't available to be booked."
        case .profileRequired:
            "Set up your own profile first."
        case .billingUnavailable:
            "Billing isn't available in this build. It needs a server with Stripe set up; see the README."
        case .invalidEmail:
            "Check the email address and try again."
        case .invalidCode:
            "That code didn't work. It may have expired, so ask for a new one."
        case .nameRequired:
            "Add your name. It goes on the contracts you sign."
        case .tooManyCards(let limit):
            "You can keep up to \(limit) cards. Remove one to add another."
        case .cardNotFound:
            "That card isn't on file any more."
        case .cardExpired:
            "That card has expired."
        case .noCardAccess:
            "This client hasn't allowed a saved card to be charged for this booking."
        case .noBookingWithCreator:
            "You can only allow creators you've booked."
        case .cardConsentOutdated:
            "The wording of the agreement changed. Please open it again."
        case .cardDeclined:
            "The card was declined. The client can pay the balance in the app instead."
        case .cardNeedsApproval:
            "The client's bank needs them to approve this payment. They can pay the balance in the app instead."
        case .filesNotAllowed:
            "Photos and videos can be delivered once the shoot has started, while the booking is confirmed or complete."
        case .unsupportedFileType:
            "Slate Pro takes photos (JPEG, PNG, HEIC, TIFF, WebP) and videos (MP4, MOV, M4V)."
        case .firstDeliveryLocked:
            "This booking was already delivered by link, or its balance is paid, so the first delivery can't be sent as files."
        case .revisionNotAllowed:
            "A revision can be sent after the first delivery, once nothing is owed."
        case .fileRefused(let refusal):
            refusal.message
        case .uploadIncomplete:
            "The upload didn't finish. Try sending it again."
        case .nothingToDeliver:
            "Add at least one photo or video first."
        case .filesNotReady:
            "Some files are still uploading. Wait for them to finish."
        case .originalsLocked:
            "The originals unlock when the balance is paid."
        case .fileTitleTooLong:
            "Keep the title under 80 characters."
        case .fileUnavailable:
            "That file isn't available any more."
        case .photosAccessDenied:
            "Allow \(AppConfig.productName) to add to your photos in Settings, or save to Files instead."
        case .backend(let message):
            message
        }
    }
}

// MARK: - Config

enum AppConfig {
    /// What the app is called to the people who use it. The target, module, folders, `slate://` link scheme, bundle ids
    /// and placeholder domain keep the working name "Slate"; nothing a person reads should.
    static let productName = "Slate Pro"

    /// Placeholder host for public booking links (`.example` is reserved and never resolves).
    static let bookingLinkHost = "slate.example"
    static let portfolioLimit = 12
    /// How many reviews a creator's page loads at a time.
    static let reviewsPageSize = 20
    static let maxVideoSeconds = 120
    static let bioLimit = 280
    static let maxSpecialties = 5

    /// UserDefaults key for the Apple user identifier (used to detect revoked credentials).
    static let appleUserIDKey = "slate.appleUserID"
    /// Set once the person says "Not now" to the card asking them to turn notifications on.
    static let notificationPromptDismissedKey = "slate.notificationPromptDismissed"
    /// Fake Apple user identifier used by the debug-only demo sign-in.
    static let demoAppleUserID = "slate.demo"

    /// Set when a person says they are here to book (a client), so a person with no profile isn't asked to make one.
    static func clientAccountKey(for userID: UUID) -> String { "slate.clientAccount.\(userID.uuidString.lowercased())" }

    /// The city a client chose, or the one their phone found, to see creators near them. Kept on this device only.
    static func clientPlaceKey(for userID: UUID) -> String { "slate.clientPlace.\(userID.uuidString.lowercased())" }

    /// Which account (their own, or a company's) a person last had open on this device.
    static func activeAccountKey(for userID: UUID) -> String { "slate.activeAccount.\(userID.uuidString.lowercased())" }

    /// Custom URL scheme: `slate://book/<handle>` opens a creator's page in the app.
    static let urlScheme = "slate"

    static func bookingDeepLink(handle: String) -> URL? {
        URL(string: "\(urlScheme)://book/\(handle)")
    }

    /// `slate://join/<token>` opens the app on a company invite.
    static func joinDeepLink(token: String) -> URL? {
        URL(string: "\(urlScheme)://join/\(token)")
    }

    static func bookingURL(handle: String) -> URL? {
        URL(string: "https://\(bookingLinkHost)/\(handle)")
    }

    /// Stripe's publishable key and the Apple Pay merchant ID, from Info.plist (set in Config/Secrets.xcconfig).
    /// Nil means real payments aren't configured; on-device mode doesn't need them.
    static var stripe: (publishableKey: String, merchantID: String)? {
        let info = Bundle.main.infoDictionary
        guard
            let key = info?["StripePublishableKey"] as? String,
            let merchant = info?["ApplePayMerchantID"] as? String,
            !key.isEmpty, !merchant.isEmpty
        else { return nil }
        return (key, merchant)
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

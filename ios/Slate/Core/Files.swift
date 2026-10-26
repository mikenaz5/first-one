import Foundation

// MARK: - Slate Files
//
// A creator delivers the finished photos and videos inside the app. The client sees reduced, watermarked previews at
// once, pays the balance, and then saves the originals; everything is deleted 30 days after delivery. SPEC.md 5.5 and
// 8.12 say how it works. This file is the part that is pure rules, kept in step with the `files_*` functions in
// `…_slate_files.sql`: `SlateTests/Fixtures/file_rules.json` is read by both test suites.

// MARK: - Settings (SPEC 4.4)

/// The numbers behind Slate Files. In SQL they are the `files` row of `app_settings` (read through `files_config()`);
/// `standard` is the on-device default and the fallback.
struct FilesConfig: Equatable, Codable {
    /// How long a delivery stays, counted from the moment it is delivered.
    var retentionDays: Int
    /// How long files that were uploaded but never delivered are kept.
    var draftDays: Int
    /// Reminders to the client, in days before expiry, while anything is unsaved.
    var warnDays: [Int]
    var quotaGBIndividual: Int
    /// Added per billed seat for a company, shared across it.
    var quotaGBPerSeat: Int
    var maxPhotoMB: Int
    var maxVideoGB: Int
    var maxFiles: Int
    var previewPhotoMaxMB: Int
    var previewVideoMaxMB: Int
    /// How long a download link works once the app has asked for it.
    var urlMinutes: Int
    /// How long a file that was reserved but never finished uploading keeps its space.
    var reservationHours: Int

    static let standard = FilesConfig(
        retentionDays: 30, draftDays: 7, warnDays: [7, 1], quotaGBIndividual: 50, quotaGBPerSeat: 50,
        maxPhotoMB: 100, maxVideoGB: 4, maxFiles: 1000, previewPhotoMaxMB: 5, previewVideoMaxMB: 150,
        urlMinutes: 15, reservationHours: 24
    )

    /// Sizes are decimal, the way the system shows them (a 100 MB photo is 100,000,000 bytes).
    static let megabyte: Int64 = 1_000_000
    static let gigabyte: Int64 = 1_000_000_000
}

// MARK: - What exists

enum FileKind: String, Codable, CaseIterable, Hashable {
    case photo, video

    var title: String { self == .photo ? "Photo" : "Video" }
    var symbol: String { self == .photo ? "photo" : "video" }
}

enum FileStatus: String, Codable, Hashable {
    /// Space is reserved and the bytes are on their way. Covers a file that is still being sent.
    case uploading
    case ready
    case removed
    case expired
}

enum DeliveryKind: String, Codable, Hashable {
    case delivery, revision
}

enum DeliveryState: String, Codable, Hashable {
    /// Being put together: nobody but the creator side can see it.
    case draft
    case delivered
    case expired
}

/// One photo or video: its original and the small watermarked preview that goes with it.
struct DeliveryFile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var kind: FileKind
    var name: String
    var contentType: String
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var originalBytes: Int64
    var previewBytes: Int64
    var status: FileStatus
    /// When the client first saved the original. Nil until they have.
    var savedAt: Date?
    var createdAt: Date
    var position: Int
    /// Where the preview is kept. A path is not a link: opening one needs the signed-in person's own access.
    var previewPath: String
    /// Where the original is kept. Nil while it is locked for the client.
    var originalPath: String?

    var isSaved: Bool { savedAt != nil }

    /// Width over height, for laying out a grid before the picture is there.
    var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1.5 }
        return Double(width) / Double(height)
    }

    /// "0:42" for a video, nil for a photo.
    var durationText: String? {
        guard kind == .video, let durationSeconds else { return nil }
        let total = max(0, Int(durationSeconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The first delivery of a booking, or one revision after it.
struct FileDelivery: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var bookingID: UUID
    var kind: DeliveryKind
    /// 0 for the delivery; 1, 2 and so on for revisions.
    var sequence: Int
    var title: String
    var note: String
    var state: DeliveryState
    var createdAt: Date
    var deliveredAt: Date?
    var expiresAt: Date?
    /// Whether the originals can be opened by the person looking, as of when this was fetched. The database decides.
    var originalsOpen: Bool
    var files: [DeliveryFile]

    /// Files that are part of it now: everything but what was removed.
    var liveFiles: [DeliveryFile] { files.filter { $0.status != .removed } }
    var readyFiles: [DeliveryFile] { files.filter { $0.status == .ready || $0.status == .expired } }
    var photoCount: Int { readyFiles.filter { $0.kind == .photo }.count }
    var videoCount: Int { readyFiles.filter { $0.kind == .video }.count }
    var savedCount: Int { readyFiles.filter(\.isSaved).count }
    var unsavedCount: Int { readyFiles.count - savedCount }
    var totalBytes: Int64 { readyFiles.reduce(0) { $0 + $1.originalBytes } }
    var isUploading: Bool { files.contains { $0.status == .uploading } }

    func isExpired(at now: Date) -> Bool {
        state == .expired || (state == .delivered && (expiresAt.map { $0 <= now } ?? false))
    }

    /// "Delivery" or the revision's title.
    var heading: String {
        kind == .delivery ? "Delivery" : (title.isEmpty ? FileRules.revisionTitle(sequence: sequence) : title)
    }

    /// Whole days until it ends (rounded up), or nil once it has.
    func daysLeft(at now: Date) -> Int? {
        guard state == .delivered, let expiresAt, expiresAt > now else { return nil }
        return Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.up))
    }

    /// "12 photos and 3 videos".
    var countText: String {
        readyFiles.isEmpty ? "No files" : FileRules.countText(photos: photoCount, videos: videoCount)
    }
}

/// Everything about a booking's files that the person looking is allowed to know.
struct BookingFiles: Equatable {
    var bookingID: UUID
    /// What the client still owes on the booking. Originals of the first delivery stay locked until this is zero.
    var owedCents: Int
    var deliveries: [FileDelivery]
    /// The creator side only: the allowance of the account the files count against.
    var usedBytes: Int64?
    var allowanceBytes: Int64?
    /// Whether the creator can still deliver the first time by files (it is locked once the client has paid or confirmed
    /// receipt of a link).
    var canDeliverFiles: Bool
    /// Whether a revision can be sent now.
    var canSendRevision: Bool

    static func empty(for bookingID: UUID) -> BookingFiles {
        BookingFiles(bookingID: bookingID, owedCents: 0, deliveries: [], usedBytes: nil, allowanceBytes: nil, canDeliverFiles: false, canSendRevision: false)
    }

    /// The delivery that is being put together, if any.
    var draft: FileDelivery? { deliveries.first { $0.state == .draft } }
    /// The first delivery, once there is one.
    var firstDelivery: FileDelivery? { deliveries.first { $0.sequence == 0 } }
    /// What the client sees: deliveries that were delivered (and have since expired), newest first.
    var delivered: [FileDelivery] {
        deliveries.filter { $0.state != .draft }.sorted { $0.sequence > $1.sequence }
    }
    var hasFiles: Bool { deliveries.contains { !$0.liveFiles.isEmpty } }
    var meter: StorageMeter? {
        guard let usedBytes, let allowanceBytes else { return nil }
        return StorageMeter(usedBytes: usedBytes, allowanceBytes: allowanceBytes)
    }
}

/// "4.2 of 50 GB used".
struct StorageMeter: Equatable {
    var usedBytes: Int64
    var allowanceBytes: Int64

    var fraction: Double {
        guard allowanceBytes > 0 else { return 1 }
        return min(1, max(0, Double(usedBytes) / Double(allowanceBytes)))
    }

    var isNearlyFull: Bool { fraction >= 0.9 }
    var remainingBytes: Int64 { max(0, allowanceBytes - usedBytes) }

    var text: String { "\(ByteText.format(usedBytes)) of \(ByteText.format(allowanceBytes)) used" }
}

enum ByteText {
    /// "4.2 GB", "812 KB". Decimal units, like the system's own.
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Sending a file

/// What the creator's phone tells the backend about a file it wants to send. Sizes are the real ones, measured on the
/// phone; the backend refuses anything that doesn't fit and checks them again when the upload is finished.
struct FileUploadRequest: Equatable {
    var bookingID: UUID
    var kind: FileKind
    var name: String
    var contentType: String
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var originalBytes: Int64
    var previewBytes: Int64
}

/// A file's place in storage once the backend has accepted it.
struct FileReservation: Equatable {
    var fileID: UUID
    var deliveryID: UUID
    var deliveryKind: DeliveryKind
    var originalPath: String
    var previewPath: String
}

/// Why a file was turned away: it is the answer to "can I add this?", before or after the bytes are sent.
enum FileRefusal: Equatable {
    case tooManyFiles
    case empty
    case tooLarge(maxBytes: Int64)
    case previewTooLarge(maxBytes: Int64)
    case storageFull(usedBytes: Int64, allowanceBytes: Int64)

    /// A sentence for the creator.
    var message: String {
        switch self {
        case .tooManyFiles:
            "A delivery holds up to \(FilesConfig.standard.maxFiles) files. Send the rest as a revision."
        case .empty:
            "That file is empty."
        case .tooLarge(let maxBytes):
            "That file is over the \(ByteText.format(maxBytes)) limit."
        case .previewTooLarge:
            "The preview of that file came out too large."
        case .storageFull(let used, let allowance):
            allowance > 0
                ? "Your storage is full: \(ByteText.format(used)) of \(ByteText.format(allowance)) used. Remove something, or deliver by link."
                : "Your storage is full. Remove something, or deliver by link."
        }
    }
}

/// Where a file's bytes are on the creator's phone, ready to send: the original as it came, and the small watermarked preview.
struct FileUploadSource: Equatable {
    var original: URL
    var preview: URL
}

/// The backend's verdict once the bytes are in storage.
enum FileFinalization: Equatable {
    case accepted
    case refused(FileRefusal)
}

/// How many of a delivery's files the client has saved.
struct FileSaveCount: Equatable {
    var saved: Int
    var total: Int
}

/// Where to read a file from right now: a short-lived link to private storage, or a file on this phone.
struct FileSource: Equatable {
    var url: URL
    var isRemote: Bool
}

// MARK: - Rules

enum FileRules {
    static let photoTypes: Set<String> = ["image/jpeg", "image/png", "image/heic", "image/heif", "image/tiff", "image/webp"]
    static let videoTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v"]
    static let nameMaxLength = 120

    /// Which kind of file a content type is, or nil if Slate Pro doesn't take it. Mirrors `files_kind_for()`.
    static func kind(forContentType type: String) -> FileKind? {
        let lowered = type.lowercased()
        if photoTypes.contains(lowered) { return .photo }
        if videoTypes.contains(lowered) { return .video }
        return nil
    }

    static func maxOriginalBytes(_ kind: FileKind, config: FilesConfig = .standard) -> Int64 {
        kind == .photo ? Int64(config.maxPhotoMB) * FilesConfig.megabyte : Int64(config.maxVideoGB) * FilesConfig.gigabyte
    }

    static func maxPreviewBytes(_ kind: FileKind, config: FilesConfig = .standard) -> Int64 {
        Int64(kind == .photo ? config.previewPhotoMaxMB : config.previewVideoMaxMB) * FilesConfig.megabyte
    }

    /// An individual's allowance, or a company's: per billed seat, shared by everyone in it. Mirrors `files_allowance_bytes()`.
    static func allowanceBytes(individual: Bool, billedSeats: Int, config: FilesConfig = .standard) -> Int64 {
        individual
            ? Int64(config.quotaGBIndividual) * FilesConfig.gigabyte
            : Int64(config.quotaGBPerSeat) * Int64(max(0, billedSeats)) * FilesConfig.gigabyte
    }

    /// Whether a file may be added, in this order: room in the delivery, not empty, original within its cap, preview
    /// within its cap, room in the allowance. Mirrors `files_check_caps()`.
    static func refusal(
        kind: FileKind, originalBytes: Int64, previewBytes: Int64, filesInDelivery: Int,
        usedBytes: Int64, allowanceBytes: Int64, config: FilesConfig = .standard
    ) -> FileRefusal? {
        if filesInDelivery >= config.maxFiles { return .tooManyFiles }
        if originalBytes <= 0 || previewBytes <= 0 { return .empty }
        if originalBytes > maxOriginalBytes(kind, config: config) { return .tooLarge(maxBytes: maxOriginalBytes(kind, config: config)) }
        if previewBytes > maxPreviewBytes(kind, config: config) { return .previewTooLarge(maxBytes: maxPreviewBytes(kind, config: config)) }
        if usedBytes + originalBytes + previewBytes > allowanceBytes { return .storageFull(usedBytes: usedBytes, allowanceBytes: allowanceBytes) }
        return nil
    }

    /// The database's names for the same answers, for the shared fixture and for mapping its errors.
    static func token(for refusal: FileRefusal?) -> String? {
        switch refusal {
        case nil: nil
        case .tooManyFiles?: "too_many_files"
        case .empty?: "file_empty"
        case .tooLarge?: "file_too_large"
        case .previewTooLarge?: "preview_too_large"
        case .storageFull?: "storage_full"
        }
    }

    // MARK: When

    /// When a delivery made at `deliveredAt` ends. Mirrors `files_expires_at()`.
    static func expiresAt(deliveredAt: Date, config: FilesConfig = .standard) -> Date {
        deliveredAt.addingTimeInterval(TimeInterval(config.retentionDays) * 86_400)
    }

    static func isExpired(expiresAt: Date, now: Date) -> Bool { expiresAt <= now }

    /// Which reminder applies right now: the smallest number of days (of 7 and 1) that the end is within, while the files
    /// are still there. Mirrors `files_reminder_day()`.
    static func reminderDay(expiresAt: Date, now: Date, config: FilesConfig = .standard) -> Int? {
        guard expiresAt > now else { return nil }
        return config.warnDays.sorted().first { now >= expiresAt.addingTimeInterval(-TimeInterval($0) * 86_400) }
    }

    // MARK: Who can open what

    enum Viewer: String { case client, provider, other }
    enum Part: String { case preview, original }

    /// Whether a person can open a preview or an original, from the delivery's state and what is owed. The client sees a
    /// delivery's previews from delivery until it ends, and its originals only when nothing is owed (a revision is never
    /// locked). The creator side sees everything while it exists. Mirrors `files_can_open()`.
    static func canOpen(
        _ part: Part, as viewer: Viewer, kind: DeliveryKind, state: DeliveryState, expiresAt: Date?, owedCents: Int, now: Date
    ) -> Bool {
        switch viewer {
        case .other:
            return false
        case .provider:
            switch state {
            case .draft: return true
            case .delivered: return expiresAt.map { $0 > now } ?? false
            case .expired: return false
            }
        case .client:
            guard state == .delivered, let expiresAt, expiresAt > now else { return false }
            switch part {
            case .preview: return true
            case .original: return kind == .revision || owedCents <= 0
            }
        }
    }

    // MARK: Which way, and when a revision is allowed

    /// The first delivery is by files or by link, and the choice is locked once a link has been shared (so the client
    /// isn't left with two) or the client has paid the balance. Mirrors `files_first_delivery_locked()`.
    static func firstDeliveryLocked(hasFilesDelivery: Bool, linkDelivered: Bool, balancePaid: Bool) -> Bool {
        !hasFilesDelivery && (linkDelivered || balancePaid)
    }

    /// A revision needs a first delivery that was made, and nothing owed: it is not a way round payment (R21).
    /// Mirrors `files_revision_allowed()`.
    static func revisionAllowed(firstState: DeliveryState?, owedCents: Int) -> Bool {
        (firstState == .delivered || firstState == .expired) && owedCents <= 0
    }

    static func revisionTitle(sequence: Int) -> String { "Revision \(sequence)" }

    /// Whether a file's preview is a short video rather than a picture. The first delivery's video preview is a reduced,
    /// watermarked video; a revision is never locked, so its preview is only the small picture a tile needs.
    static func previewIsVideo(kind: FileKind, deliveryKind: DeliveryKind) -> Bool {
        kind == .video && deliveryKind == .delivery
    }

    /// "12 photos and 2 videos", "1 photo", "3 videos"; "files" when there are none. The notification wording says the same.
    static func countText(photos: Int, videos: Int) -> String {
        func part(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        if photos > 0, videos > 0 { return "\(part(photos, "photo")) and \(part(videos, "video"))" }
        if photos > 0 { return part(photos, "photo") }
        if videos > 0 { return part(videos, "video") }
        return "files"
    }

    // MARK: Names

    /// A file's name as it is kept and shown: no slashes or control characters (they become a space), runs of spaces
    /// collapsed, at most 120 characters, and "Untitled" if nothing is left. Mirrors `files_clean_name()`.
    static func cleanName(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let breaks = scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == " "
            if breaks {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = trim(scalars)
        let cut = trim(Array(trimmed.prefix(nameMaxLength)))
        if cut.isEmpty { return "Untitled" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: cut)
        return String(view)
    }

    private static func trim(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var start = 0
        var end = scalars.count
        while start < end, scalars[start] == " " { start += 1 }
        while end > start, scalars[end - 1] == " " { end -= 1 }
        return Array(scalars[start..<end])
    }
}

/// How the creator's phone makes the small copies the client sees. The numbers keep a preview under its cap.
enum PreviewSpec {
    /// A watermarked preview of a photo: the long edge, in points, and the JPEG quality to start from.
    static let photoLongEdge: CGFloat = 1600
    static let photoQuality: CGFloat = 0.7
    /// The small, unmarked picture that fills a grid tile (and the only picture a revision needs).
    static let thumbnailLongEdge: CGFloat = 480
    static let thumbnailQuality: CGFloat = 0.7
    /// A video preview is scaled so its long edge is at most this (960 by 540 for ordinary video) and marked the same way.
    static let videoLongEdge: CGFloat = 960
    static let watermarkText = "PREVIEW"
}

import Foundation

// MARK: - Slate Files, on the creator's phone
//
// What happens between choosing a photo and it being a file on the booking: the phone makes the small copy the client sees
// (`FilePreparing`), asks the backend for room (`reserveFile`), sends the bytes, and asks the backend to check them. This
// file holds the plain types for that, with no UI, so the steps can be tested with a stand-in for the slow parts.

/// What the small copy is like. The first delivery's is watermarked and reduced, because the client sees it before paying.
/// A revision is never locked, so its copy is only the small picture the grid needs.
enum PreviewStyle: Equatable {
    case watermarked
    case thumbnail

    /// The kind of delivery a style belongs to.
    var deliveryKind: DeliveryKind { self == .watermarked ? .delivery : .revision }

    static func forDelivery(_ kind: DeliveryKind) -> PreviewStyle { kind == .delivery ? .watermarked : .thumbnail }
}

/// A file the person chose: a copy the app owns in its own temporary folder, so the picker's file can go away.
struct PickedFile: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    /// The name to show, with its extension.
    var name: String
    /// What the system says it is, such as `image/heic`. Nil when it couldn't tell.
    var contentType: String?

    /// What it is filed under: what the system said if Slate Pro takes that, otherwise what the ending says. Nil if neither is
    /// a photo or video type Slate Pro takes.
    var resolvedContentType: String? {
        if let said = contentType?.lowercased(), FileRules.kind(forContentType: said) != nil { return said }
        return FileNames.contentType(forExtension: url.pathExtension.isEmpty ? (name as NSString).pathExtension : url.pathExtension)
    }

    var kind: FileKind? { resolvedContentType.flatMap(FileRules.kind(forContentType:)) }
}

/// A picked file with its small copy made and its facts read, ready to reserve and send.
struct PreparedFile: Equatable {
    var name: String
    var kind: FileKind
    var contentType: String
    var originalURL: URL
    var previewURL: URL
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var originalBytes: Int64
    var previewBytes: Int64
}

/// Reads a picked file and makes its small copy. The real one uses ImageIO and AVFoundation (`PreviewMaker`); tests use a
/// stand-in.
protocol FilePreparing: Sendable {
    func prepare(_ pick: PickedFile, kind: FileKind, style: PreviewStyle) async throws -> PreparedFile
}

/// Opening and saving the client's files: fetching the bytes, and putting them in Photos.
protocol FileTransferring: Sendable {
    /// Fetches the file to a place the app owns, named `name`. `progress` runs from 0 to 1.
    func download(_ source: FileSource, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func saveToPhotos(_ url: URL, kind: FileKind) async throws
}

/// One file on its way, as the creator sees it in the list above the grid.
struct FileUploadItem: Identifiable, Equatable {
    enum Stage: Equatable {
        /// Reading the file and making its small copy.
        case preparing
        /// Sending: 0 to 1.
        case sending(Double)
        /// Sent; the backend is checking what arrived.
        case finishing
        /// It stopped, and why. The person can try again or dismiss it.
        case failed(String)
    }

    var id: UUID
    var bookingID: UUID
    var name: String
    var kind: FileKind?
    var stage: Stage

    var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = stage { return message }
        return nil
    }

    /// For the bar, 0 to 1.
    var fraction: Double {
        switch stage {
        case .preparing: 0
        case .sending(let value): min(1, max(0, value))
        case .finishing: 1
        case .failed: 0
        }
    }

    var statusText: String {
        switch stage {
        case .preparing: "Getting ready…"
        case .sending(let value): "Sending \(Int((min(1, max(0, value)) * 100).rounded()))%"
        case .finishing: "Checking…"
        case .failed(let message): message
        }
    }
}

/// Saving a delivery's originals to the client's phone, one after another.
struct FileSaveRun: Equatable {
    var deliveryID: UUID
    var done: Int
    var total: Int
    var currentName: String?
    /// 0 to 1 for the file being fetched now.
    var currentFraction: Double
    var isCancelled = false

    var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, (Double(done) + currentFraction) / Double(total))
    }
}

enum FileNames {
    /// The content type a file ending stands for, for the types Slate Pro takes.
    static func contentType(forExtension ending: String) -> String? {
        switch ending.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        case "mp4": "video/mp4"
        case "m4v": "video/x-m4v"
        case "mov": "video/quicktime"
        default: nil
        }
    }

    /// The extension a content type is saved with, so a file opens in the right app.
    static func fileExtension(forContentType type: String) -> String {
        switch type.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/tiff": "tiff"
        case "image/webp": "webp"
        case "video/mp4": "mp4"
        case "video/x-m4v": "m4v"
        default: "mov"
        }
    }

    /// A name safe to use as a file name, ending in the right extension.
    static func saveName(for file: DeliveryFile) -> String {
        let ext = fileExtension(forContentType: file.contentType)
        let base = FileRules.cleanName(file.name)
        if base.lowercased().hasSuffix(".\(ext)") { return base }
        // IMG_0042.HEIC for a heic keeps its name; anything else gets the right ending.
        let stem = (base as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "File" : stem).\(ext)"
    }
}

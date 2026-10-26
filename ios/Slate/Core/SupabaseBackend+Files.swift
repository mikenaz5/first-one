import Foundation
import Supabase

/// Slate Files on Supabase.
///
/// Rules and permissions live in the database (`…_slate_files.sql`): the app asks `files_reserve` whether a file fits and
/// where it goes, sends the bytes straight to the private `deliveries` bucket, then asks `files_finalize` to check what
/// really arrived. Who can open which bytes is decided by the bucket's policies when a link is made, so a link for a
/// locked original can't be made at all. Reading is `list_booking_files`, which leaves out the original's path while it is
/// locked. Nothing in this file decides who may do what.
extension SupabaseBackend {
    // MARK: - Rows

    struct FilesConfigRow: Decodable {
        var retentionDays: Int
        var draftDays: Int
        var warnDays: [Int]
        var quotaGbIndividual: Int
        var quotaGbPerSeat: Int
        var maxPhotoMb: Int
        var maxVideoGb: Int
        var maxFiles: Int
        var previewPhotoMaxMb: Int
        var previewVideoMaxMb: Int
        var urlMinutes: Int
        var reservationHours: Int

        enum CodingKeys: String, CodingKey {
            case retentionDays = "retention_days"
            case draftDays = "draft_days"
            case warnDays = "warn_days"
            case quotaGbIndividual = "quota_gb_individual"
            case quotaGbPerSeat = "quota_gb_per_seat"
            case maxPhotoMb = "max_photo_mb"
            case maxVideoGb = "max_video_gb"
            case maxFiles = "max_files"
            case previewPhotoMaxMb = "preview_photo_max_mb"
            case previewVideoMaxMb = "preview_video_max_mb"
            case urlMinutes = "url_minutes"
            case reservationHours = "reservation_hours"
        }

        var config: FilesConfig {
            FilesConfig(
                retentionDays: retentionDays, draftDays: draftDays, warnDays: warnDays, quotaGBIndividual: quotaGbIndividual,
                quotaGBPerSeat: quotaGbPerSeat, maxPhotoMB: maxPhotoMb, maxVideoGB: maxVideoGb, maxFiles: maxFiles,
                previewPhotoMaxMB: previewPhotoMaxMb, previewVideoMaxMB: previewVideoMaxMb, urlMinutes: urlMinutes,
                reservationHours: reservationHours
            )
        }
    }

    /// One file in `list_booking_files()`.
    struct DeliveryFileRow: Decodable {
        var id: String
        var kind: String
        var name: String
        var contentType: String
        var width: Int?
        var height: Int?
        var durationSeconds: Double?
        var originalBytes: Int64
        var previewBytes: Int64
        var status: String
        var savedAt: Date?
        var createdAt: Date
        var position: Int
        var previewPath: String
        var originalPath: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, name, width, height, status, position
            case contentType = "content_type"
            case durationSeconds = "duration_seconds"
            case originalBytes = "original_bytes"
            case previewBytes = "preview_bytes"
            case savedAt = "saved_at"
            case createdAt = "created_at"
            case previewPath = "preview_path"
            case originalPath = "original_path"
        }

        func file() throws -> DeliveryFile {
            guard let id = UUID(uuidString: id), let kind = FileKind(rawValue: kind), let status = FileStatus(rawValue: status) else {
                throw SlateError.backend("A file came back in a form this version can't read.")
            }
            return DeliveryFile(
                id: id, kind: kind, name: name, contentType: contentType, width: width, height: height, durationSeconds: durationSeconds,
                originalBytes: originalBytes, previewBytes: previewBytes, status: status, savedAt: savedAt, createdAt: createdAt,
                position: position, previewPath: previewPath, originalPath: originalPath
            )
        }
    }

    struct FileDeliveryRow: Decodable {
        var id: String
        var bookingId: String
        var kind: String
        var sequence: Int
        var title: String
        var note: String
        var state: String
        var createdAt: Date
        var deliveredAt: Date?
        var expiresAt: Date?
        var originalsOpen: Bool
        var files: [DeliveryFileRow]

        enum CodingKeys: String, CodingKey {
            case id, kind, sequence, title, note, state, files
            case bookingId = "booking_id"
            case createdAt = "created_at"
            case deliveredAt = "delivered_at"
            case expiresAt = "expires_at"
            case originalsOpen = "originals_open"
        }

        func delivery() throws -> FileDelivery {
            guard let id = UUID(uuidString: id), let bookingID = UUID(uuidString: bookingId),
                  let kind = DeliveryKind(rawValue: kind), let state = DeliveryState(rawValue: state)
            else { throw SlateError.backend("A delivery came back in a form this version can't read.") }
            return FileDelivery(
                id: id, bookingID: bookingID, kind: kind, sequence: sequence, title: title, note: note, state: state, createdAt: createdAt,
                deliveredAt: deliveredAt, expiresAt: expiresAt, originalsOpen: originalsOpen, files: try files.map { try $0.file() }
            )
        }
    }

    /// What `list_booking_files()` and `files_deliver()` answer.
    struct BookingFilesRow: Decodable {
        var bookingId: String
        var owedCents: Int
        var deliveries: [FileDeliveryRow]
        var usedBytes: Int64?
        var allowanceBytes: Int64?
        var canDeliverFiles: Bool
        var canSendRevision: Bool

        enum CodingKeys: String, CodingKey {
            case deliveries
            case bookingId = "booking_id"
            case owedCents = "owed_cents"
            case usedBytes = "used_bytes"
            case allowanceBytes = "allowance_bytes"
            case canDeliverFiles = "can_deliver_files"
            case canSendRevision = "can_send_revision"
        }

        func files() throws -> BookingFiles {
            guard let bookingID = UUID(uuidString: bookingId) else { throw SlateError.backend("Malformed booking id.") }
            return BookingFiles(
                bookingID: bookingID, owedCents: owedCents, deliveries: try deliveries.map { try $0.delivery() },
                usedBytes: usedBytes, allowanceBytes: allowanceBytes, canDeliverFiles: canDeliverFiles, canSendRevision: canSendRevision
            )
        }
    }

    /// What `files_reserve()` answers.
    struct FileReservationRow: Decodable {
        var fileId: String
        var deliveryId: String
        var deliveryKind: String
        var originalPath: String
        var previewPath: String

        enum CodingKeys: String, CodingKey {
            case fileId = "file_id"
            case deliveryId = "delivery_id"
            case deliveryKind = "delivery_kind"
            case originalPath = "original_path"
            case previewPath = "preview_path"
        }

        func reservation() throws -> FileReservation {
            guard let fileID = UUID(uuidString: fileId), let deliveryID = UUID(uuidString: deliveryId), let kind = DeliveryKind(rawValue: deliveryKind) else {
                throw SlateError.backend("A reservation came back in a form this version can't read.")
            }
            return FileReservation(fileID: fileID, deliveryID: deliveryID, deliveryKind: kind, originalPath: originalPath, previewPath: previewPath)
        }
    }

    /// What `files_finalize()` answers. A refusal is an answer, not an error, so that the removal it makes sticks.
    struct FileFinalizationRow: Decodable {
        var accepted: Bool
        var refusal: String?
        var kind: String?
    }

    struct FileSaveCountRow: Decodable {
        var saved: Int
        var total: Int
    }

    struct FileUsageRow: Decodable {
        var usedBytes: Int64
        var allowanceBytes: Int64

        enum CodingKeys: String, CodingKey {
            case usedBytes = "used_bytes"
            case allowanceBytes = "allowance_bytes"
        }
    }

    // MARK: - Parameters

    private struct FilesBookingParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct FilesReserveParams: Encodable {
        var pBookingId: String
        var pKind: String
        var pName: String
        var pContentType: String
        var pWidth: Int?
        var pHeight: Int?
        var pDuration: Double?
        var pOriginalBytes: Int64
        var pPreviewBytes: Int64

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pKind = "p_kind"
            case pName = "p_name"
            case pContentType = "p_content_type"
            case pWidth = "p_width"
            case pHeight = "p_height"
            case pDuration = "p_duration"
            case pOriginalBytes = "p_original_bytes"
            case pPreviewBytes = "p_preview_bytes"
        }

        /// A missing size is sent as null, not left out: the database function has no defaults to fall back on.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pBookingId, forKey: .pBookingId)
            try container.encode(pKind, forKey: .pKind)
            try container.encode(pName, forKey: .pName)
            try container.encode(pContentType, forKey: .pContentType)
            try container.encode(pWidth, forKey: .pWidth)
            try container.encode(pHeight, forKey: .pHeight)
            try container.encode(pDuration, forKey: .pDuration)
            try container.encode(pOriginalBytes, forKey: .pOriginalBytes)
            try container.encode(pPreviewBytes, forKey: .pPreviewBytes)
        }
    }

    private struct FileIDParams: Encodable {
        var pFileId: String

        enum CodingKeys: String, CodingKey { case pFileId = "p_file_id" }
    }

    private struct FileReportParams: Encodable {
        var pFileId: String
        var pReason: String

        enum CodingKeys: String, CodingKey {
            case pFileId = "p_file_id"
            case pReason = "p_reason"
        }
    }

    private struct DeliverParams: Encodable {
        var pBookingId: String
        var pTitle: String?
        var pNote: String?

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pTitle = "p_title"
            case pNote = "p_note"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pBookingId, forKey: .pBookingId)
            try container.encode(pTitle, forKey: .pTitle)
            try container.encode(pNote, forKey: .pNote)
        }
    }

    private struct UsageParams: Encodable {
        var pOwner: String

        enum CodingKeys: String, CodingKey { case pOwner = "p_owner" }
    }

    // MARK: - Reading

    func loadFilesConfig() async throws -> FilesConfig {
        do {
            let row: FilesConfigRow = try await client.rpc("files_config").execute().value
            filesConfig = row.config
            return row.config
        } catch {
            throw Self.mapFileError(error)
        }
    }

    func loadBookingFiles(bookingID: UUID, for userID: UUID) async throws -> BookingFiles {
        do {
            let row: BookingFilesRow = try await client
                .rpc("list_booking_files", params: FilesBookingParams(pBookingId: Self.key(bookingID)))
                .execute()
                .value
            return try row.files()
        } catch {
            throw Self.mapFileError(error)
        }
    }

    func fileStorageMeter(owner: UUID, for userID: UUID) async throws -> StorageMeter {
        do {
            let row: FileUsageRow = try await client.rpc("files_storage_usage", params: UsageParams(pOwner: Self.key(owner))).execute().value
            return StorageMeter(usedBytes: row.usedBytes, allowanceBytes: row.allowanceBytes)
        } catch {
            throw Self.mapFileError(error)
        }
    }

    // MARK: - Adding files

    func reserveFile(_ request: FileUploadRequest, by userID: UUID) async throws -> FileReservation {
        let params = FilesReserveParams(
            pBookingId: Self.key(request.bookingID), pKind: request.kind.rawValue, pName: request.name, pContentType: request.contentType,
            pWidth: request.width, pHeight: request.height, pDuration: request.durationSeconds,
            pOriginalBytes: request.originalBytes, pPreviewBytes: request.previewBytes
        )
        do {
            let row: FileReservationRow = try await client.rpc("files_reserve", params: params).execute().value
            return try row.reservation()
        } catch {
            var mapped = Self.mapFileError(error, kind: request.kind, config: filesConfig)
            // "Storage is full" reads better with the figures, which the database will give the creator side.
            if let slate = mapped as? SlateError, case .fileRefused(.storageFull) = slate,
               let files = try? await loadBookingFiles(bookingID: request.bookingID, for: userID) {
                mapped = SlateError.fileRefused(.storageFull(usedBytes: files.usedBytes ?? 0, allowanceBytes: files.allowanceBytes ?? 0))
            }
            throw mapped
        }
    }

    func uploadFile(
        _ reservation: FileReservation, from source: FileUploadSource, by userID: UUID, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0)
        // The preview is small and quick; the original is where the time goes, so it gets most of the bar.
        try await putObject(at: reservation.previewPath, from: source.preview, contentType: Self.contentType(forFileAt: source.preview)) { progress(0.05 * $0) }
        let originalType = Self.contentType(forFileAt: source.original)
        try await putObject(at: reservation.originalPath, from: source.original, contentType: originalType) { progress(0.05 + 0.95 * $0) }
        progress(1)
    }

    func finishFile(_ fileID: UUID, by userID: UUID) async throws -> FileFinalization {
        do {
            let row: FileFinalizationRow = try await client.rpc("files_finalize", params: FileIDParams(pFileId: Self.key(fileID))).execute().value
            if row.accepted { return .accepted }
            let kind = row.kind.flatMap(FileKind.init(rawValue:)) ?? .photo
            if let refusal = row.refusal.flatMap({ Self.refusal(forToken: $0, kind: kind, config: filesConfig) }) { return .refused(refusal) }
            throw SlateError.backend("The file was turned away for a reason this version doesn't know.")
        } catch {
            throw Self.mapFileError(error)
        }
    }

    // MARK: - Delivering and removing

    func deliverFiles(bookingID: UUID, title: String?, note: String?, by userID: UUID) async throws -> BookingFiles {
        do {
            let row: BookingFilesRow = try await client
                .rpc("files_deliver", params: DeliverParams(pBookingId: Self.key(bookingID), pTitle: title, pNote: note))
                .execute()
                .value
            return try row.files()
        } catch {
            throw Self.mapFileError(error)
        }
    }

    func removeFile(_ fileID: UUID, by userID: UUID) async throws {
        do {
            try await client.rpc("files_remove", params: FileIDParams(pFileId: Self.key(fileID))).execute()
        } catch {
            throw Self.mapFileError(error)
        }
    }

    // MARK: - The client

    func markFileSaved(_ fileID: UUID, by userID: UUID) async throws -> FileSaveCount {
        do {
            let row: FileSaveCountRow = try await client.rpc("files_mark_saved", params: FileIDParams(pFileId: Self.key(fileID))).execute().value
            return FileSaveCount(saved: row.saved, total: row.total)
        } catch {
            throw Self.mapFileError(error)
        }
    }

    func reportFile(_ fileID: UUID, reason: String, by userID: UUID) async throws {
        do {
            try await client.rpc("files_report", params: FileReportParams(pFileId: Self.key(fileID), pReason: reason)).execute()
        } catch {
            throw Self.mapFileError(error)
        }
    }

    // MARK: - Opening

    func fileSource(for file: DeliveryFile, part: FileRules.Part, bookingID: UUID, for userID: UUID) async throws -> FileSource {
        guard let path = part == .preview ? file.previewPath : file.originalPath else { throw SlateError.originalsLocked }
        do {
            // Storage checks the bucket's policy as this person when it signs, so a locked original can't be signed for.
            let url = try await client.storage.from("deliveries").createSignedURL(path: path, expiresIn: max(60, filesConfig.urlMinutes * 60))
            return FileSource(url: url, isRemote: true)
        } catch {
            if error is URLError { throw error }
            throw part == .original ? SlateError.originalsLocked : SlateError.fileUnavailable
        }
    }

    // MARK: - Sending bytes

    /// Puts one file into the private bucket as the signed-in person, with progress. The SDK's upload can't report progress,
    /// and a video can be a few gigabytes, so this is a plain request. Storage's policy (`files_may_store`) is what allows it.
    private func putObject(at path: String, from file: URL, contentType: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = try await client.auth.session
        // Paths are lowercase ids and "original" or "preview", so there is nothing in them to escape.
        let url = projectURL.appendingPathComponent("storage/v1/object/deliveries/\(path)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.setValue("private, max-age=0", forHTTPHeaderField: "cache-control")

        let delegate = UploadProgress(progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw SlateError.uploadIncomplete }
        guard (200..<300).contains(http.statusCode) else {
            // Storage's own words (for example that the project's file size limit is lower than this file).
            let message = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 413 || message.contains("exceeded the maximum allowed size") {
                throw SlateError.backend("Your Supabase project doesn't allow files this big yet. Raise its file size limit in the Storage settings.")
            }
            throw SlateError.uploadIncomplete
        }
        progress(1)
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate {
        private let report: @Sendable (Double) -> Void

        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }

    /// The content type to send an original as: from its extension, since the bucket accepts only photo and video types.
    static func contentType(forFileAt url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "webp": "image/webp"
        case "mp4": "video/mp4"
        case "m4v": "video/x-m4v"
        default: "video/quicktime"
        }
    }

    // MARK: - Errors

    /// What a refusal token means, for a file of this kind.
    static func refusal(forToken token: String, kind: FileKind, config: FilesConfig) -> FileRefusal? {
        switch token {
        case "too_many_files": .tooManyFiles
        case "file_empty": .empty
        case "file_too_large": .tooLarge(maxBytes: FileRules.maxOriginalBytes(kind, config: config))
        case "preview_too_large": .previewTooLarge(maxBytes: FileRules.maxPreviewBytes(kind, config: config))
        case "storage_full": .storageFull(usedBytes: 0, allowanceBytes: 0)
        default: nil
        }
    }

    /// The files functions raise plain tokens such as `storage_full`. Theirs are checked first, because a few (`not_found`)
    /// are shared with bookings and others contain words the booking mapper looks for.
    static func mapFileError(_ error: Error, kind: FileKind = .photo, config: FilesConfig = .standard) -> Error {
        let text = "\(error)"
        let known: [(token: String, error: SlateError)] = [
            ("files_not_allowed", .filesNotAllowed),
            ("unsupported_type", .unsupportedFileType),
            ("delivery_locked", .firstDeliveryLocked),
            ("revision_not_allowed", .revisionNotAllowed),
            ("upload_incomplete", .uploadIncomplete),
            ("nothing_to_deliver", .nothingToDeliver),
            ("files_not_ready", .filesNotReady),
            ("originals_locked", .originalsLocked),
            ("title_too_long", .fileTitleTooLong),
        ]
        for entry in known where text.contains(entry.token) {
            return entry.error
        }
        for token in ["too_many_files", "file_empty", "file_too_large", "preview_too_large", "storage_full"] where text.contains(token) {
            if let refusal = refusal(forToken: token, kind: kind, config: config) { return SlateError.fileRefused(refusal) }
        }
        return mapBookingError(error)
    }
}

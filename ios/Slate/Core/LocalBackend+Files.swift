import Foundation

/// Slate Files for the on-device backend: the same flow with no server. The bytes are copied into the app's own folder
/// (a file system clone, so a big video costs no extra space), and the same rules decide who can open what. It follows
/// the `files_*` functions in `…_slate_files.sql` rule for rule (same checks, in the same order, with the same errors),
/// and writes the same lines into the conversation that the database's triggers write.
///
/// What it doesn't do: send notifications. With no server there is nothing to send a push, so the reminders that files
/// are about to be deleted exist only with a server.
extension LocalBackend {
    // MARK: - Stored shapes

    struct StoredDelivery: Codable, Equatable {
        var id: UUID
        var bookingID: UUID
        var ownerID: UUID
        var kind: DeliveryKind
        var sequence: Int
        var title: String
        var note: String
        var state: DeliveryState
        var createdAt: Date
        var deliveredAt: Date?
        var expiresAt: Date?
        var expiredAt: Date?
    }

    struct StoredFile: Codable, Equatable {
        /// The paths in it are where the bytes live under `deliveredFilesDirectory`, as on the server.
        var file: DeliveryFile
        var deliveryID: UUID
        var bookingID: UUID
        var ownerID: UUID
    }

    struct StoredFileReport: Codable, Equatable {
        var id: UUID
        var fileID: UUID
        var reporterID: UUID
        var reason: String
        var createdAt: Date
    }

    private var deliveriesURL: URL { root.appendingPathComponent("file_deliveries.json") }
    private var deliveryFilesURL: URL { root.appendingPathComponent("file_items.json") }
    private var fileReportsURL: URL { root.appendingPathComponent("file_reports.json") }
    private var deliveredFilesDirectory: URL { root.appendingPathComponent("delivered_files", isDirectory: true) }

    func readDeliveries() -> [StoredDelivery] {
        read([StoredDelivery].self, from: deliveriesURL) ?? []
    }

    func readDeliveryFiles() -> [StoredFile] {
        read([StoredFile].self, from: deliveryFilesURL) ?? []
    }

    /// Stored dates are whole seconds, so use whole seconds: what this returns then equals what is read back later.
    private var filesNow: Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    private func objectURL(_ path: String) -> URL {
        deliveredFilesDirectory.appendingPathComponent(path)
    }

    private func byteCount(at url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func deleteBytes(of stored: StoredFile) {
        try? fileManager.removeItem(at: objectURL(stored.file.previewPath))
        if let original = stored.file.originalPath { try? fileManager.removeItem(at: objectURL(original)) }
    }

    // MARK: - Figures

    /// What the client still owes on a booking: the total less what has been paid.
    private func owedCents(_ booking: Booking, payments: [Payment]) -> Int {
        let paid = payments
            .filter { $0.bookingID == booking.id && ($0.kind == .deposit || $0.kind == .balance) && $0.status == .succeeded }
            .reduce(0) { $0 + $1.amountCents }
        return max(0, booking.totalCents - paid)
    }

    private func balancePaid(_ booking: Booking, payments: [Payment]) -> Bool {
        payments.contains { $0.bookingID == booking.id && $0.kind == .balance && $0.status == .succeeded }
    }

    private func usedBytes(_ owner: UUID, files: [StoredFile]) -> Int64 {
        files
            .filter { $0.ownerID == owner && ($0.file.status == .uploading || $0.file.status == .ready) }
            .reduce(0) { $0 + $1.file.originalBytes + $1.file.previewBytes }
    }

    /// A person's own allowance, or a company's: per billed seat, shared by everyone in it.
    private func allowanceBytes(_ owner: UUID) -> Int64 {
        if let org = readOrganization(owner) {
            let seats = max(teamConfig.seatMinimum, activeMembers(org).count)
            return FileRules.allowanceBytes(individual: false, billedSeats: seats, config: filesConfig)
        }
        return FileRules.allowanceBytes(individual: true, billedSeats: 0, config: filesConfig)
    }

    private func isLive(_ status: FileStatus) -> Bool { status == .uploading || status == .ready }

    // MARK: - Time passing

    /// The twin of `files_expire_due()`: ends deliveries whose time is up (their files are deleted), tidies drafts nobody
    /// delivered and uploads that never finished. Safe to run any number of times; every files call begins with it.
    func expireLapsedFiles() throws {
        let now = filesNow
        var deliveries = readDeliveries()
        var files = readDeliveryFiles()
        guard !deliveries.isEmpty || !files.isEmpty else { return }
        var changed = false

        for index in deliveries.indices where deliveries[index].state == .delivered && (deliveries[index].expiresAt.map { $0 <= now } ?? false) {
            deliveries[index].state = .expired
            deliveries[index].expiredAt = now
            var total = 0
            var saved = 0
            for fileIndex in files.indices where files[fileIndex].deliveryID == deliveries[index].id && files[fileIndex].file.status == .ready {
                files[fileIndex].file.status = .expired
                deleteBytes(of: files[fileIndex])
                total += 1
                if files[fileIndex].file.savedAt != nil { saved += 1 }
            }
            try? appendSystemMessage(
                .filesExpired, bookingID: deliveries[index].bookingID,
                data: MessageEventData(revised: deliveries[index].kind == .revision, title: deliveries[index].title, saved: saved, total: total), at: now
            )
            changed = true
        }

        // A draft nobody delivered within the time goes, files and all.
        let draftCutoff = now.addingTimeInterval(-TimeInterval(filesConfig.draftDays) * 86_400)
        let staleDrafts = Set(deliveries.filter { $0.state == .draft && $0.createdAt < draftCutoff }.map(\.id))
        if !staleDrafts.isEmpty {
            for stored in files where staleDrafts.contains(stored.deliveryID) { deleteBytes(of: stored) }
            files.removeAll { staleDrafts.contains($0.deliveryID) }
            deliveries.removeAll { staleDrafts.contains($0.id) }
            changed = true
        }

        // An upload that never finished gives its space back.
        let uploadCutoff = now.addingTimeInterval(-TimeInterval(filesConfig.reservationHours) * 3_600)
        for index in files.indices where files[index].file.status == .uploading && files[index].file.createdAt < uploadCutoff {
            files[index].file.status = .removed
            deleteBytes(of: files[index])
            changed = true
        }

        if changed {
            try write(deliveries, to: deliveriesURL)
            try write(files, to: deliveryFilesURL)
        }
    }

    // MARK: - Reading

    func loadFilesConfig() async throws -> FilesConfig { filesConfig }

    func loadBookingFiles(bookingID: UUID, for userID: UUID) async throws -> BookingFiles {
        try expireLapsedFiles()
        guard let booking = readBookings().first(where: { $0.id == bookingID }) else { throw SlateError.bookingNotFound }
        let provider = providerAccess(userID, booking, .manage)
        guard provider || booking.clientID == userID else { throw SlateError.bookingNotFound }
        return listing(booking, provider: provider)
    }

    /// The twin of `list_booking_files()`.
    private func listing(_ booking: Booking, provider: Bool) -> BookingFiles {
        let now = filesNow
        let payments = readPayments()
        let owed = owedCents(booking, payments: payments)
        let allDeliveries = readDeliveries().filter { $0.bookingID == booking.id }
        let allFiles = readDeliveryFiles()
        let first = allDeliveries.first { $0.sequence == 0 }
        let viewer: FileRules.Viewer = provider ? .provider : .client
        let canAct = provider && (booking.status == .confirmed || booking.status == .completed) && booking.startAt <= now

        let deliveries: [FileDelivery] = allDeliveries
            .filter { provider || $0.state != .draft }
            .sorted { $0.sequence < $1.sequence }
            .map { delivery in
                let open = FileRules.canOpen(
                    .original, as: viewer, kind: delivery.kind, state: delivery.state, expiresAt: delivery.expiresAt, owedCents: owed, now: now
                )
                let rows = allFiles
                    .filter { $0.deliveryID == delivery.id }
                    .filter { stored in
                        switch stored.file.status {
                        case .ready, .expired: true
                        case .uploading: provider
                        case .removed: false
                        }
                    }
                    .sorted { ($0.file.position, $0.file.createdAt) < ($1.file.position, $1.file.createdAt) }
                    .map { stored -> DeliveryFile in
                        var file = stored.file
                        if !open { file.originalPath = nil }
                        return file
                    }
                return FileDelivery(
                    id: delivery.id, bookingID: delivery.bookingID, kind: delivery.kind, sequence: delivery.sequence, title: delivery.title,
                    note: delivery.note, state: delivery.state, createdAt: delivery.createdAt, deliveredAt: delivery.deliveredAt,
                    expiresAt: delivery.expiresAt, originalsOpen: open, files: rows
                )
            }

        let locked = FileRules.firstDeliveryLocked(
            hasFilesDelivery: false, linkDelivered: booking.deliveryURL != nil || booking.receiptConfirmedAt != nil,
            balancePaid: balancePaid(booking, payments: payments)
        )
        return BookingFiles(
            bookingID: booking.id, owedCents: owed, deliveries: deliveries,
            usedBytes: provider ? usedBytes(booking.creatorID, files: allFiles) : nil,
            allowanceBytes: provider ? allowanceBytes(booking.creatorID) : nil,
            canDeliverFiles: canAct && (first == nil || first?.state == .draft) && !locked,
            canSendRevision: canAct && FileRules.revisionAllowed(firstState: first?.state, owedCents: owed)
        )
    }

    func fileStorageMeter(owner: UUID, for userID: UUID) async throws -> StorageMeter {
        try expireLapsedFiles()
        if owner != userID {
            guard let org = readOrganization(owner), permits(org, userID, .teamView) else { throw SlateError.notFound }
        }
        return StorageMeter(usedBytes: usedBytes(owner, files: readDeliveryFiles()), allowanceBytes: allowanceBytes(owner))
    }

    // MARK: - Adding files

    func reserveFile(_ request: FileUploadRequest, by userID: UUID) async throws -> FileReservation {
        try expireLapsedFiles()
        let now = filesNow
        guard let booking = readBookings().first(where: { $0.id == request.bookingID }), providerAccess(userID, booking, .manage) else {
            throw SlateError.bookingNotFound
        }
        guard booking.status == .confirmed || booking.status == .completed, booking.startAt <= now else { throw SlateError.filesNotAllowed }
        guard FileRules.kind(forContentType: request.contentType) == request.kind else { throw SlateError.unsupportedFileType }

        let payments = readPayments()
        var deliveries = readDeliveries()
        var files = readDeliveryFiles()
        let owed = owedCents(booking, payments: payments)
        let first = deliveries.first { $0.bookingID == booking.id && $0.sequence == 0 }

        let kind: DeliveryKind
        if first == nil || first?.state == .draft {
            kind = .delivery
            let locked = FileRules.firstDeliveryLocked(
                hasFilesDelivery: false, linkDelivered: booking.deliveryURL != nil || booking.receiptConfirmedAt != nil,
                balancePaid: balancePaid(booking, payments: payments)
            )
            if locked { throw SlateError.firstDeliveryLocked }
        } else {
            kind = .revision
            guard FileRules.revisionAllowed(firstState: first?.state, owedCents: owed) else { throw SlateError.revisionNotAllowed }
        }

        let draftID = deliveries.first { $0.bookingID == booking.id && $0.state == .draft }?.id
        let inDraft = draftID.map { id in files.filter { $0.deliveryID == id && isLive($0.file.status) }.count } ?? 0
        let used = usedBytes(booking.creatorID, files: files)
        let allowance = allowanceBytes(booking.creatorID)
        if let refusal = FileRules.refusal(
            kind: request.kind, originalBytes: request.originalBytes, previewBytes: request.previewBytes, filesInDelivery: inDraft,
            usedBytes: used, allowanceBytes: allowance, config: filesConfig
        ) {
            throw SlateError.fileRefused(refusal)
        }

        let deliveryID: UUID
        let deliveryKind: DeliveryKind
        if let draftID, let draft = deliveries.first(where: { $0.id == draftID }) {
            deliveryID = draftID
            deliveryKind = draft.kind
        } else {
            let sequence = kind == .delivery ? 0 : (deliveries.filter { $0.bookingID == booking.id }.map(\.sequence).max() ?? 0) + 1
            let created = StoredDelivery(
                id: UUID(), bookingID: booking.id, ownerID: booking.creatorID, kind: kind, sequence: sequence, title: "", note: "",
                state: .draft, createdAt: now, deliveredAt: nil, expiresAt: nil, expiredAt: nil
            )
            deliveries.append(created)
            deliveryID = created.id
            deliveryKind = kind
        }

        let fileID = UUID()
        let base = "\(booking.creatorID.uuidString.lowercased())/\(booking.id.uuidString.lowercased())/\(fileID.uuidString.lowercased())"
        let position = (files.filter { $0.deliveryID == deliveryID }.map(\.file.position).max()).map { $0 + 1 } ?? 0
        let file = DeliveryFile(
            id: fileID, kind: request.kind, name: FileRules.cleanName(request.name), contentType: request.contentType.lowercased(),
            width: request.width, height: request.height, durationSeconds: request.durationSeconds,
            originalBytes: request.originalBytes, previewBytes: request.previewBytes, status: .uploading, savedAt: nil,
            createdAt: now, position: position, previewPath: "\(base)/preview", originalPath: "\(base)/original"
        )
        files.append(StoredFile(file: file, deliveryID: deliveryID, bookingID: booking.id, ownerID: booking.creatorID))
        try write(deliveries, to: deliveriesURL)
        try write(files, to: deliveryFilesURL)
        return FileReservation(
            fileID: fileID, deliveryID: deliveryID, deliveryKind: deliveryKind,
            originalPath: "\(base)/original", previewPath: "\(base)/preview"
        )
    }

    func uploadFile(
        _ reservation: FileReservation, from source: FileUploadSource, by userID: UUID, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let stored = readDeliveryFiles().first(where: { $0.file.id == reservation.fileID }), stored.file.status == .uploading,
              let booking = readBookings().first(where: { $0.id == stored.bookingID }), providerAccess(userID, booking, .manage),
              let original = stored.file.originalPath
        else { throw SlateError.bookingNotFound }
        progress(0)
        try copyReplacing(source.original, to: objectURL(original))
        progress(0.9)
        try copyReplacing(source.preview, to: objectURL(stored.file.previewPath))
        progress(1)
    }

    func finishFile(_ fileID: UUID, by userID: UUID) async throws -> FileFinalization {
        try expireLapsedFiles()
        var files = readDeliveryFiles()
        guard let index = files.firstIndex(where: { $0.file.id == fileID }),
              let booking = readBookings().first(where: { $0.id == files[index].bookingID }), providerAccess(userID, booking, .manage)
        else { throw SlateError.bookingNotFound }
        if files[index].file.status == .ready { return .accepted }
        guard files[index].file.status == .uploading, let originalPath = files[index].file.originalPath else { throw SlateError.bookingNotFound }

        let original = byteCount(at: objectURL(originalPath))
        let preview = byteCount(at: objectURL(files[index].file.previewPath))
        guard original > 0, preview > 0 else { throw SlateError.uploadIncomplete }

        let kind = files[index].file.kind
        var refusal: FileRefusal?
        if original > files[index].file.originalBytes {
            refusal = .tooLarge(maxBytes: FileRules.maxOriginalBytes(kind, config: filesConfig))
        } else if preview > files[index].file.previewBytes || preview > FileRules.maxPreviewBytes(kind, config: filesConfig) {
            refusal = .previewTooLarge(maxBytes: FileRules.maxPreviewBytes(kind, config: filesConfig))
        }
        if let refusal {
            files[index].file.status = .removed
            deleteBytes(of: files[index])
            try write(files, to: deliveryFilesURL)
            return .refused(refusal)
        }
        files[index].file.originalBytes = original
        files[index].file.previewBytes = preview
        files[index].file.status = .ready
        try write(files, to: deliveryFilesURL)
        return .accepted
    }

    // MARK: - Delivering

    func deliverFiles(bookingID: UUID, title: String?, note: String?, by userID: UUID) async throws -> BookingFiles {
        try expireLapsedFiles()
        let now = filesNow
        var bookings = readBookings()
        guard let bookingIndex = bookings.firstIndex(where: { $0.id == bookingID }), providerAccess(userID, bookings[bookingIndex], .manage) else {
            throw SlateError.bookingNotFound
        }
        let booking = bookings[bookingIndex]
        guard booking.status == .confirmed || booking.status == .completed else { throw SlateError.filesNotAllowed }

        var deliveries = readDeliveries()
        let files = readDeliveryFiles()
        guard let draftIndex = deliveries.firstIndex(where: { $0.bookingID == bookingID && $0.state == .draft }) else {
            throw SlateError.nothingToDeliver
        }
        let draft = deliveries[draftIndex]
        let mine = files.filter { $0.deliveryID == draft.id }
        if mine.contains(where: { $0.file.status == .uploading }) { throw SlateError.filesNotReady }
        let ready = mine.filter { $0.file.status == .ready }
        if ready.isEmpty { throw SlateError.nothingToDeliver }

        let rawNote = note ?? ""
        if DeliveryRules.noteIsTooLong(rawNote) { throw SlateError.deliveryNoteTooLong }
        let cleanNote = DeliveryRules.cleanNote(rawNote) ?? ""

        let payments = readPayments()
        var finalTitle = ""
        if draft.kind == .delivery {
            let locked = FileRules.firstDeliveryLocked(
                hasFilesDelivery: false, linkDelivered: booking.deliveryURL != nil || booking.receiptConfirmedAt != nil,
                balancePaid: balancePaid(booking, payments: payments)
            )
            if locked { throw SlateError.firstDeliveryLocked }
        } else {
            let first = deliveries.first { $0.bookingID == bookingID && $0.sequence == 0 }
            guard FileRules.revisionAllowed(firstState: first?.state, owedCents: owedCents(booking, payments: payments)) else {
                throw SlateError.revisionNotAllowed
            }
            let cleanTitle = MessageRules.clean(title ?? "")
            if MessageRules.length(of: cleanTitle) > 80 { throw SlateError.fileTitleTooLong }
            finalTitle = cleanTitle.isEmpty ? FileRules.revisionTitle(sequence: draft.sequence) : cleanTitle
        }

        deliveries[draftIndex].state = .delivered
        deliveries[draftIndex].deliveredAt = now
        deliveries[draftIndex].expiresAt = FileRules.expiresAt(deliveredAt: now, config: filesConfig)
        deliveries[draftIndex].title = finalTitle
        deliveries[draftIndex].note = cleanNote

        var completed = false
        if draft.kind == .delivery {
            // A hosted delivery has no confirm step: the previews are how the client checks the work. So the booking is
            // marked received now, which makes the balance payable, and a booking that owes nothing is complete.
            if bookings[bookingIndex].deliveredAt == nil { bookings[bookingIndex].deliveredAt = now }
            if bookings[bookingIndex].receiptConfirmedAt == nil { bookings[bookingIndex].receiptConfirmedAt = now }
            if bookings[bookingIndex].balanceCents == 0, bookings[bookingIndex].status == .confirmed {
                bookings[bookingIndex].status = .completed
                completed = true
            }
            try write(bookings, to: bookingsURL)
        }
        try write(deliveries, to: deliveriesURL)

        let photos = ready.filter { $0.file.kind == .photo }.count
        let videos = ready.filter { $0.file.kind == .video }.count
        try? appendSystemMessage(
            .filesDelivered, bookingID: bookingID,
            data: MessageEventData(revised: draft.kind == .revision, title: finalTitle, photos: photos, videos: videos), at: now
        )
        let client = booking.clientName.isEmpty ? "a client" : booking.clientName
        if completed { recordBookingEvent(bookings[bookingIndex], "booking.completed", "Completed", actor: nil) }
        recordForCompany(
            booking.creatorID, actor: userID, "files.delivered",
            "\(draft.kind == .delivery ? "Delivered" : "Sent a revision of") \(ready.count) \(ready.count == 1 ? "file" : "files") for \(booking.packageName) (\(client))"
        )
        return listing(bookings[bookingIndex], provider: true)
    }

    func removeFile(_ fileID: UUID, by userID: UUID) async throws {
        try expireLapsedFiles()
        var files = readDeliveryFiles()
        guard let index = files.firstIndex(where: { $0.file.id == fileID }),
              let booking = readBookings().first(where: { $0.id == files[index].bookingID }), providerAccess(userID, booking, .manage),
              isLive(files[index].file.status)
        else { throw SlateError.bookingNotFound }
        files[index].file.status = .removed
        deleteBytes(of: files[index])
        try write(files, to: deliveryFilesURL)
        let client = booking.clientName.isEmpty ? "a client" : booking.clientName
        recordForCompany(booking.creatorID, actor: userID, "files.removed", "Removed a file from \(booking.packageName) (\(client))")
    }

    // MARK: - The client

    func markFileSaved(_ fileID: UUID, by userID: UUID) async throws -> FileSaveCount {
        try expireLapsedFiles()
        let now = filesNow
        var files = readDeliveryFiles()
        guard let index = files.firstIndex(where: { $0.file.id == fileID }),
              let booking = readBookings().first(where: { $0.id == files[index].bookingID }),
              booking.clientID == userID, files[index].file.status == .ready,
              let delivery = readDeliveries().first(where: { $0.id == files[index].deliveryID })
        else { throw SlateError.bookingNotFound }
        let owed = owedCents(booking, payments: readPayments())
        guard FileRules.canOpen(.original, as: .client, kind: delivery.kind, state: delivery.state, expiresAt: delivery.expiresAt, owedCents: owed, now: now) else {
            throw SlateError.originalsLocked
        }
        if files[index].file.savedAt == nil { files[index].file.savedAt = now }
        try write(files, to: deliveryFilesURL)
        let ready = files.filter { $0.deliveryID == delivery.id && $0.file.status == .ready }
        return FileSaveCount(saved: ready.filter { $0.file.savedAt != nil }.count, total: ready.count)
    }

    func reportFile(_ fileID: UUID, reason: String, by userID: UUID) async throws {
        try expireLapsedFiles()
        guard let stored = readDeliveryFiles().first(where: { $0.file.id == fileID }), isLive(stored.file.status),
              let booking = readBookings().first(where: { $0.id == stored.bookingID }),
              booking.clientID == userID || providerAccess(userID, booking, .manage)
        else { throw SlateError.bookingNotFound }
        let cleaned = String(MessageRules.clean(reason).prefix(500))
        var reports = read([StoredFileReport].self, from: fileReportsURL) ?? []
        reports.append(StoredFileReport(
            id: UUID(), fileID: fileID, reporterID: userID, reason: cleaned.isEmpty ? "No reason given" : cleaned, createdAt: filesNow
        ))
        try write(reports, to: fileReportsURL)
    }

    // MARK: - Opening

    func fileSource(for file: DeliveryFile, part: FileRules.Part, bookingID: UUID, for userID: UUID) async throws -> FileSource {
        try expireLapsedFiles()
        let now = filesNow
        guard let booking = readBookings().first(where: { $0.id == bookingID }) else { throw SlateError.bookingNotFound }
        let provider = providerAccess(userID, booking, .manage)
        guard provider || booking.clientID == userID else { throw SlateError.bookingNotFound }
        guard let stored = readDeliveryFiles().first(where: { $0.file.id == file.id && $0.bookingID == bookingID }),
              let delivery = readDeliveries().first(where: { $0.id == stored.deliveryID })
        else { throw SlateError.fileUnavailable }
        // The creator side can open a file that is still going up; the client only one that is ready.
        guard stored.file.status == .ready || (provider && stored.file.status == .uploading) else { throw SlateError.fileUnavailable }

        let owed = owedCents(booking, payments: readPayments())
        let viewer: FileRules.Viewer = provider ? .provider : .client
        guard FileRules.canOpen(part, as: viewer, kind: delivery.kind, state: delivery.state, expiresAt: delivery.expiresAt, owedCents: owed, now: now) else {
            // A locked original is a different answer from a file that has gone.
            let stillThere = delivery.state == .delivered && (delivery.expiresAt.map { $0 > now } ?? false)
            throw part == .original && stillThere ? SlateError.originalsLocked : SlateError.fileUnavailable
        }
        let path = part == .preview ? stored.file.previewPath : (stored.file.originalPath ?? "")
        let url = objectURL(path)
        guard !path.isEmpty, fileManager.fileExists(atPath: url.path) else { throw SlateError.fileUnavailable }
        return FileSource(url: url, isRemote: false)
    }
}

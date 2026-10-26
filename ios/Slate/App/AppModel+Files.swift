import Foundation
import UIKit

/// Slate Files: adding photos and videos to a booking, delivering them, and the client previewing, paying for and saving them.
/// The app only asks; the backend decides what fits and who can open what (see `SlateBackend` and `…_slate_files.sql`).
extension AppModel {
    // MARK: - What to show

    func files(for bookingID: UUID) -> BookingFiles? { bookingFiles[bookingID] }

    func uploads(for bookingID: UUID) -> [FileUploadItem] { fileUploads[bookingID] ?? [] }

    /// Whether the first delivery of this booking was made as files kept by Slate Pro (as opposed to a link): it is delivered,
    /// and there is no link to open.
    func isHostedDelivery(_ booking: Booking) -> Bool { booking.deliveredAt != nil && booking.deliveryURL == nil }

    /// Whether the signed-in person adds the files on this booking (the creator side) rather than receiving them.
    func addsFiles(to booking: Booking) -> Bool { isProviderSide(booking) }

    /// What the creator side offers on a booking, from what was last loaded: nothing until the shoot has started, and not once
    /// a link was shared.
    func canOfferFiles(for booking: Booking, now: Date) -> Bool {
        guard addsFiles(to: booking), booking.status == .confirmed || booking.status == .completed, booking.startAt <= now else { return false }
        if let files = bookingFiles[booking.id] { return files.canDeliverFiles || files.canSendRevision || files.hasFiles }
        return booking.deliveryURL == nil && booking.receiptConfirmedAt == nil
    }

    // MARK: - Loading

    /// Fetches a booking's files as this person may see them. Returns a sentence to show if it couldn't. A booking the person
    /// has no right to look at simply has none.
    @discardableResult
    func loadFiles(for bookingID: UUID) async -> String? {
        guard let session else { return nil }
        do {
            bookingFiles[bookingID] = try await backend.loadBookingFiles(bookingID: bookingID, for: session.userID)
            return nil
        } catch let error as SlateError where error == .bookingNotFound {
            bookingFiles[bookingID] = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The limits come from the database, so they can change without a release. Quiet: the built-in ones are a fine fallback.
    func loadFilesConfig() async {
        if let latest = try? await backend.loadFilesConfig() { filesConfig = latest }
    }

    /// "4.2 of 50 GB used" for the account on screen. Only the creator side has one.
    func refreshStorageMeter() async {
        guard let session, let owner = ownerID else { return }
        storageMeter = try? await backend.fileStorageMeter(owner: owner, for: session.userID)
    }

    // MARK: - Adding

    /// Puts files on a booking: for each, makes its small copy, asks for room, sends it, and has it checked. They go one after
    /// another, so a long list doesn't use all the phone's memory at once. A file that can't go shows why, with a way to try again.
    func addFiles(_ picks: [PickedFile], to booking: Booking) async {
        guard session != nil, !picks.isEmpty else { return }
        if bookingFiles[booking.id] == nil { await loadFiles(for: booking.id) }
        for pick in picks {
            fileUploads[booking.id, default: []].append(
                FileUploadItem(id: pick.id, bookingID: booking.id, name: pick.name, kind: pick.kind, stage: .preparing)
            )
            pendingPicks[pick.id] = (pick, booking.id)
        }
        for pick in picks { await send(pick.id) }
        await loadFiles(for: booking.id)
        await refreshStorageMeter()
    }

    /// Tries a failed file again from the start.
    func retryUpload(_ itemID: UUID) async {
        guard let bookingID = pendingPicks[itemID]?.booking else { return }
        await giveBackSpace(for: itemID)
        await send(itemID)
        await loadFiles(for: bookingID)
        await refreshStorageMeter()
    }

    /// Gives up on a failed file: the space it reserved is returned and its copy on the phone is deleted.
    func dismissUpload(_ itemID: UUID) async {
        let bookingID = pendingPicks[itemID]?.booking
        await giveBackSpace(for: itemID)
        finishUpload(itemID, keepingFile: false)
        if let bookingID {
            await loadFiles(for: bookingID)
            await refreshStorageMeter()
        }
    }

    private func send(_ itemID: UUID) async {
        guard let session, let entry = pendingPicks[itemID] else { return }
        let pick = entry.pick
        let bookingID = entry.booking
        setStage(itemID, .preparing)
        var previewToClean: URL?
        defer { if let previewToClean { try? FileManager.default.removeItem(at: previewToClean) } }

        do {
            guard let kind = pick.kind else { throw SlateError.unsupportedFileType }
            // The first delivery's copy is watermarked and reduced; a revision's is only the small picture a tile needs.
            let current = bookingFiles[bookingID]
            let expected: DeliveryKind = (current?.firstDelivery == nil || current?.firstDelivery?.state == .draft) ? .delivery : .revision
            let prepared = try await filePreparer.prepare(pick, kind: kind, style: .forDelivery(expected))
            previewToClean = prepared.previewURL

            let request = FileUploadRequest(
                bookingID: bookingID, kind: prepared.kind, name: prepared.name, contentType: prepared.contentType,
                width: prepared.width, height: prepared.height, durationSeconds: prepared.durationSeconds,
                originalBytes: prepared.originalBytes, previewBytes: prepared.previewBytes
            )
            let reservation = try await backend.reserveFile(request, by: session.userID)
            reservedFileIDs[itemID] = reservation.fileID
            if reservation.deliveryKind != expected {
                // Another phone delivered in the meantime, so this copy is the wrong kind.
                await giveBackSpace(for: itemID)
                throw SlateError.backend("This booking changed while the files were being added. Add them again.")
            }

            setStage(itemID, .sending(0))
            try await backend.uploadFile(
                reservation, from: FileUploadSource(original: prepared.originalURL, preview: prepared.previewURL), by: session.userID
            ) { [weak self] fraction in
                Task { @MainActor in self?.setProgress(itemID, fraction) }
            }

            setStage(itemID, .finishing)
            switch try await backend.finishFile(reservation.fileID, by: session.userID) {
            case .accepted:
                finishUpload(itemID, keepingFile: false)
            case .refused(let refusal):
                reservedFileIDs[itemID] = nil
                setStage(itemID, .failed(refusal.message))
            }
        } catch {
            setStage(itemID, .failed(error.localizedDescription))
        }
    }

    private func setStage(_ itemID: UUID, _ stage: FileUploadItem.Stage) {
        guard let bookingID = pendingPicks[itemID]?.booking, let index = fileUploads[bookingID]?.firstIndex(where: { $0.id == itemID }) else { return }
        fileUploads[bookingID]?[index].stage = stage
    }

    /// Progress can arrive a moment after the next step began; it only moves a bar that is still moving.
    private func setProgress(_ itemID: UUID, _ fraction: Double) {
        guard let bookingID = pendingPicks[itemID]?.booking,
              let index = fileUploads[bookingID]?.firstIndex(where: { $0.id == itemID }),
              case .sending = fileUploads[bookingID]?[index].stage
        else { return }
        fileUploads[bookingID]?[index].stage = .sending(fraction)
    }

    /// Takes a file off the list and deletes the copy the app made of it.
    private func finishUpload(_ itemID: UUID, keepingFile: Bool) {
        if let entry = pendingPicks[itemID] {
            fileUploads[entry.booking]?.removeAll { $0.id == itemID }
            if fileUploads[entry.booking]?.isEmpty == true { fileUploads[entry.booking] = nil }
            if !keepingFile { try? FileManager.default.removeItem(at: entry.pick.url) }
        }
        pendingPicks[itemID] = nil
        reservedFileIDs[itemID] = nil
    }

    /// A file that reserved room but never finished returns it, so a failed try doesn't count against the allowance.
    private func giveBackSpace(for itemID: UUID) async {
        guard let session, let fileID = reservedFileIDs[itemID] else { return }
        reservedFileIDs[itemID] = nil
        try? await backend.removeFile(fileID, by: session.userID)
    }

    // MARK: - Delivering and removing

    /// Delivers what is ready (or sends it as a revision). The booking changes too: delivered and received, and complete if
    /// nothing is owed. Returns whether it worked; if not, the reason is shown.
    @discardableResult
    func deliverFiles(for booking: Booking, title: String?, note: String?) async -> Bool {
        guard let session else { return false }
        do {
            bookingFiles[booking.id] = try await backend.deliverFiles(bookingID: booking.id, title: title, note: note, by: session.userID)
            await reloadMoney()
            await refreshStorageMeter()
            return true
        } catch {
            show(error, title: "Couldn't deliver the files")
            await loadFiles(for: booking.id)
            return false
        }
    }

    @discardableResult
    func removeFile(_ file: DeliveryFile, from booking: Booking) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.removeFile(file.id, by: session.userID)
            await loadFiles(for: booking.id)
            await refreshStorageMeter()
            return true
        } catch {
            show(error, title: "Couldn't remove the file")
            return false
        }
    }

    // MARK: - Looking

    /// The small picture for a tile: the preview, or for a video a still from it. Kept for next time.
    func tileImage(for file: DeliveryFile, in delivery: FileDelivery, bookingID: UUID) async -> UIImage? {
        let key = "\(file.id.uuidString)-tile"
        if let cached = fileImages.image(forKey: key) { return cached }
        guard let session,
              let source = try? await backend.fileSource(for: file, part: .preview, bookingID: bookingID, for: session.userID)
        else { return nil }
        let image: UIImage?
        if FileRules.previewIsVideo(kind: file.kind, deliveryKind: delivery.kind) {
            image = await FileImages.poster(at: source.url, longEdge: 480)
        } else {
            image = await FileImages.image(at: source.url, isRemote: source.isRemote, longEdge: 480)
        }
        if let image { fileImages.store(image, forKey: key) }
        return image
    }

    /// The picture to look at full screen: the original when it can be opened (so a revision is seen as it is), otherwise the
    /// watermarked preview.
    func fullImage(for file: DeliveryFile, in delivery: FileDelivery, bookingID: UUID) async -> UIImage? {
        let key = "\(file.id.uuidString)-full-\(delivery.originalsOpen)"
        if let cached = fileImages.image(forKey: key) { return cached }
        guard let session else { return nil }
        var image: UIImage?
        if delivery.originalsOpen, file.originalPath != nil,
           let source = try? await backend.fileSource(for: file, part: .original, bookingID: bookingID, for: session.userID) {
            if source.isRemote {
                if let local = try? await fileTransfer.download(source, name: FileNames.saveName(for: file), progress: { _ in }) {
                    image = await FileImages.image(at: local, isRemote: false, longEdge: 2400)
                    try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
                }
            } else {
                image = await FileImages.image(at: source.url, isRemote: false, longEdge: 2400)
            }
        }
        if image == nil, let source = try? await backend.fileSource(for: file, part: .preview, bookingID: bookingID, for: session.userID) {
            image = await FileImages.image(at: source.url, isRemote: source.isRemote, longEdge: 1600)
        }
        if let image { fileImages.store(image, forKey: key) }
        return image
    }

    /// The address to play a video from: the original when it can be opened, otherwise the watermarked preview.
    func videoURL(for file: DeliveryFile, in delivery: FileDelivery, bookingID: UUID) async -> URL? {
        guard let session else { return nil }
        if delivery.originalsOpen, file.originalPath != nil,
           let source = try? await backend.fileSource(for: file, part: .original, bookingID: bookingID, for: session.userID) {
            return source.url
        }
        guard FileRules.previewIsVideo(kind: file.kind, deliveryKind: delivery.kind) else { return nil }
        return try? await backend.fileSource(for: file, part: .preview, bookingID: bookingID, for: session.userID).url
    }

    // MARK: - Saving

    private func fetchOriginal(_ file: DeliveryFile, bookingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let session else { throw SlateError.notSignedIn }
        let source = try await backend.fileSource(for: file, part: .original, bookingID: bookingID, for: session.userID)
        return try await fileTransfer.download(source, name: FileNames.saveName(for: file), progress: progress)
    }

    /// Counts the file as saved, once it is in the person's hands.
    func markSaved(_ file: DeliveryFile, bookingID: UUID) async {
        guard let session else { return }
        _ = try? await backend.markFileSaved(file.id, by: session.userID)
        await loadFiles(for: bookingID)
    }

    /// Saves one original to Photos. Returns whether it worked; if not, the reason is shown.
    @discardableResult
    func saveToPhotos(_ file: DeliveryFile, bookingID: UUID) async -> Bool {
        do {
            let url = try await fetchOriginal(file, bookingID: bookingID) { _ in }
            try await fileTransfer.saveToPhotos(url, kind: file.kind)
            await markSaved(file, bookingID: bookingID)
            return true
        } catch {
            show(error, title: "Couldn't save")
            return false
        }
    }

    /// Fetches an original to a place the app owns, for the share sheet (Save to Files, AirDrop, and so on).
    func downloadOriginal(_ file: DeliveryFile, bookingID: UUID) async -> URL? {
        do {
            return try await fetchOriginal(file, bookingID: bookingID) { _ in }
        } catch {
            show(error, title: "Couldn't get the file")
            return nil
        }
    }

    /// Saves every original in a delivery that isn't saved yet to Photos, one after another, with progress. It can be stopped.
    func saveAll(_ delivery: FileDelivery, bookingID: UUID) async {
        guard fileSaveRuns[delivery.id] == nil else { return }
        let todo = delivery.files.filter { $0.status == .ready && !$0.isSaved }
        guard !todo.isEmpty else { return }
        fileSaveRuns[delivery.id] = FileSaveRun(deliveryID: delivery.id, done: 0, total: todo.count, currentName: nil, currentFraction: 0)
        fileRunsCancelled.remove(delivery.id)
        var failure: Error?

        for file in todo {
            if fileRunsCancelled.contains(delivery.id) { break }
            fileSaveRuns[delivery.id]?.currentName = file.name
            fileSaveRuns[delivery.id]?.currentFraction = 0
            do {
                let url = try await fetchOriginal(file, bookingID: bookingID) { [weak self] fraction in
                    Task { @MainActor in self?.fileSaveRuns[delivery.id]?.currentFraction = fraction }
                }
                try await fileTransfer.saveToPhotos(url, kind: file.kind)
                await markSaved(file, bookingID: bookingID)
                fileSaveRuns[delivery.id]?.done += 1
            } catch {
                failure = error
                break
            }
        }
        fileSaveRuns[delivery.id] = nil
        fileRunsCancelled.remove(delivery.id)
        await loadFiles(for: bookingID)
        if let failure { show(failure, title: "Couldn't save everything") }
    }

    func cancelSaving(_ delivery: FileDelivery) {
        guard fileSaveRuns[delivery.id] != nil else { return }
        fileRunsCancelled.insert(delivery.id)
        fileSaveRuns[delivery.id]?.isCancelled = true
    }

    // MARK: - Reporting

    @discardableResult
    func reportFile(_ file: DeliveryFile, reason: String) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.reportFile(file.id, reason: reason, by: session.userID)
            return true
        } catch {
            show(error, title: "Couldn't send the report")
            return false
        }
    }
}

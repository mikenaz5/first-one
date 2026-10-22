import Foundation

/// Packages, availability and bookings for the on-device backend.
///
/// `LocalBackend` is an actor, so each of these methods runs start to finish before the next
/// one begins. That is what makes "check the slot is free, then save the booking" safe against
/// two bookings arriving together, the same guarantee the exclusion constraint gives in Postgres.
extension LocalBackend {
    nonisolated var allowsSelfBooking: Bool { true }

    // MARK: - Paths

    func packagesURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("packages.json") }
    func availabilityURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("availability.json") }
    private func busyURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("busy.json") }
    var bookingsURL: URL { root.appendingPathComponent("bookings.json") }

    // MARK: - Packages

    func loadPackages(for creatorID: UUID) async throws -> [ServicePackage] {
        readPackages(creatorID)
    }

    func savePackage(_ package: ServicePackage) async throws -> [ServicePackage] {
        guard PackageRules.problems(in: package).isEmpty else { throw SlateError.invalidPackage }
        // A package can only use one of its own creator's contracts.
        if let templateID = package.contractTemplateID,
           !readTemplates(package.creatorID).contains(where: { $0.id == templateID }) {
            throw SlateError.invalidContract
        }

        var list = readPackages(package.creatorID)
        var saved = package
        saved.updatedAt = Date()
        if let index = list.firstIndex(where: { $0.id == package.id }) {
            saved.createdAt = list[index].createdAt
            saved.position = list[index].position
            list[index] = saved
        } else {
            saved.createdAt = Date()
            saved.position = (list.map(\.position).max() ?? -1) + 1
            list.append(saved)
        }
        try write(list, to: packagesURL(package.creatorID))
        return readPackages(package.creatorID)
    }

    func deletePackage(_ id: UUID, for creatorID: UUID) async throws -> [ServicePackage] {
        var list = readPackages(creatorID)
        list.removeAll { $0.id == id }
        try write(list.enumerated().map { index, package -> ServicePackage in
            var copy = package
            copy.position = index
            return copy
        }, to: packagesURL(creatorID))
        return readPackages(creatorID)
    }

    func readPackages(_ creatorID: UUID) -> [ServicePackage] {
        (read([ServicePackage].self, from: packagesURL(creatorID)) ?? []).sorted { $0.position < $1.position }
    }

    // MARK: - Availability

    func loadAvailability(for creatorID: UUID) async throws -> AvailabilitySettings? {
        read(AvailabilitySettings.self, from: availabilityURL(creatorID))
    }

    func saveAvailability(_ settings: AvailabilitySettings, for creatorID: UUID) async throws -> AvailabilitySettings {
        guard settings.isValid else { throw SlateError.invalidAvailability }
        try fileManager.createDirectory(at: userDirectory(creatorID), withIntermediateDirectories: true)
        try write(settings, to: availabilityURL(creatorID))
        return settings
    }

    func replaceBusyBlocks(_ blocks: [DateInterval], for creatorID: UUID) async throws {
        try fileManager.createDirectory(at: userDirectory(creatorID), withIntermediateDirectories: true)
        try write(IntervalMath.merge(blocks), to: busyURL(creatorID))
    }

    // MARK: - Clients

    func loadPublicPage(handle: String) async throws -> PublicCreatorPage? {
        let accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        for userID in accounts.values {
            guard let profile = try await loadProfile(for: userID), profile.handle == handle, profile.isComplete else { continue }
            return PublicCreatorPage(
                profile: profile,
                portfolio: try await loadPortfolio(for: userID),
                packages: readPackages(userID).filter(\.isPublished)
            )
        }
        return nil
    }

    func loadSchedule(for creatorID: UUID, from: Date, to: Date) async throws -> CreatorSchedule {
        try expireLapsedHolds()
        return makeSchedule(for: creatorID, from: from, to: to)
    }

    func makeSchedule(for creatorID: UUID, from: Date, to: Date) -> CreatorSchedule {
        // A creator who hasn't set hours yet is closed, not "open by default".
        let settings = read(AvailabilitySettings.self, from: availabilityURL(creatorID))
            ?? AvailabilitySettings.closed()
        let window = DateInterval(start: from, end: max(to, from))
        let now = self.now
        let booked = readBookings()
            .filter { $0.creatorID == creatorID && $0.effectiveStatus(at: now).blocksTime }
            .map(\.blockedRange)
            .filter { IntervalMath.overlaps($0, window) }
        let external = (read([DateInterval].self, from: busyURL(creatorID)) ?? [])
            .filter { IntervalMath.overlaps($0, window) }
        return CreatorSchedule(settings: settings, bookedRanges: booked, externalBusy: external)
    }

    // MARK: - Bookings

    /// Everything needed to price, schedule and write a booking, resolved from stored data (never from the client).
    struct ResolvedBooking {
        var package: ServicePackage
        var addOns: [AddOn]
        var settings: AvailabilitySettings
        var creatorName: String
        var contract: RenderedContract
        var creatorSignature: CreatorSignature
        var durationMinutes: Int
    }

    func resolveBooking(_ request: BookingRequest, clientName: String) async throws -> ResolvedBooking {
        guard let package = readPackages(request.creatorID).first(where: { $0.id == request.packageID && $0.isPublished }) else {
            throw SlateError.packageUnavailable
        }
        let requested = Set(request.addOnIDs)
        let chosen = package.addOns(withIDs: requested)
        guard chosen.count == requested.count else { throw SlateError.packageUnavailable }

        guard let templateID = package.contractTemplateID,
              let template = readTemplates(request.creatorID).first(where: { $0.id == templateID })
        else { throw SlateError.contractMissing }
        // Nobody can sign until the creator has a signature on file to countersign with.
        guard let creatorSignature = read(CreatorSignature.self, from: signatureURL(request.creatorID)),
              SignatureRules.isValid(creatorSignature)
        else { throw SlateError.creatorNotReady }

        let settings = read(AvailabilitySettings.self, from: availabilityURL(request.creatorID)) ?? AvailabilitySettings.closed()
        let creatorName = try await loadProfile(for: request.creatorID)?.displayName ?? "Creator"
        let values = ContractContextBuilder.make(
            package: package, addOns: chosen, start: request.startAt, timeZone: settings.timeZone,
            clientName: clientName, creatorName: creatorName, notes: request.notes
        )
        return ResolvedBooking(
            package: package,
            addOns: chosen,
            settings: settings,
            creatorName: creatorName,
            contract: ContractRenderer.render(template: template, values: values),
            creatorSignature: creatorSignature,
            durationMinutes: package.durationMinutes(with: chosen)
        )
    }

    func previewContract(_ request: BookingRequest, clientName: String) async throws -> ContractPreview {
        ContractPreview(contract: try await resolveBooking(request, clientName: clientName).contract)
    }

    func createBooking(
        _ request: BookingRequest, clientID: UUID, clientName: String, signature: SignatureInput
    ) async throws -> SignedBooking {
        // Holds that ran out stop blocking the calendar before anything else is looked at.
        try expireLapsedHolds()
        let resolved = try await resolveBooking(request, clientName: clientName)
        let package = resolved.package
        // Stored dates are whole seconds, so use whole seconds here: what this returns then equals what is read back later.
        let now = Date(timeIntervalSince1970: self.now.timeIntervalSince1970.rounded(.down))
        let duration = resolved.durationMinutes

        // Availability first, so someone who picked a taken time hears about that before anything else.
        let dayBefore = request.startAt.addingTimeInterval(-86_400)
        let dayAfter = request.startAt.addingTimeInterval(Double(duration) * 60 + 86_400)
        let schedule = makeSchedule(for: request.creatorID, from: dayBefore, to: dayAfter)
        guard AvailabilityEngine.isAvailable(start: request.startAt, durationMinutes: duration, schedule: schedule, now: now) else {
            // If the time would be fine with no other bookings, then someone else has it.
            let withoutBookings = CreatorSchedule(settings: schedule.settings, bookedRanges: [], externalBusy: schedule.externalBusy)
            let onlyBookingsBlock = AvailabilityEngine.isAvailable(
                start: request.startAt, durationMinutes: duration, schedule: withoutBookings, now: now
            )
            throw onlyBookingsBlock ? SlateError.slotTaken : SlateError.slotUnavailable
        }

        guard SignatureRules.isValid(signature) else { throw SlateError.invalidSignature }
        let creatorSignature = resolved.creatorSignature
        // The client signed a hash of what they were shown. If the wording has changed since, they must read it again.
        guard signature.documentHash == resolved.contract.documentHash else { throw SlateError.contractChanged }

        let summary = PriceSummary.make(package: package, addOns: resolved.addOns)
        let end = request.startAt.addingTimeInterval(Double(duration) * 60)
        let bookingID = UUID()
        // With a deposit the time is held until it is paid; with none the booking is confirmed straight away.
        let isHeld = summary.depositCents > 0

        let booking = Booking(
            id: bookingID,
            creatorID: request.creatorID,
            clientID: clientID,
            creatorName: resolved.creatorName,
            clientName: clientName,
            packageID: package.id,
            packageName: package.name,
            addOns: resolved.addOns.map { BookedAddOn(id: $0.id, name: $0.name, priceCents: $0.priceCents, extraMinutes: $0.extraMinutes) },
            startAt: request.startAt,
            endAt: end,
            blockedUntil: end.addingTimeInterval(Double(schedule.settings.bufferMinutes) * 60),
            timeZoneID: schedule.settings.timeZoneID,
            currencyCode: package.currencyCode,
            totalCents: summary.totalCents,
            depositCents: summary.depositCents,
            status: isHeld ? .held : .confirmed,
            notes: String(request.notes.prefix(500)),
            createdAt: now,
            holdExpiresAt: isHeld ? now.addingTimeInterval(Double(PaymentRules.holdMinutes) * 60) : nil,
            cancellationPolicy: package.cancellationPolicy
        )

        let clientSignature = ContractSignature(
            id: UUID(), role: .client, userID: clientID,
            signedName: signature.signedName.trimmingCharacters(in: .whitespacesAndNewlines),
            method: signature.method, imagePNG: signature.method == .drawn ? signature.imagePNG : nil,
            signedAt: now, consentVersion: signature.consentVersion, device: signature.device
        )
        var contract = Contract(
            id: UUID(),
            bookingID: bookingID,
            creatorID: request.creatorID,
            clientID: clientID,
            templateID: resolved.contract.templateID,
            templateVersion: resolved.contract.templateVersion,
            title: resolved.contract.title,
            sections: resolved.contract.sections,
            documentHash: resolved.contract.documentHash,
            status: .pending,
            signatures: [clientSignature],
            createdAt: now,
            executedAt: nil
        )
        if !isHeld {
            contract = Self.executed(contract, with: creatorSignature, at: now)
        }

        // Both are written or neither is.
        let previousContracts = readContracts()
        try write(previousContracts + [contract], to: contractsURL)
        do {
            try write(readBookings() + [booking], to: bookingsURL)
        } catch {
            try? write(previousContracts, to: contractsURL)
            throw error
        }
        return SignedBooking(booking: booking, contract: contract)
    }

    /// The contract with the creator's saved signature added and marked complete.
    static func executed(_ contract: Contract, with creatorSignature: CreatorSignature, at date: Date) -> Contract {
        var done = contract
        if done.signature(for: .creator) == nil {
            done.signatures.append(ContractSignature(
                id: UUID(), role: .creator, userID: contract.creatorID,
                signedName: creatorSignature.signedName, method: .onFile,
                imagePNG: creatorSignature.method == .drawn ? creatorSignature.imagePNG : nil,
                signedAt: date, consentVersion: SigningConsent.version,
                device: "Signature on file, applied when the booking was confirmed"
            ))
        }
        done.status = .executed
        done.executedAt = date
        return done
    }

    func loadBookings(for userID: UUID) async throws -> [Booking] {
        try expireLapsedHolds()
        return readBookings()
            .filter { $0.creatorID == userID || $0.clientID == userID }
            .sorted { $0.startAt < $1.startAt }
    }

    func readBookings() -> [Booking] {
        read([Booking].self, from: bookingsURL) ?? []
    }
}

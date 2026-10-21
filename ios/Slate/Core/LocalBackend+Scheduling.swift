import Foundation

/// Packages, availability and bookings for the on-device backend.
///
/// `LocalBackend` is an actor, so each of these methods runs start to finish before the next
/// one begins. That is what makes "check the slot is free, then save the booking" safe against
/// two bookings arriving together, the same guarantee the exclusion constraint gives in Postgres.
extension LocalBackend {
    nonisolated var allowsSelfBooking: Bool { true }

    // MARK: - Paths

    private func packagesURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("packages.json") }
    private func availabilityURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("availability.json") }
    private func busyURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("busy.json") }
    private var bookingsURL: URL { root.appendingPathComponent("bookings.json") }

    // MARK: - Packages

    func loadPackages(for creatorID: UUID) async throws -> [ServicePackage] {
        readPackages(creatorID)
    }

    func savePackage(_ package: ServicePackage) async throws -> [ServicePackage] {
        guard PackageRules.problems(in: package).isEmpty else { throw SlateError.invalidPackage }

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

    private func readPackages(_ creatorID: UUID) -> [ServicePackage] {
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
        makeSchedule(for: creatorID, from: from, to: to)
    }

    private func makeSchedule(for creatorID: UUID, from: Date, to: Date) -> CreatorSchedule {
        // A creator who hasn't set hours yet is closed, not "open by default".
        let settings = read(AvailabilitySettings.self, from: availabilityURL(creatorID))
            ?? AvailabilitySettings.closed()
        let window = DateInterval(start: from, end: max(to, from))
        let booked = readBookings()
            .filter { $0.creatorID == creatorID && $0.status.blocksTime }
            .map(\.blockedRange)
            .filter { IntervalMath.overlaps($0, window) }
        let external = (read([DateInterval].self, from: busyURL(creatorID)) ?? [])
            .filter { IntervalMath.overlaps($0, window) }
        return CreatorSchedule(settings: settings, bookedRanges: booked, externalBusy: external)
    }

    // MARK: - Bookings

    func createBooking(_ request: BookingRequest, clientID: UUID, clientName: String) async throws -> Booking {
        guard let package = readPackages(request.creatorID).first(where: { $0.id == request.packageID && $0.isPublished }) else {
            throw SlateError.packageUnavailable
        }
        let requested = Set(request.addOnIDs)
        let chosen = package.addOns(withIDs: requested)
        guard chosen.count == requested.count else { throw SlateError.packageUnavailable }

        let now = Date()
        let duration = package.durationMinutes(with: chosen)
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

        let summary = PriceSummary.make(package: package, addOns: chosen)
        let end = request.startAt.addingTimeInterval(Double(duration) * 60)
        let creatorName = try await loadProfile(for: request.creatorID)?.displayName ?? "Creator"

        let booking = Booking(
            id: UUID(),
            creatorID: request.creatorID,
            clientID: clientID,
            creatorName: creatorName,
            clientName: clientName,
            packageID: package.id,
            packageName: package.name,
            addOns: chosen.map { BookedAddOn(id: $0.id, name: $0.name, priceCents: $0.priceCents, extraMinutes: $0.extraMinutes) },
            startAt: request.startAt,
            endAt: end,
            blockedUntil: end.addingTimeInterval(Double(schedule.settings.bufferMinutes) * 60),
            timeZoneID: schedule.settings.timeZoneID,
            currencyCode: package.currencyCode,
            totalCents: summary.totalCents,
            depositCents: summary.depositCents,
            status: .confirmed,
            notes: String(request.notes.prefix(500)),
            createdAt: now
        )

        var all = readBookings()
        all.append(booking)
        try write(all, to: bookingsURL)
        return booking
    }

    func loadBookings(for userID: UUID) async throws -> [Booking] {
        readBookings()
            .filter { $0.creatorID == userID || $0.clientID == userID }
            .sorted { $0.startAt < $1.startAt }
    }

    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> Booking {
        var all = readBookings()
        guard let index = all.firstIndex(where: { $0.id == id }),
              all[index].creatorID == userID || all[index].clientID == userID,
              all[index].canCancel(at: Date())
        else { throw SlateError.notCancellable }

        all[index].status = .cancelled
        try write(all, to: bookingsURL)
        return all[index]
    }

    private func readBookings() -> [Booking] {
        read([Booking].self, from: bookingsURL) ?? []
    }
}

import Foundation
import Supabase

/// Packages, availability and bookings on Supabase. The rules that matter (no double-booking,
/// server-side pricing, working hours) live in the `create_booking` SQL function; this file
/// just calls it and maps its error tokens to `SlateError`.
extension SupabaseBackend {
    var allowsSelfBooking: Bool { false }

    // MARK: - Rows

    private struct PackageRow: Codable {
        var id: String
        var creatorId: String
        var name: String
        var summary: String
        var category: String?
        var priceCents: Int
        var currencyCode: String
        var durationMinutes: Int
        var deliverables: [String]
        var turnaroundDays: Int
        var depositCents: Int
        var addOns: [AddOn]
        var isPublished: Bool
        var position: Int
        var createdAt: Date?
        var updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, name, summary, category, deliverables, position
            case creatorId = "creator_id"
            case priceCents = "price_cents"
            case currencyCode = "currency_code"
            case durationMinutes = "duration_minutes"
            case turnaroundDays = "turnaround_days"
            case depositCents = "deposit_cents"
            case addOns = "add_ons"
            case isPublished = "is_published"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    private struct AvailabilityRow: Codable {
        var creatorId: String
        var timeZone: String
        var weekly: [DayHours]
        var blackouts: [BlackoutRange]
        var minNoticeHours: Int
        var maxAdvanceDays: Int
        var bufferMinutes: Int
        var slotIntervalMinutes: Int

        enum CodingKeys: String, CodingKey {
            case weekly, blackouts
            case creatorId = "creator_id"
            case timeZone = "time_zone"
            case minNoticeHours = "min_notice_hours"
            case maxAdvanceDays = "max_advance_days"
            case bufferMinutes = "buffer_minutes"
            case slotIntervalMinutes = "slot_interval_minutes"
        }
    }

    private struct BusyBlockRow: Encodable {
        var creatorId: String
        var startsAt: Date
        var endsAt: Date

        enum CodingKeys: String, CodingKey {
            case creatorId = "creator_id"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }
    }

    private struct BusyIntervalRow: Decodable {
        var startsAt: Date
        var endsAt: Date
        var kind: String

        enum CodingKeys: String, CodingKey {
            case kind
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }
    }

    private struct BookingRow: Decodable {
        var id: String
        var creatorId: String
        var clientId: String?
        var creatorName: String
        var clientName: String
        var packageId: String?
        var packageName: String
        var addOns: [BookedAddOn]
        var startAt: Date
        var endAt: Date
        var blockedUntil: Date
        var timeZone: String
        var currencyCode: String
        var totalCents: Int
        var depositCents: Int
        var status: String
        var notes: String
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, status, notes
            case creatorId = "creator_id"
            case clientId = "client_id"
            case creatorName = "creator_name"
            case clientName = "client_name"
            case packageId = "package_id"
            case packageName = "package_name"
            case addOns = "add_ons"
            case startAt = "start_at"
            case endAt = "end_at"
            case blockedUntil = "blocked_until"
            case timeZone = "time_zone"
            case currencyCode = "currency_code"
            case totalCents = "total_cents"
            case depositCents = "deposit_cents"
            case createdAt = "created_at"
        }
    }

    private struct CreateBookingParams: Encodable {
        var pPackageId: String
        var pAddOnIds: [String]
        var pStartAt: Date
        var pClientName: String
        var pNotes: String

        enum CodingKeys: String, CodingKey {
            case pPackageId = "p_package_id"
            case pAddOnIds = "p_add_on_ids"
            case pStartAt = "p_start_at"
            case pClientName = "p_client_name"
            case pNotes = "p_notes"
        }
    }

    private struct CancelBookingParams: Encodable {
        var pBookingId: String
        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct BusyIntervalParams: Encodable {
        var pCreatorId: String
        var pFrom: Date
        var pTo: Date

        enum CodingKeys: String, CodingKey {
            case pCreatorId = "p_creator_id"
            case pFrom = "p_from"
            case pTo = "p_to"
        }
    }

    // MARK: - Packages

    func loadPackages(for creatorID: UUID) async throws -> [ServicePackage] {
        let rows: [PackageRow] = try await client
            .from("packages")
            .select()
            .eq("creator_id", value: Self.key(creatorID))
            .order("position", ascending: true)
            .execute()
            .value
        return try rows.map(makePackage)
    }

    func savePackage(_ package: ServicePackage) async throws -> [ServicePackage] {
        guard PackageRules.problems(in: package).isEmpty else { throw SlateError.invalidPackage }
        let row = PackageRow(
            id: Self.key(package.id),
            creatorId: Self.key(package.creatorID),
            name: package.name,
            summary: package.summary,
            category: package.category?.rawValue,
            priceCents: package.priceCents,
            currencyCode: package.currencyCode,
            durationMinutes: package.durationMinutes,
            deliverables: package.deliverables,
            turnaroundDays: package.turnaroundDays,
            depositCents: package.depositCents,
            addOns: package.addOns,
            isPublished: package.isPublished,
            position: package.position,
            createdAt: nil,
            updatedAt: nil
        )
        try await client.from("packages").upsert(row, onConflict: "id").execute()
        return try await loadPackages(for: package.creatorID)
    }

    func deletePackage(_ id: UUID, for creatorID: UUID) async throws -> [ServicePackage] {
        try await client
            .from("packages")
            .delete()
            .eq("id", value: Self.key(id))
            .eq("creator_id", value: Self.key(creatorID))
            .execute()
        return try await loadPackages(for: creatorID)
    }

    private func makePackage(_ row: PackageRow) throws -> ServicePackage {
        guard let id = UUID(uuidString: row.id), let creatorID = UUID(uuidString: row.creatorId) else {
            throw SlateError.backend("Malformed package id.")
        }
        return ServicePackage(
            id: id,
            creatorID: creatorID,
            name: row.name,
            summary: row.summary,
            category: row.category.flatMap(Specialty.init(rawValue:)),
            priceCents: row.priceCents,
            currencyCode: row.currencyCode,
            durationMinutes: row.durationMinutes,
            deliverables: row.deliverables,
            turnaroundDays: row.turnaroundDays,
            depositCents: row.depositCents,
            addOns: row.addOns,
            isPublished: row.isPublished,
            position: row.position,
            createdAt: row.createdAt ?? Date(),
            updatedAt: row.updatedAt ?? Date()
        )
    }

    // MARK: - Availability

    func loadAvailability(for creatorID: UUID) async throws -> AvailabilitySettings? {
        let rows: [AvailabilityRow] = try await client
            .from("availability_settings")
            .select()
            .eq("creator_id", value: Self.key(creatorID))
            .limit(1)
            .execute()
            .value
        return rows.first.map { row in
            AvailabilitySettings(
                timeZoneID: row.timeZone,
                weekly: row.weekly,
                blackouts: row.blackouts,
                minNoticeHours: row.minNoticeHours,
                maxAdvanceDays: row.maxAdvanceDays,
                bufferMinutes: row.bufferMinutes,
                slotIntervalMinutes: row.slotIntervalMinutes
            )
        }
    }

    func saveAvailability(_ settings: AvailabilitySettings, for creatorID: UUID) async throws -> AvailabilitySettings {
        guard settings.isValid else { throw SlateError.invalidAvailability }
        let row = AvailabilityRow(
            creatorId: Self.key(creatorID),
            timeZone: settings.timeZoneID,
            weekly: settings.weekly,
            blackouts: settings.blackouts,
            minNoticeHours: settings.minNoticeHours,
            maxAdvanceDays: settings.maxAdvanceDays,
            bufferMinutes: settings.bufferMinutes,
            slotIntervalMinutes: settings.slotIntervalMinutes
        )
        try await client.from("availability_settings").upsert(row, onConflict: "creator_id").execute()
        return settings
    }

    /// Delete-then-insert, so a failure between the two leaves no imported busy time until the
    /// next sync. That errs towards "available", and the booking function re-checks anyway.
    func replaceBusyBlocks(_ blocks: [DateInterval], for creatorID: UUID) async throws {
        let key = Self.key(creatorID)
        try await client.from("busy_blocks").delete().eq("creator_id", value: key).execute()
        let rows = IntervalMath.merge(blocks).map {
            BusyBlockRow(creatorId: key, startsAt: $0.start, endsAt: $0.end)
        }
        if !rows.isEmpty {
            try await client.from("busy_blocks").insert(rows).execute()
        }
    }

    // MARK: - Clients

    func loadPublicPage(handle: String) async throws -> PublicCreatorPage? {
        guard let profile = try await loadProfile(handle: handle), profile.isComplete else { return nil }
        let portfolio = try await loadPortfolio(for: profile.id)
        let rows: [PackageRow] = try await client
            .from("packages")
            .select()
            .eq("creator_id", value: Self.key(profile.id))
            .eq("is_published", value: true)
            .order("position", ascending: true)
            .execute()
            .value
        return PublicCreatorPage(profile: profile, portfolio: portfolio, packages: try rows.map(makePackage))
    }

    func loadSchedule(for creatorID: UUID, from: Date, to: Date) async throws -> CreatorSchedule {
        let settings = try await loadAvailability(for: creatorID) ?? AvailabilitySettings.closed()
        let rows: [BusyIntervalRow] = try await client
            .rpc("get_busy_intervals", params: BusyIntervalParams(pCreatorId: Self.key(creatorID), pFrom: from, pTo: max(to, from)))
            .execute()
            .value
        var booked: [DateInterval] = []
        var external: [DateInterval] = []
        for row in rows where row.endsAt > row.startsAt {
            let interval = DateInterval(start: row.startsAt, end: row.endsAt)
            if row.kind == "booking" { booked.append(interval) } else { external.append(interval) }
        }
        return CreatorSchedule(settings: settings, bookedRanges: booked, externalBusy: external)
    }

    // MARK: - Bookings

    func createBooking(_ request: BookingRequest, clientID: UUID, clientName: String) async throws -> Booking {
        let params = CreateBookingParams(
            pPackageId: Self.key(request.packageID),
            pAddOnIds: request.addOnIDs.map(Self.key),
            pStartAt: request.startAt,
            pClientName: clientName,
            pNotes: request.notes
        )
        do {
            let row: BookingRow = try await client.rpc("create_booking", params: params).execute().value
            return try makeBooking(row)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func loadBookings(for userID: UUID) async throws -> [Booking] {
        // Row Level Security already limits this to bookings the person is part of.
        let rows: [BookingRow] = try await client
            .from("bookings")
            .select()
            .order("start_at", ascending: true)
            .execute()
            .value
        return try rows.map(makeBooking)
    }

    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> Booking {
        do {
            let row: BookingRow = try await client
                .rpc("cancel_booking", params: CancelBookingParams(pBookingId: Self.key(id)))
                .execute()
                .value
            return try makeBooking(row)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    private func makeBooking(_ row: BookingRow) throws -> Booking {
        guard let id = UUID(uuidString: row.id), let creatorID = UUID(uuidString: row.creatorId) else {
            throw SlateError.backend("Malformed booking id.")
        }
        return Booking(
            id: id,
            creatorID: creatorID,
            clientID: row.clientId.flatMap(UUID.init(uuidString:)),
            creatorName: row.creatorName,
            clientName: row.clientName,
            packageID: row.packageId.flatMap(UUID.init(uuidString:)),
            packageName: row.packageName,
            addOns: row.addOns,
            startAt: row.startAt,
            endAt: row.endAt,
            blockedUntil: row.blockedUntil,
            timeZoneID: row.timeZone,
            currencyCode: row.currencyCode,
            totalCents: row.totalCents,
            depositCents: row.depositCents,
            status: BookingStatus(rawValue: row.status) ?? .confirmed,
            notes: row.notes,
            createdAt: row.createdAt
        )
    }

    /// The SQL functions raise plain tokens such as `slot_taken`; turn them into typed errors.
    static func mapBookingError(_ error: Error) -> Error {
        let text = "\(error)"
        let known: [(token: String, error: SlateError)] = [
            ("slot_taken", .slotTaken),
            ("slot_unavailable", .slotUnavailable),
            ("package_unavailable", .packageUnavailable),
            ("cannot_book_yourself", .cannotBookYourself),
            ("not_cancellable", .notCancellable),
            ("not_signed_in", .notSignedIn),
        ]
        for entry in known where text.contains(entry.token) {
            return entry.error
        }
        // 23P01 is Postgres's exclusion_violation, in case the function's own handler is bypassed.
        if text.contains("23P01") { return SlateError.slotTaken }
        return error
    }
}

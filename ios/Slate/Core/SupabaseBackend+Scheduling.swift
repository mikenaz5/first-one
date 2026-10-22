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
        var contractTemplateId: String?
        var cancellationPolicy: String
        var usageRights: String
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
            case contractTemplateId = "contract_template_id"
            case cancellationPolicy = "cancellation_policy"
            case usageRights = "usage_rights"
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
        var holdExpiresAt: Date?
        var deliveredAt: Date?
        var deliveryUrl: String?
        var deliveryNote: String?
        var receiptConfirmedAt: Date?
        var cancelledAt: Date?
        var cancelledBy: String?
        var cancellationPolicy: String?

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
            case holdExpiresAt = "hold_expires_at"
            case deliveredAt = "delivered_at"
            case deliveryUrl = "delivery_url"
            case deliveryNote = "delivery_note"
            case receiptConfirmedAt = "receipt_confirmed_at"
            case cancelledAt = "cancelled_at"
            case cancelledBy = "cancelled_by"
            case cancellationPolicy = "cancellation_policy"
        }
    }

    /// What `cancel_booking` returns.
    private struct CancelRow: Decodable {
        var booking: BookingRow
        var refundCents: Int
        var percent: Int

        enum CodingKeys: String, CodingKey {
            case booking, percent
            case refundCents = "refund_cents"
        }
    }

    /// The signature as `create_booking` reads it (`p_signature ->> 'signedName'` and so on).
    private struct SignaturePayload: Encodable {
        var signedName: String
        var method: String
        var imagePng: String?
        var consentVersion: Int
        var device: String
    }

    /// What `create_booking` returns: the booking and its contract with both signatures.
    private struct SignedBookingRow: Decodable {
        var booking: BookingRow
        var contract: ContractRow
    }

    private struct CreateBookingParams: Encodable {
        var pPackageId: String
        var pAddOnIds: [String]
        var pStartAt: Date
        var pClientName: String
        var pNotes: String
        var pDocumentHash: String
        var pSignature: SignaturePayload

        enum CodingKeys: String, CodingKey {
            case pPackageId = "p_package_id"
            case pAddOnIds = "p_add_on_ids"
            case pStartAt = "p_start_at"
            case pClientName = "p_client_name"
            case pNotes = "p_notes"
            case pDocumentHash = "p_document_hash"
            case pSignature = "p_signature"
        }
    }

    private struct CancelBookingParams: Encodable {
        var pBookingId: String
        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct ShareDeliveryParams: Encodable {
        var pBookingId: String
        var pUrl: String
        var pNote: String

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pUrl = "p_url"
            case pNote = "p_note"
        }
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
            contractTemplateId: package.contractTemplateID.map(Self.key),
            cancellationPolicy: package.cancellationPolicy.rawValue,
            usageRights: package.usageRights.rawValue,
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
            updatedAt: row.updatedAt ?? Date(),
            contractTemplateID: row.contractTemplateId.flatMap(UUID.init(uuidString:)),
            cancellationPolicy: CancellationPolicy(rawValue: row.cancellationPolicy) ?? .moderate,
            usageRights: UsageRights(rawValue: row.usageRights) ?? .personal
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

    /// Books and signs in one database call, so there is never a booking without its contract.
    /// The server re-renders the contract and refuses (`contract_changed`) if it no longer matches
    /// the hash the client signed; the creator's signature on file is applied there too.
    func createBooking(
        _ request: BookingRequest, clientID: UUID, clientName: String, signature: SignatureInput
    ) async throws -> SignedBooking {
        guard SignatureRules.isValid(signature) else { throw SlateError.invalidSignature }
        let params = CreateBookingParams(
            pPackageId: Self.key(request.packageID),
            pAddOnIds: request.addOnIDs.map(Self.key),
            pStartAt: request.startAt,
            pClientName: clientName,
            pNotes: request.notes,
            pDocumentHash: signature.documentHash,
            pSignature: SignaturePayload(
                signedName: signature.signedName.trimmingCharacters(in: .whitespacesAndNewlines),
                method: signature.method.rawValue,
                imagePng: signature.method == .drawn ? signature.imagePNG?.base64EncodedString() : nil,
                consentVersion: signature.consentVersion,
                device: signature.device
            )
        )
        do {
            let row: SignedBookingRow = try await client.rpc("create_booking", params: params).execute().value
            return SignedBooking(booking: try makeBooking(row.booking), contract: try makeContract(row.contract))
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func loadBookings(for userID: UUID) async throws -> [Booking] {
        // Let go of holds that ran out first, so they don't show as held. Best effort.
        try? await expireHolds()
        // Row Level Security already limits this to bookings the person is part of.
        let rows: [BookingRow] = try await client
            .from("bookings")
            .select()
            .order("start_at", ascending: true)
            .execute()
            .value
        return try rows.map(makeBooking)
    }

    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> CancellationResult {
        do {
            let row: CancelRow = try await client
                .rpc("cancel_booking", params: CancelBookingParams(pBookingId: Self.key(id)))
                .execute()
                .value
            return CancellationResult(booking: try makeBooking(row.booking), refundCents: row.refundCents, percent: row.percent)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func shareDelivery(bookingID: UUID, link: String, note: String, by creatorID: UUID) async throws -> Booking {
        do {
            let row: BookingRow = try await client
                .rpc("share_delivery", params: ShareDeliveryParams(pBookingId: Self.key(bookingID), pUrl: link, pNote: note))
                .execute()
                .value
            return try makeBooking(row)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func confirmReceipt(bookingID: UUID, by clientID: UUID) async throws -> Booking {
        do {
            let row: BookingRow = try await client
                .rpc("confirm_receipt", params: CancelBookingParams(pBookingId: Self.key(bookingID)))
                .execute()
                .value
            return try makeBooking(row)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func expireHolds() async throws {
        try await client.rpc("expire_holds").execute()
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
            createdAt: row.createdAt,
            holdExpiresAt: row.holdExpiresAt,
            deliveredAt: row.deliveredAt,
            deliveryURL: row.deliveryUrl,
            deliveryNote: row.deliveryNote,
            receiptConfirmedAt: row.receiptConfirmedAt,
            cancelledAt: row.cancelledAt,
            cancelledByID: row.cancelledBy.flatMap(UUID.init(uuidString:)),
            cancellationPolicy: row.cancellationPolicy.flatMap(CancellationPolicy.init(rawValue:)) ?? .moderate
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
            ("contract_changed", .contractChanged),
            ("contract_missing", .contractMissing),
            ("creator_not_ready", .creatorNotReady),
            ("invalid_signature", .invalidSignature),
            ("invalid_contract", .invalidContract),
            ("hold_expired", .holdExpired),
            ("payments_not_ready", .paymentsNotReady),
            ("payment_not_due", .paymentNotDue),
            ("balance_not_due", .paymentNotDue),
            ("nothing_due", .paymentNotDue),
            ("already_paid", .alreadyPaid),
            ("not_deliverable", .notDeliverable),
            ("invalid_delivery_url", .invalidDeliveryLink),
            ("note_too_long", .deliveryNoteTooLong),
            ("not_delivered", .notDelivered),
            ("not_reviewable", .notReviewable),
            ("invalid_rating", .invalidRating),
            ("review_too_long", .reviewTooLong),
            ("already_reviewed", .alreadyReviewed),
            ("conversation_closed", .conversationClosed),
            ("message_too_long", .messageTooLong),
            ("invalid_message", .invalidMessage),
            ("rate_limited", .rateLimited),
            ("not_found", .bookingNotFound),
        ]
        for entry in known where text.contains(entry.token) {
            return entry.error
        }
        // 23P01 is Postgres's exclusion_violation, in case the function's own handler is bypassed.
        if text.contains("23P01") { return SlateError.slotTaken }
        return error
    }
}

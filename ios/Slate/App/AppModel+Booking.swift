import Foundation

extension AppModel {
    // MARK: - Availability

    func saveAvailability(_ settings: AvailabilitySettings) async throws {
        guard let session else { throw SlateError.notSignedIn }
        availability = try await backend.saveAvailability(settings, for: session.userID)
        // The window of dates that matter may have changed.
        Task { await syncBusyTime() }
    }

    // MARK: - Booking as a client

    /// The schedule a client sees for a creator: hours, blackouts and blocked time ranges.
    func loadSchedule(for creatorID: UUID) async throws -> CreatorSchedule {
        let now = Date()
        return try await backend.loadSchedule(
            for: creatorID,
            from: now.addingTimeInterval(-86_400),
            to: now.addingTimeInterval(86_400 * 740)
        )
    }

    /// Whether the signed-in person may book this creator's packages.
    func canBook(creatorID: UUID) -> Bool {
        creatorID != session?.userID || backend.allowsSelfBooking
    }

    /// The name that appears in the contract for this person.
    var clientDisplayName: String {
        let name = profile?.displayName ?? session?.fullName ?? ""
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Client" : name
    }

    /// Books and signs in one step. The backend decides everything that matters; this just refreshes our lists.
    /// With a deposit the booking comes back held, and `pay` finishes it; with none it is already confirmed.
    func book(_ request: BookingRequest, signature: SignatureInput) async throws -> SignedBooking {
        guard let session else { throw SlateError.notSignedIn }
        let signed = try await backend.createBooking(
            request, clientID: session.userID, clientName: clientDisplayName, signature: signature
        )
        // Refresh the list; the booking itself already succeeded, so a failure here isn't fatal.
        if let latest = try? await backend.loadBookings(for: session.userID) {
            bookings = latest
        } else {
            bookings.append(signed.booking)
        }
        payments = (try? await backend.loadPayments(for: session.userID)) ?? payments
        contractsByBooking[signed.booking.id] = signed.contract
        bookingsChanged()
        if signed.booking.status == .confirmed {
            afterConfirmed(signed.booking, contract: signed.contract)
        }
        return signed
    }

    /// Runs when a booking becomes confirmed: the signed PDF now has both signatures, and the shoot goes on the calendar.
    func afterConfirmed(_ booking: Booking, contract: Contract) {
        Task {
            _ = await signedPDF(for: contract, booking: booking)
            await syncBookingEvents()
        }
    }

    // MARK: - Bookings list

    /// Cancels, works out the refund from the policy, and sends it back. The refund is recorded first, so a
    /// failure while sending it never loses it: it stays owed and is retried.
    @discardableResult
    func cancel(_ booking: Booking) async -> CancellationResult? {
        guard let session else { return nil }
        do {
            let result = try await backend.cancelBooking(booking.id, by: session.userID)
            if let index = bookings.firstIndex(where: { $0.id == result.booking.id }) {
                bookings[index] = result.booking
            }
            removeCalendarEvent(for: booking)
            contractsByBooking[booking.id] = nil
            bookingsChanged()
            await settleRefunds(for: booking.id)
            return result
        } catch {
            show(error, title: "Couldn't cancel")
            return nil
        }
    }

    func isMine(_ booking: Booking) -> Bool { booking.creatorID == session?.userID }

    // MARK: - Deep links

    /// Handles `slate://book/<handle>` (open a creator's page), `slate://booking/<id>` (from a calendar event or a
    /// notification), `slate://messages/<id>` (a message notification) and `slate://stripe/…` (back from Stripe).
    func handle(url: URL) {
        guard let link = AppLink(url: url) else { return }
        switch link {
        case .creatorPage(let handle):
            pendingBookingHandle = handle
            Task { await openPendingBookingLinkIfNeeded() }
        case .booking(let id):
            if let id { openBooking(id) } else { selectedTab = .bookings }
        case .messages(let id):
            if let id { openConversation(id) } else { selectedTab = .messages }
        case .stripeReturn:
            // Back from Stripe's setup pages: see where the account stands now.
            Task { await refreshPaymentAccount() }
        }
    }

    /// Opens a stored link once the person is signed in and set up.
    func openPendingBookingLinkIfNeeded() async {
        guard phase == .ready, let handle = pendingBookingHandle else { return }
        pendingBookingHandle = nil
        do {
            if let page = try await backend.loadPublicPage(handle: handle) {
                presentedPage = page
            } else {
                alert = ErrorAlert(title: "Page not found", message: "There's no creator at \"\(handle)\".")
            }
        } catch {
            show(error, title: "Couldn't open that page")
        }
    }
}

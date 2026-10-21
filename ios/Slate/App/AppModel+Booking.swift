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

    func book(_ request: BookingRequest) async throws -> Booking {
        guard let session else { throw SlateError.notSignedIn }
        let name = profile?.displayName ?? session.fullName ?? "Client"
        let booking = try await backend.createBooking(request, clientID: session.userID, clientName: name)
        // Refresh the list; the booking itself already succeeded, so a failure here isn't fatal.
        if let latest = try? await backend.loadBookings(for: session.userID) {
            bookings = latest
        } else {
            bookings.append(booking)
        }
        Task { await syncBookingEvents() }
        return booking
    }

    // MARK: - Bookings list

    func cancel(_ booking: Booking) async {
        guard let session else { return }
        do {
            let updated = try await backend.cancelBooking(booking.id, by: session.userID)
            if let index = bookings.firstIndex(where: { $0.id == updated.id }) {
                bookings[index] = updated
            }
            removeCalendarEvent(for: booking)
        } catch {
            show(error, title: "Couldn't cancel")
        }
    }

    func isMine(_ booking: Booking) -> Bool { booking.creatorID == session?.userID }

    // MARK: - Deep links

    /// Handles `slate://book/<handle>` (open a creator's page) and `slate://booking/<id>` (from a calendar event).
    func handle(url: URL) {
        guard url.scheme == AppConfig.urlScheme else { return }
        switch url.host {
        case "book":
            let handle = url.lastPathComponent.lowercased()
            guard !handle.isEmpty, handle != "/" else { return }
            pendingBookingHandle = handle
            Task { await openPendingBookingLinkIfNeeded() }
        case "booking":
            selectedTab = .bookings
        default:
            break
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

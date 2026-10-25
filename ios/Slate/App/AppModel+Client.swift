import Foundation

extension AppModel {
    /// The creators this person has booked, most recently booked first.
    var creatorsBooked: [BookedCreator] {
        guard let id = session?.userID else { return [] }
        return BookedCreators.list(from: bookings, clientID: id)
    }

    /// The name the client goes by on contracts and in the app.
    var clientFirstName: String {
        let name = personalProfile?.displayName ?? session?.fullName ?? ""
        return name.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Opens a creator's page, over whatever the person is doing, so they can book again.
    func openCreatorPage(_ creatorID: UUID) async {
        do {
            guard let profile = try await backend.loadProfile(for: creatorID),
                  let page = try await backend.loadPublicPage(handle: profile.handle) else { throw SlateError.notFound }
            presentedPage = page
        } catch {
            show(error, title: "Couldn't open that page")
        }
    }

    /// Opens the page for a pasted link or name. Returns false when the text doesn't look like either.
    @discardableResult
    func openBookingLink(text: String) async -> Bool {
        guard let handle = BookingLinkText.handle(from: text) else { return false }
        pendingBookingHandle = handle
        await openPendingBookingLinkIfNeeded()
        return true
    }
}

import Foundation

extension AppModel {
    /// Loads everything scheduling-related for the signed-in creator.
    func loadScheduling(for userID: UUID) async throws {
        packages = try await backend.loadPackages(for: userID)
        availability = try await backend.loadAvailability(for: userID)
        bookings = try await backend.loadBookings(for: userID)
    }

    /// Runs once the account has loaded and the person is in the app.
    func afterAccountLoaded() {
        calendarAccess = calendar.access
        Task { await syncCalendar() }
        Task { await openPendingBookingLinkIfNeeded() }
    }

    // MARK: - Packages

    var publishedPackages: [ServicePackage] { packages.filter(\.isPublished) }

    /// True until the creator has set at least one open day. Clients can't book without it.
    var needsAvailability: Bool { !(availability?.hasOpenDay ?? false) }

    /// A starting point for the "New package" form.
    func makeNewPackage() -> ServicePackage {
        ServicePackage(
            id: UUID(),
            creatorID: session?.userID ?? UUID(),
            name: "",
            summary: "",
            category: nil,
            priceCents: 0,
            currencyCode: Money.defaultCurrencyCode,
            durationMinutes: 120,
            deliverables: [],
            turnaroundDays: 14,
            depositCents: 0,
            addOns: [],
            isPublished: true,
            position: (packages.map(\.position).max() ?? -1) + 1,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func savePackage(_ package: ServicePackage) async throws {
        packages = try await backend.savePackage(package)
    }

    func deletePackage(_ package: ServicePackage) async {
        guard let session else { return }
        do {
            packages = try await backend.deletePackage(package.id, for: session.userID)
        } catch {
            show(error, title: "Couldn't delete the package")
        }
    }

    func setPublished(_ package: ServicePackage, _ isPublished: Bool) async {
        var changed = package
        changed.isPublished = isPublished
        do {
            try await savePackage(changed)
        } catch {
            show(error, title: isPublished ? "Couldn't show the package" : "Couldn't hide the package")
        }
    }

    /// Copies a package as a hidden draft, so it can be tweaked before clients see it.
    func duplicate(_ package: ServicePackage) async {
        var copy = makeNewPackage()
        copy.name = String("\(package.name) copy".prefix(PackageRules.nameLength.upperBound))
        copy.summary = package.summary
        copy.category = package.category
        copy.priceCents = package.priceCents
        copy.currencyCode = package.currencyCode
        copy.durationMinutes = package.durationMinutes
        copy.deliverables = package.deliverables
        copy.turnaroundDays = package.turnaroundDays
        copy.depositCents = package.depositCents
        copy.addOns = package.addOns.map { addOn in
            var fresh = addOn
            fresh.id = UUID()
            return fresh
        }
        copy.isPublished = false
        do {
            try await savePackage(copy)
        } catch {
            show(error, title: "Couldn't duplicate the package")
        }
    }
}

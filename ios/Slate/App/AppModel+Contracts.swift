import Foundation

extension AppModel {
    /// True once the creator has saved a signature. Without one, clients can't sign and book.
    var hasCreatorSignature: Bool { creatorSignature != nil }

    // MARK: - Templates

    func template(withID id: UUID?) -> ContractTemplate? {
        guard let id else { return nil }
        return contractTemplates.first { $0.id == id }
    }

    func saveTemplate(_ template: ContractTemplate) async throws {
        contractTemplates = try await backend.saveContractTemplate(template)
    }

    /// Adds an editable copy of one of the starter contracts and returns it.
    @discardableResult
    func addStarterTemplate(_ kind: ContractKind) async throws -> ContractTemplate {
        guard let session else { throw SlateError.notSignedIn }
        let starter = StarterTemplates.make(kind, creatorID: session.userID)
        contractTemplates = try await backend.saveContractTemplate(starter)
        return contractTemplates.first { $0.id == starter.id } ?? starter
    }

    @discardableResult
    func addBlankTemplate() async throws -> ContractTemplate {
        guard let session else { throw SlateError.notSignedIn }
        let blank = StarterTemplates.blank(creatorID: session.userID)
        contractTemplates = try await backend.saveContractTemplate(blank)
        return contractTemplates.first { $0.id == blank.id } ?? blank
    }

    func deleteTemplate(_ template: ContractTemplate) async {
        guard let session else { return }
        do {
            contractTemplates = try await backend.deleteContractTemplate(template.id, for: session.userID)
        } catch {
            show(error, title: "Couldn't delete the contract")
        }
    }

    func packagesUsing(_ template: ContractTemplate) -> [ServicePackage] {
        packages.filter { $0.contractTemplateID == template.id }
    }

    // MARK: - Creator signature

    func saveCreatorSignature(_ signature: CreatorSignature) async throws {
        guard let session else { throw SlateError.notSignedIn }
        try await backend.saveCreatorSignature(signature, for: session.userID)
        creatorSignature = try await backend.loadCreatorSignature(for: session.userID)
    }

    // MARK: - Contracts for bookings

    /// The contract exactly as a client is about to sign it, filled in by the backend.
    func previewContract(for request: BookingRequest) async throws -> ContractPreview {
        try await backend.previewContract(request, clientName: clientDisplayName)
    }

    func contract(for booking: Booking) async -> Contract? {
        if let cached = contractsByBooking[booking.id] { return cached }
        guard let session, let loaded = try? await backend.loadContract(bookingID: booking.id, for: session.userID) else { return nil }
        contractsByBooking[booking.id] = loaded
        return loaded
    }

    /// The signed PDF. If neither party's device has stored one yet, this renders it from the stored
    /// contract and stores it for both, so the PDF always exists once a contract is signed.
    func signedPDF(for contract: Contract, booking: Booking) async -> Data? {
        if let stored = try? await backend.loadContractPDF(contractID: contract.id) { return stored }
        let data = ContractPDF.render(contract, creatorName: booking.creatorName, clientName: booking.clientName)
        try? await backend.attachContractPDF(data, contractID: contract.id)
        // Prefer whatever won the race to be stored, so both parties hold the identical file.
        return (try? await backend.loadContractPDF(contractID: contract.id)) ?? data
    }
}

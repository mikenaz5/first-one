import Foundation

/// Contract templates, the creator's signature, signed contracts and their PDFs, for the on-device backend.
extension LocalBackend {
    // MARK: Paths

    func templatesURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("contract-templates.json") }
    func signatureURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("signature.json") }
    var contractsURL: URL { root.appendingPathComponent("contracts.json") }
    private var pdfDirectory: URL { root.appendingPathComponent("contract-pdfs", isDirectory: true) }

    // MARK: Templates

    func readTemplates(_ creatorID: UUID) -> [ContractTemplate] {
        (read([ContractTemplate].self, from: templatesURL(creatorID)) ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func loadContractTemplates(for creatorID: UUID) async throws -> [ContractTemplate] {
        readTemplates(creatorID)
    }

    func saveContractTemplate(_ template: ContractTemplate) async throws -> [ContractTemplate] {
        try authorizeOwner(template.creatorID, .templatesManage)
        guard ContractRules.problems(in: template).isEmpty else { throw SlateError.invalidContract }

        var list = readTemplates(template.creatorID)
        var saved = template
        let now = Date()
        if let index = list.firstIndex(where: { $0.id == template.id }) {
            let existing = list[index]
            saved.createdAt = existing.createdAt
            // Signed contracts keep the version they were signed on; only a real wording change bumps it.
            let reworded = existing.title != saved.title || existing.clauses != saved.clauses
            saved.version = reworded ? existing.version + 1 : existing.version
            saved.updatedAt = reworded ? now : existing.updatedAt
            if reworded {
                recordForCompany(template.creatorID, actor: currentUserID(), "template.edited",
                                 "Edited the contract template \(saved.title) (version \(saved.version))")
            }
            list[index] = saved
        } else {
            guard list.count < ContractRules.templateLimit else { throw SlateError.invalidContract }
            saved.version = 1
            saved.createdAt = now
            saved.updatedAt = now
            list.append(saved)
            recordForCompany(template.creatorID, actor: currentUserID(), "template.created", "Added the contract template \(saved.title)")
        }
        try fileManager.createDirectory(at: userDirectory(template.creatorID), withIntermediateDirectories: true)
        try write(list, to: templatesURL(template.creatorID))
        return readTemplates(template.creatorID)
    }

    func deleteContractTemplate(_ id: UUID, for creatorID: UUID) async throws -> [ContractTemplate] {
        try authorizeOwner(creatorID, .templatesManage)
        guard !readPackages(creatorID).contains(where: { $0.contractTemplateID == id }) else {
            throw SlateError.templateInUse
        }
        var list = readTemplates(creatorID)
        if let gone = list.first(where: { $0.id == id }) {
            recordForCompany(creatorID, actor: currentUserID(), "template.deleted", "Deleted the contract template \(gone.title)")
        }
        list.removeAll { $0.id == id }
        try write(list, to: templatesURL(creatorID))
        return readTemplates(creatorID)
    }

    // MARK: Creator signature

    func loadCreatorSignature(for creatorID: UUID) async throws -> CreatorSignature? {
        read(CreatorSignature.self, from: signatureURL(creatorID))
    }

    func saveCreatorSignature(_ signature: CreatorSignature, for creatorID: UUID) async throws {
        guard SignatureRules.isValid(signature) else { throw SlateError.invalidSignature }
        try fileManager.createDirectory(at: userDirectory(creatorID), withIntermediateDirectories: true)
        var stored = signature
        stored.updatedAt = Date()
        try write(stored, to: signatureURL(creatorID))
    }

    // MARK: Contracts

    func readContracts() -> [Contract] {
        read([Contract].self, from: contractsURL) ?? []
    }

    func loadContract(bookingID: UUID, for userID: UUID) async throws -> Contract? {
        let orgs = readOrganizations()
        guard let booking = readBookings().first(where: { $0.id == bookingID }), isParty(userID, booking, .view, in: orgs) else { return nil }
        return readContracts().first { $0.bookingID == bookingID }
    }

    func loadContractPDF(contractID: UUID) async throws -> Data? {
        try? Data(contentsOf: pdfURL(contractID))
    }

    func attachContractPDF(_ data: Data, contractID: UUID) async throws {
        guard readContracts().contains(where: { $0.id == contractID }) else { throw SlateError.invalidContract }
        try fileManager.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
        let url = pdfURL(contractID)
        if fileManager.fileExists(atPath: url.path) { return } // The first PDF stored is the one both parties keep.
        try data.write(to: url, options: .atomic)
    }

    private func pdfURL(_ contractID: UUID) -> URL {
        pdfDirectory.appendingPathComponent("\(contractID.uuidString.lowercased()).pdf")
    }
}

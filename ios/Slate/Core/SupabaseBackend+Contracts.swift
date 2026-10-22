import Foundation
import Supabase

/// Contract templates, the creator's saved signature, signed contracts and their PDFs on Supabase.
///
/// Filling in a contract and recording signatures happen inside the `preview_contract` and
/// `create_booking` SQL functions, so the app can't write a contract row or a signature itself:
/// Row Level Security gives it read access only.
extension SupabaseBackend {
    // MARK: - Rows

    private struct TemplateRow: Codable {
        var id: String
        var creatorId: String
        var title: String
        var kind: String
        var clauses: [ContractClause]
        var version: Int?
        var createdAt: Date?
        var updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, title, kind, clauses, version
            case creatorId = "creator_id"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    /// What changes when a template is edited. The server owns the version, owner and dates.
    private struct TemplateChanges: Encodable {
        var title: String
        var kind: String
        var clauses: [ContractClause]
    }

    private struct SignatureRow: Codable {
        var creatorId: String
        var signedName: String
        var method: String
        var imagePng: String?
        var updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case method
            case creatorId = "creator_id"
            case signedName = "signed_name"
            case imagePng = "image_png"
            case updatedAt = "updated_at"
        }
    }

    struct ContractSignatureRow: Decodable {
        var id: String
        var role: String
        var userId: String?
        var signedName: String
        var method: String
        var imagePng: String?
        var signedAt: Date
        var consentVersion: Int
        var device: String
        var onBehalfOf: String?
        var signerTitle: String?

        enum CodingKeys: String, CodingKey {
            case id, role, method, device
            case onBehalfOf = "on_behalf_of"
            case signerTitle = "signer_title"
            case userId = "user_id"
            case signedName = "signed_name"
            case imagePng = "image_png"
            case signedAt = "signed_at"
            case consentVersion = "consent_version"
        }
    }

    /// A contract as either `create_booking` (signatures under `signatures`) or a table read with
    /// the signatures embedded (under `contract_signatures`) returns it.
    struct ContractRow: Decodable {
        var id: String
        var bookingId: String
        var creatorId: String
        var clientId: String?
        var templateId: String?
        var templateVersion: Int
        var title: String
        var sections: [ContractSection]
        var documentHash: String
        var status: String
        var createdAt: Date
        var executedAt: Date?
        var providerLegalName: String?
        var countersignerId: String?
        var countersignerName: String?
        var countersignerTitle: String?
        var signatures: [ContractSignatureRow]?
        var embeddedSignatures: [ContractSignatureRow]?

        enum CodingKeys: String, CodingKey {
            case id, title, sections, status, signatures
            case providerLegalName = "provider_legal_name"
            case countersignerId = "countersigner_id"
            case countersignerName = "countersigner_name"
            case countersignerTitle = "countersigner_title"
            case bookingId = "booking_id"
            case creatorId = "creator_id"
            case clientId = "client_id"
            case templateId = "template_id"
            case templateVersion = "template_version"
            case documentHash = "document_hash"
            case createdAt = "created_at"
            case executedAt = "executed_at"
            case embeddedSignatures = "contract_signatures"
        }
    }

    /// `preview_contract` returns more than this (the plain text too); the app builds the text itself
    /// from the sections and checks the server's hash against it.
    private struct PreviewRow: Decodable {
        var title: String
        var sections: [ContractSection]
        var documentHash: String
        var templateId: String
        var templateVersion: Int

        enum CodingKeys: String, CodingKey {
            case title, sections
            case documentHash = "document_hash"
            case templateId = "template_id"
            case templateVersion = "template_version"
        }
    }

    private struct PreviewParams: Encodable {
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

    // MARK: - Templates

    func loadContractTemplates(for creatorID: UUID) async throws -> [ContractTemplate] {
        let rows: [TemplateRow] = try await client
            .from("contract_templates")
            .select()
            .eq("creator_id", value: Self.key(creatorID))
            .order("created_at", ascending: true)
            .execute()
            .value
        return try rows.map(makeTemplate)
    }

    func saveContractTemplate(_ template: ContractTemplate) async throws -> [ContractTemplate] {
        guard ContractRules.problems(in: template).isEmpty else { throw SlateError.invalidContract }

        let changes = TemplateChanges(title: template.title, kind: template.kind.rawValue, clauses: template.clauses)
        do {
            // Insert or update is decided here rather than with an upsert: an upsert runs the
            // insert-time checks (such as the limit on how many contracts a creator may keep) even when it
            // turns out to be an edit of an existing row.
            let existing: [IDRow] = try await client
                .from("contract_templates")
                .select("id")
                .eq("id", value: Self.key(template.id))
                .limit(1)
                .execute()
                .value
            if existing.isEmpty {
                let row = TemplateRow(
                    id: Self.key(template.id),
                    creatorId: Self.key(template.creatorID),
                    title: changes.title,
                    kind: changes.kind,
                    clauses: changes.clauses,
                    version: nil, createdAt: nil, updatedAt: nil
                )
                try await client.from("contract_templates").insert(row).execute()
            } else {
                try await client
                    .from("contract_templates")
                    .update(changes)
                    .eq("id", value: Self.key(template.id))
                    .eq("creator_id", value: Self.key(template.creatorID))
                    .execute()
            }
        } catch {
            throw Self.mapBookingError(error)
        }
        return try await loadContractTemplates(for: template.creatorID)
    }

    func deleteContractTemplate(_ id: UUID, for creatorID: UUID) async throws -> [ContractTemplate] {
        do {
            try await client
                .from("contract_templates")
                .delete()
                .eq("id", value: Self.key(id))
                .eq("creator_id", value: Self.key(creatorID))
                .execute()
        } catch {
            // 23503 is foreign_key_violation: a package still uses this contract.
            if "\(error)".contains("23503") { throw SlateError.templateInUse }
            throw error
        }
        return try await loadContractTemplates(for: creatorID)
    }

    private func makeTemplate(_ row: TemplateRow) throws -> ContractTemplate {
        guard let id = UUID(uuidString: row.id), let creatorID = UUID(uuidString: row.creatorId) else {
            throw SlateError.backend("Malformed contract id.")
        }
        return ContractTemplate(
            id: id,
            creatorID: creatorID,
            title: row.title,
            kind: ContractKind(rawValue: row.kind) ?? .custom,
            clauses: row.clauses,
            version: row.version ?? 1,
            createdAt: row.createdAt ?? Date(),
            updatedAt: row.updatedAt ?? Date()
        )
    }

    // MARK: - Creator signature

    func loadCreatorSignature(for creatorID: UUID) async throws -> CreatorSignature? {
        let rows: [SignatureRow] = try await client
            .from("creator_signatures")
            .select()
            .eq("creator_id", value: Self.key(creatorID))
            .limit(1)
            .execute()
            .value
        guard let row = rows.first, let method = SignatureMethod(rawValue: row.method) else { return nil }
        return CreatorSignature(
            signedName: row.signedName,
            method: method,
            imagePNG: row.imagePng.flatMap { Data(base64Encoded: $0) },
            updatedAt: row.updatedAt ?? Date()
        )
    }

    func saveCreatorSignature(_ signature: CreatorSignature, for creatorID: UUID) async throws {
        guard SignatureRules.isValid(signature) else { throw SlateError.invalidSignature }
        let row = SignatureRow(
            creatorId: Self.key(creatorID),
            signedName: signature.signedName.trimmingCharacters(in: .whitespacesAndNewlines),
            method: signature.method.rawValue,
            imagePng: signature.method == .drawn ? signature.imagePNG?.base64EncodedString() : nil,
            updatedAt: nil
        )
        try await client.from("creator_signatures").upsert(row, onConflict: "creator_id").execute()
    }

    // MARK: - Contracts

    func previewContract(_ request: BookingRequest, clientName: String) async throws -> ContractPreview {
        let params = PreviewParams(
            pPackageId: Self.key(request.packageID),
            pAddOnIds: request.addOnIDs.map(Self.key),
            pStartAt: request.startAt,
            pClientName: clientName,
            pNotes: request.notes
        )
        do {
            let row: PreviewRow = try await client.rpc("preview_contract", params: params).execute().value
            let contract = RenderedContract(
                title: row.title,
                sections: row.sections,
                templateID: UUID(uuidString: row.templateId) ?? UUID(),
                templateVersion: row.templateVersion
            )
            // What the person reads and what gets hashed must be the same words. If the server's hash
            // isn't the hash of what we're about to show, don't let anyone sign it.
            guard contract.documentHash == row.documentHash else {
                throw SlateError.backend("This contract couldn't be verified. Please try again.")
            }
            return ContractPreview(contract: contract)
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func loadContract(bookingID: UUID, for userID: UUID) async throws -> Contract? {
        // Row Level Security limits this to contracts the person is a party to.
        let rows: [ContractRow] = try await client
            .from("contracts")
            .select("*, contract_signatures(*)")
            .eq("booking_id", value: Self.key(bookingID))
            .limit(1)
            .execute()
            .value
        return try rows.first.map(makeContract)
    }

    func makeContract(_ row: ContractRow) throws -> Contract {
        guard let id = UUID(uuidString: row.id),
              let bookingID = UUID(uuidString: row.bookingId),
              let creatorID = UUID(uuidString: row.creatorId)
        else { throw SlateError.backend("Malformed contract id.") }

        let signatures: [ContractSignature] = (row.signatures ?? row.embeddedSignatures ?? []).compactMap { signature in
            guard let signatureID = UUID(uuidString: signature.id),
                  let role = SignerRole(rawValue: signature.role),
                  let method = SignatureMethod(rawValue: signature.method)
            else { return nil }
            return ContractSignature(
                id: signatureID,
                role: role,
                userID: signature.userId.flatMap(UUID.init(uuidString:)),
                signedName: signature.signedName,
                method: method,
                imagePNG: signature.imagePng.flatMap { Data(base64Encoded: $0) },
                signedAt: signature.signedAt,
                consentVersion: signature.consentVersion,
                device: signature.device,
                onBehalfOf: signature.onBehalfOf,
                signerTitle: signature.signerTitle.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        // The client's signature first, then the creator's, whichever order the server returned them in.
        .sorted { ($0.signedAt, $0.role.rawValue) < ($1.signedAt, $1.role.rawValue) }

        return Contract(
            id: id,
            bookingID: bookingID,
            creatorID: creatorID,
            clientID: row.clientId.flatMap(UUID.init(uuidString:)),
            templateID: row.templateId.flatMap(UUID.init(uuidString:)),
            templateVersion: row.templateVersion,
            title: row.title,
            sections: row.sections,
            documentHash: row.documentHash,
            status: ContractStatus(rawValue: row.status) ?? .executed,
            signatures: signatures,
            createdAt: row.createdAt,
            executedAt: row.executedAt,
            providerLegalName: row.providerLegalName,
            countersignerID: row.countersignerId.flatMap(UUID.init(uuidString:)),
            countersignerName: row.countersignerName,
            countersignerTitle: row.countersignerTitle.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Signed PDFs

    /// Stored in a private bucket as `<contract id>.pdf`; both parties read the same file.
    private func pdfPath(_ contractID: UUID) -> String { "\(Self.key(contractID)).pdf" }

    func loadContractPDF(contractID: UUID) async throws -> Data? {
        do {
            return try await client.storage.from("contracts").download(path: pdfPath(contractID))
        } catch {
            let text = "\(error)".lowercased()
            if text.contains("404") || text.contains("not found") { return nil }
            throw error
        }
    }

    func attachContractPDF(_ data: Data, contractID: UUID) async throws {
        do {
            try await client.storage.from("contracts").upload(
                pdfPath(contractID),
                data: data,
                options: FileOptions(cacheControl: "31536000", contentType: "application/pdf", upsert: false)
            )
        } catch {
            // The first PDF stored is the one both parties keep, so "already there" is success.
            let text = "\(error)".lowercased()
            if text.contains("duplicate") || text.contains("already exists") || text.contains("409") { return }
            throw error
        }
    }
}

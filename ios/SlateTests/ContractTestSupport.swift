import UIKit
@testable import Slate

/// Shared setup for tests that book. A package can only be sold with a contract, and a contract only
/// works once the creator has a signature on file, so most tests need both.
enum ContractFixtures {
    /// A real (small) PNG, like the ones the drawing pad produces.
    static func pngData(size: CGSize = CGSize(width: 160, height: 60)) -> Data {
        UIGraphicsImageRenderer(size: size).pngData { _ in
            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.lineWidth = 3
            path.move(to: CGPoint(x: 8, y: size.height - 12))
            path.addCurve(
                to: CGPoint(x: size.width - 8, y: 14),
                controlPoint1: CGPoint(x: size.width * 0.3, y: 0),
                controlPoint2: CGPoint(x: size.width * 0.6, y: size.height)
            )
            path.stroke()
        }
    }

    static func typedSignature(hash: String, name: String = "Sam Client") -> SignatureInput {
        SignatureInput(documentHash: hash, signedName: name, method: .typed, imagePNG: nil, device: "Test device")
    }

    static func drawnSignature(hash: String, name: String = "Sam Client") -> SignatureInput {
        SignatureInput(documentHash: hash, signedName: name, method: .drawn, imagePNG: pngData(), device: "Test device")
    }

    static func creatorSignature(name: String = "Maya Chen", method: SignatureMethod = .typed) -> CreatorSignature {
        CreatorSignature(
            signedName: name,
            method: method,
            imagePNG: method == .drawn ? pngData() : nil,
            updatedAt: Date()
        )
    }

    /// Gives a creator a signature on file and a contract, and returns the contract to point packages at.
    @discardableResult
    static func equip(
        _ backend: any SlateBackend, creatorID: UUID, kind: ContractKind = .photography,
        signature: CreatorSignature? = nil
    ) async throws -> ContractTemplate {
        try await backend.saveCreatorSignature(signature ?? creatorSignature(), for: creatorID)
        let template = StarterTemplates.make(kind, creatorID: creatorID)
        let saved = try await backend.saveContractTemplate(template)
        return saved.first { $0.id == template.id } ?? template
    }

    /// What a client does: read the contract as the backend fills it in, then sign what they read.
    static func signedBooking(
        _ backend: any SlateBackend, _ request: BookingRequest,
        clientID: UUID = UUID(), name: String = "Sam Client"
    ) async throws -> SignedBooking {
        let preview = try await backend.previewContract(request, clientName: name)
        return try await backend.createBooking(
            request, clientID: clientID, clientName: name,
            signature: typedSignature(hash: preview.documentHash, name: name)
        )
    }
}

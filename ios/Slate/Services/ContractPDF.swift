import CoreText
import UIKit

/// Turns a signed contract into a PDF: the agreement as real, searchable text across as many pages as it needs,
/// then a page of signatures and a certificate (who signed, how, when, and the hash that identifies the exact text).
enum ContractPDF {
    static let pageSize = CGSize(width: 612, height: 792) // US Letter
    private static let margin: CGFloat = 54
    private static let footerSpace: CGFloat = 24

    static func render(_ contract: Contract, creatorName: String, clientName: String) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: contract.title,
            kCGPDFContextAuthor as String: creatorName,
            kCGPDFContextSubject as String: "Agreement between \(creatorName) and \(clientName)",
            kCGPDFContextCreator as String: "Slate Pro",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        return renderer.pdfData { context in
            let body = bodyText(contract, creatorName: creatorName, clientName: clientName)
            var page = 0

            // The agreement itself, flowing across pages.
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var location = 0
            repeat {
                context.beginPage()
                page += 1
                let cg = context.cgContext
                cg.saveGState()
                // CoreText draws with a bottom-left origin; UIKit's PDF context is top-left.
                cg.translateBy(x: 0, y: pageSize.height)
                cg.scaleBy(x: 1, y: -1)
                let textRect = CGRect(
                    x: margin, y: margin + footerSpace,
                    width: pageSize.width - margin * 2, height: pageSize.height - margin * 2 - footerSpace
                )
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), CGPath(rect: textRect, transform: nil), nil)
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()
                drawFooter(contract, page: page)
                if visible.length == 0 { break }
                location += visible.length
            } while location < body.length

            // Signatures and certificate.
            context.beginPage()
            page += 1
            drawSignaturePage(contract, creatorName: creatorName, clientName: clientName)
            drawFooter(contract, page: page)
        }
    }

    // MARK: Body

    private static func bodyText(_ contract: Contract, creatorName: String, clientName: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 6
        result.append(NSAttributedString(string: contract.title + "\n", attributes: [
            .font: PDFFonts.bold(22), .foregroundColor: UIColor.black, .paragraphStyle: titleStyle,
        ]))
        result.append(NSAttributedString(string: "\(creatorName) and \(clientName)\n\n", attributes: [
            .font: PDFFonts.regular(11), .foregroundColor: UIColor.darkGray,
        ]))

        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 10
        headingStyle.paragraphSpacing = 3

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 2.5
        bodyStyle.paragraphSpacing = 4

        for (index, section) in contract.sections.enumerated() {
            result.append(NSAttributedString(string: "\(index + 1). \(section.title)\n", attributes: [
                .font: PDFFonts.semibold(13), .foregroundColor: UIColor.black, .paragraphStyle: headingStyle,
            ]))
            result.append(NSAttributedString(string: section.body + "\n", attributes: [
                .font: PDFFonts.regular(11), .foregroundColor: UIColor.black, .paragraphStyle: bodyStyle,
            ]))
        }
        return result
    }

    private static func drawFooter(_ contract: Contract, page: Int) {
        let text = "\(contract.title)  ·  Document \(String(contract.documentHash.prefix(12)))  ·  Page \(page)"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (text as NSString).draw(
            in: CGRect(x: margin, y: pageSize.height - margin + 6, width: pageSize.width - margin * 2, height: 14),
            withAttributes: [.font: PDFFonts.regular(8.5), .foregroundColor: UIColor.gray, .paragraphStyle: style]
        )
    }

    // MARK: Signatures and certificate

    private static func drawSignaturePage(_ contract: Contract, creatorName: String, clientName: String) {
        var y = margin
        let width = pageSize.width - margin * 2

        func draw(_ text: String, font: UIFont, color: UIColor = .black, spacingAfter: CGFloat = 4) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: attributes, context: nil
            )
            (text as NSString).draw(in: CGRect(x: margin, y: y, width: width, height: ceil(rect.height)), withAttributes: attributes)
            y += ceil(rect.height) + spacingAfter
        }

        draw("Signatures", font: PDFFonts.bold(20), spacingAfter: 4)
        draw("\(contract.title), between \(contract.providerLegalName ?? creatorName) and \(clientName).", font: PDFFonts.regular(11), color: .darkGray, spacingAfter: 14)

        for role in [SignerRole.client, .creator] {
            guard let signature = contract.signature(for: role) else { continue }
            draw("\(role.title): \(signature.signedName)", font: PDFFonts.semibold(13), spacingAfter: signature.onBehalfOf == nil ? 6 : 2)
            if let company = signature.onBehalfOf {
                // A company's contract is signed for the company by a person, who signs with their title.
                var line = "For \(company)"
                if let title = signature.signerTitle, !title.isEmpty { line += ", \(title)" }
                draw(line, font: PDFFonts.regular(11), color: .darkGray, spacingAfter: 6)
            }

            let box = CGRect(x: margin, y: y, width: 260, height: 66)
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 6).fill()
            drawSignatureMark(signature, in: box.insetBy(dx: 10, dy: 6))
            y += box.height + 8

            draw(methodDescription(signature), font: PDFFonts.regular(10), color: .darkGray, spacingAfter: 1)
            draw("Signed \(ContractFormat.timestampUTC(signature.signedAt))", font: PDFFonts.regular(10), color: .darkGray, spacingAfter: 1)
            draw(signature.device, font: PDFFonts.regular(10), color: .darkGray, spacingAfter: 14)
        }

        // Certificate
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: y))
        rule.addLine(to: CGPoint(x: margin + width, y: y))
        UIColor.lightGray.setStroke()
        rule.lineWidth = 0.5
        rule.stroke()
        y += 12

        draw("Certificate of completion", font: PDFFonts.semibold(15), spacingAfter: 6)
        let mono = PDFFonts.mono(9)
        draw("Status: \(contract.status.title)", font: PDFFonts.regular(10), spacingAfter: 2)
        draw("Document ID: \(contract.id.uuidString.lowercased())", font: mono, spacingAfter: 2)
        draw("Booking ID: \(contract.bookingID.uuidString.lowercased())", font: mono, spacingAfter: 2)
        draw("Template version: \(contract.templateVersion)", font: PDFFonts.regular(10), spacingAfter: 2)
        draw("Created: \(ContractFormat.timestampUTC(contract.createdAt))", font: PDFFonts.regular(10), spacingAfter: 2)
        if let executed = contract.executedAt {
            draw("Completed: \(ContractFormat.timestampUTC(executed))", font: PDFFonts.regular(10), spacingAfter: 2)
        }
        draw("SHA-256 of the agreement text:", font: PDFFonts.regular(10), spacingAfter: 2)
        draw(contract.documentHash, font: mono, spacingAfter: 8)
        draw(
            "The hash identifies the exact wording both parties signed. If a single character of the agreement changed, the hash would not match. Consent wording version \(contract.signatures.first?.consentVersion ?? SigningConsent.version): \"\(SigningConsent.text)\"",
            font: PDFFonts.regular(9), color: .darkGray
        )
    }

    private static func methodDescription(_ signature: ContractSignature) -> String {
        switch signature.method {
        case .typed: "Signed by typing their full name"
        case .drawn: "Signed by drawing their signature"
        case .onFile: "Signature saved in advance by the Creator and applied under their standing authorization"
        }
    }

    private static func drawSignatureMark(_ signature: ContractSignature, in rect: CGRect) {
        if let data = signature.imagePNG, let image = UIImage(data: data) {
            drawFitted(image, in: rect)
        } else {
            drawFitted(typedSignatureImage(signature.signedName), in: rect)
        }
    }

    private static func drawFitted(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// A typed signature is drawn as a picture of the name, not as text. Text would copy a piece of the script font (one that
    /// belongs to iOS) into every contract PDF that is sent to someone; a picture carries no font.
    private static func typedSignatureImage(_ name: String) -> UIImage {
        let font = UIFont(name: "SnellRoundhand-Bold", size: 28) ?? UIFont.italicSystemFont(ofSize: 24)
        let text = NSAttributedString(
            string: name,
            attributes: [.font: font, .foregroundColor: UIColor(red: 0.08, green: 0.12, blue: 0.35, alpha: 1)]
        )
        let size = text.size()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: max(ceil(size.width), 1), height: max(ceil(size.height), 1)), format: format)
            .image { _ in text.draw(at: .zero) }
    }
}

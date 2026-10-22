import Foundation

/// Ready-made contracts a creator can copy and edit. They are plain-language starting points,
/// not legal advice: creators should have a lawyer review them for their own situation and region.
enum StarterTemplates {
    static let disclaimer = "Starter contracts are plain-language templates, not legal advice. Have a lawyer review yours for your business and where you work."

    static let kinds: [ContractKind] = [.photography, .videography, .freelance]

    /// A fresh, creator-owned copy with new identifiers.
    static func make(_ kind: ContractKind, creatorID: UUID, now: Date = Date()) -> ContractTemplate {
        let source = content(for: kind)
        return ContractTemplate(
            id: UUID(),
            creatorID: creatorID,
            title: source.title,
            kind: kind,
            clauses: source.clauses.map { ContractClause(title: $0.title, body: $0.body) },
            version: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    /// A blank contract with the essentials already in it.
    static func blank(creatorID: UUID, now: Date = Date()) -> ContractTemplate {
        ContractTemplate(
            id: UUID(),
            creatorID: creatorID,
            title: "Service agreement",
            kind: .custom,
            clauses: [
                ContractClause(
                    title: "Parties",
                    body: "This agreement is between {{creator_name}} (the \"Creator\") and {{client_name}} (the \"Client\") for the \"{{package_name}}\" package."
                ),
                ContractClause(
                    title: "The booking",
                    body: "Date: {{booking_date}}\nTime: {{booking_time}} ({{time_zone}})\nTotal: {{price}}"
                ),
                ContractClause(title: "Cancellation", body: "{{cancellation_policy}}"),
            ],
            version: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    private struct Source {
        var title: String
        var clauses: [(title: String, body: String)]
    }

    private static func content(for kind: ContractKind) -> Source {
        switch kind {
        case .photography: return photography
        case .videography: return videography
        case .freelance, .custom: return freelance
        }
    }

    // MARK: Photography

    private static let photography = Source(
        title: "Photography services agreement",
        clauses: [
            ("Parties",
             "This agreement is between {{creator_name}} (the \"Creator\") and {{client_name}} (the \"Client\"). It covers the \"{{package_name}}\" package and takes effect once both parties have signed."),
            ("The shoot",
             "Date: {{booking_date}}\nTime: {{booking_time}} ({{time_zone}})\nLength: {{duration}}\n\nThe Creator will arrive on time and photograph for the booked length. If the Client is late, the shoot still ends at the booked time unless the Creator agrees to extend it.\n\nNotes from the Client: {{client_notes}}"),
            ("Deliverables",
             "The Creator will deliver:\n{{deliverables}}\n\nAdd-ons:\n{{add_ons}}\n\nFinished photos are delivered within {{turnaround}} of the shoot, by {{delivery_date}}. Editing style and the final selection of images are at the Creator's discretion."),
            ("Fees and payment",
             "Total fee: {{price}}. A deposit of {{deposit}} is due when this agreement is signed and secures the date. The balance of {{balance}} is due when the finished photos are delivered."),
            ("Cancellation and rescheduling",
             "{{cancellation_policy}}\n\nThe date may be moved once, free of charge, if both parties agree on a new date the Creator has available."),
            ("Usage rights", "{{usage_rights}}"),
            ("Client responsibilities",
             "The Client will provide a schedule, access to locations and any permits needed, and will make sure the people to be photographed are available at the agreed times."),
            ("Illness and unforeseen events",
             "If the Creator cannot attend because of illness, an emergency or something outside their control, the Creator will try to send a suitable replacement. If that is not possible, the Client receives a full refund of the amounts paid."),
            ("Liability",
             "The Creator will take reasonable care of all images. If images are lost or damaged in a way the Creator could not reasonably prevent, the Creator's liability is limited to the amount the Client has paid."),
            ("Whole agreement and electronic signature",
             "This is the whole agreement between the parties. Changes must be agreed in writing. Both parties agree to sign electronically and that an electronic signature is as binding as a handwritten one."),
        ]
    )

    // MARK: Videography

    private static let videography = Source(
        title: "Videography services agreement",
        clauses: [
            ("Parties",
             "This agreement is between {{creator_name}} (the \"Creator\") and {{client_name}} (the \"Client\"). It covers the \"{{package_name}}\" package and takes effect once both parties have signed."),
            ("The shoot",
             "Date: {{booking_date}}\nTime: {{booking_time}} ({{time_zone}})\nLength: {{duration}}\n\nThe Creator will film for the booked length. If the Client is late, filming still ends at the booked time unless the Creator agrees to extend it. Drone footage is included only where listed below and only where it is legal and safe to fly.\n\nNotes from the Client: {{client_notes}}"),
            ("Deliverables",
             "The Creator will deliver:\n{{deliverables}}\n\nAdd-ons:\n{{add_ons}}\n\nThe finished video is delivered within {{turnaround}} of the shoot, by {{delivery_date}}. Unedited (raw) footage is not included unless it is listed above."),
            ("Revisions",
             "The price includes one round of reasonable revisions to the finished video, requested in writing within 7 days of delivery. Further changes or re-edits may be charged separately."),
            ("Fees and payment",
             "Total fee: {{price}}. A deposit of {{deposit}} is due when this agreement is signed and secures the date. The balance of {{balance}} is due when the finished video is delivered."),
            ("Cancellation and rescheduling",
             "{{cancellation_policy}}\n\nThe date may be moved once, free of charge, if both parties agree on a new date the Creator has available."),
            ("Usage rights and music",
             "{{usage_rights}}\n\nMusic and other third-party material in the video is licensed for the uses above only. The Client must not use the video in ways that would breach those licenses."),
            ("Client responsibilities",
             "The Client will provide a schedule, access to locations, any permits or permissions needed to film, and will make sure the people appearing are available and happy to be filmed."),
            ("Illness and unforeseen events",
             "If the Creator cannot attend because of illness, an emergency or something outside their control, the Creator will try to send a suitable replacement. If that is not possible, the Client receives a full refund of the amounts paid."),
            ("Liability",
             "The Creator will take reasonable care of all footage and keep a backup until delivery. If footage is lost or damaged in a way the Creator could not reasonably prevent, the Creator's liability is limited to the amount the Client has paid."),
            ("Whole agreement and electronic signature",
             "This is the whole agreement between the parties. Changes must be agreed in writing. Both parties agree to sign electronically and that an electronic signature is as binding as a handwritten one."),
        ]
    )

    // MARK: General freelance

    private static let freelance = Source(
        title: "Freelance services agreement",
        clauses: [
            ("Parties",
             "This agreement is between {{creator_name}} (the \"Creator\") and {{client_name}} (the \"Client\"). The Creator is an independent contractor, not an employee of the Client. It covers the \"{{package_name}}\" package and takes effect once both parties have signed."),
            ("Scope of work",
             "The Creator will provide:\n{{deliverables}}\n\nAdd-ons:\n{{add_ons}}\n\nAnything not listed here is outside the scope and may be quoted separately.\n\nNotes from the Client: {{client_notes}}"),
            ("Schedule",
             "Work begins on {{booking_date}} ({{booking_time}}, {{time_zone}}) and is expected to take {{duration}}. Final work is delivered within {{turnaround}}, by {{delivery_date}}, provided the Client supplies what the Creator needs in good time."),
            ("Fees and payment",
             "Total fee: {{price}}. A deposit of {{deposit}} is due when this agreement is signed. The balance of {{balance}} is due when the final work is delivered."),
            ("Revisions",
             "The fee includes one round of reasonable revisions requested in writing within 7 days of delivery. Further revisions may be charged separately."),
            ("Ownership and rights", "{{usage_rights}}"),
            ("Confidentiality",
             "Each party will keep the other's non-public business information confidential and use it only for this work."),
            ("Cancellation",
             "{{cancellation_policy}}"),
            ("Liability",
             "The Creator will do the work with reasonable skill and care. Except where the law does not allow it, the Creator's liability is limited to the amount the Client has paid."),
            ("Whole agreement and electronic signature",
             "This is the whole agreement between the parties. Changes must be agreed in writing. Both parties agree to sign electronically and that an electronic signature is as binding as a handwritten one."),
        ]
    )
}

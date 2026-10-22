import XCTest
@testable import Slate

final class CancellationPolicyTests: XCTestCase {
    func testFlexibleRefundsInFullUntilADayBefore() {
        let policy = CancellationPolicy.flexible
        XCTAssertEqual(policy.refundPercent(hoursBefore: 24), 100)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 23.99), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 0), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: -5), 50, "Even after the start time, half")
    }

    func testModerateHasThreeSteps() {
        let policy = CancellationPolicy.moderate
        XCTAssertEqual(policy.refundPercent(hoursBefore: 24 * 30), 100)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 168), 100)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 167.9), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 48), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 47.9), 0)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 0), 0)
    }

    func testStrictNeverRefundsMoreThanHalf() {
        let policy = CancellationPolicy.strict
        XCTAssertEqual(policy.refundPercent(hoursBefore: 24 * 365), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 336), 50)
        XCTAssertEqual(policy.refundPercent(hoursBefore: 335.9), 0)
    }

    func testWaitingNeverGetsYouMoreMoneyBack() {
        for policy in CancellationPolicy.allCases {
            var previous = 101
            for hours in stride(from: 1_000.0, through: 0, by: -0.5) {
                let percent = policy.refundPercent(hoursBefore: hours)
                XCTAssertLessThanOrEqual(percent, previous, "\(policy) at \(hours)h")
                XCTAssertTrue((0...100).contains(percent))
                previous = percent
            }
        }
    }

    func testTiersListTheMostGenerousFirstAndEndAtZeroHours() {
        for policy in CancellationPolicy.allCases {
            let thresholds = policy.tiers.map(\.minHoursBefore)
            XCTAssertEqual(thresholds, thresholds.sorted(by: >), "\(policy)")
            XCTAssertEqual(thresholds.last, 0, "\(policy) must cover every case")
        }
    }

    func testTheContractWordsMatchTheNumbers() {
        XCTAssertTrue(CancellationPolicy.flexible.contractText.contains("24 hours"))
        XCTAssertTrue(CancellationPolicy.moderate.contractText.contains("7 days"))
        XCTAssertTrue(CancellationPolicy.moderate.contractText.contains("48 hours"))
        XCTAssertTrue(CancellationPolicy.strict.contractText.contains("14 days"))
        for policy in CancellationPolicy.allCases {
            XCTAssertTrue(policy.contractText.hasPrefix(policy.title + "."))
            XCTAssertTrue(policy.contractText.contains("If the Creator cancels, the Client receives a full refund."))
        }
    }

    func testUsageRightsAreWordedForEveryChoice() {
        for rights in UsageRights.allCases {
            XCTAssertTrue(rights.contractText.hasPrefix(rights.title), "\(rights) starts by naming itself")
            XCTAssertTrue(rights.contractText.contains("Creator"), "\(rights) says who keeps what")
        }
    }
}

final class SignatureRulesTests: XCTestCase {
    private let png = ContractFixtures.pngData()

    func testTypedNeedsOnlyAName() {
        XCTAssertTrue(SignatureRules.isValid(name: "Al", method: .typed, imagePNG: nil))
        XCTAssertTrue(SignatureRules.isValid(name: String(repeating: "x", count: 80), method: .typed, imagePNG: nil))
        XCTAssertFalse(SignatureRules.isValid(name: "A", method: .typed, imagePNG: nil))
        XCTAssertFalse(SignatureRules.isValid(name: "   A   ", method: .typed, imagePNG: nil), "Spaces don't count")
        XCTAssertFalse(SignatureRules.isValid(name: String(repeating: "x", count: 81), method: .typed, imagePNG: nil))
        XCTAssertFalse(SignatureRules.isValid(name: "", method: .typed, imagePNG: nil))
    }

    func testDrawnNeedsARealPNGThatIsNotTooBig() {
        XCTAssertTrue(SignatureRules.isPNG(png))
        XCTAssertTrue(SignatureRules.isValid(name: "Sam Client", method: .drawn, imagePNG: png))
        XCTAssertFalse(SignatureRules.isValid(name: "Sam Client", method: .drawn, imagePNG: nil))
        XCTAssertFalse(SignatureRules.isValid(name: "Sam Client", method: .drawn, imagePNG: Data("not an image".utf8)))
        XCTAssertFalse(SignatureRules.isPNG(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "A header and nothing else isn't an image")
        var huge = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        huge.append(Data(count: SignatureRules.maxImageBytes))
        XCTAssertFalse(SignatureRules.isValid(name: "Sam Client", method: .drawn, imagePNG: huge))
    }

    func testOnFileCanNeverBeGivenByAClient() {
        XCTAssertFalse(SignatureRules.isValid(name: "Sam Client", method: .onFile, imagePNG: nil))
        XCTAssertFalse(SignatureRules.isValid(name: "Sam Client", method: .onFile, imagePNG: png))
        XCTAssertFalse(SignatureRules.isValid(ContractFixtures.typedSignature(hash: "x").with(method: .onFile)))
    }

    func testCreatorSignaturesFollowTheSameRules() {
        XCTAssertTrue(SignatureRules.isValid(ContractFixtures.creatorSignature()))
        XCTAssertTrue(SignatureRules.isValid(ContractFixtures.creatorSignature(method: .drawn)))
        XCTAssertFalse(SignatureRules.isValid(CreatorSignature(signedName: "M", method: .typed, imagePNG: nil, updatedAt: Date())))
        XCTAssertFalse(SignatureRules.isValid(CreatorSignature(signedName: "Maya", method: .drawn, imagePNG: nil, updatedAt: Date())))
    }
}

extension SignatureInput {
    fileprivate func with(method: SignatureMethod) -> SignatureInput {
        var copy = self
        copy.method = method
        return copy
    }
}

final class ContractRulesTests: XCTestCase {
    private func template(
        title: String = "Agreement",
        clauses: [ContractClause]? = nil
    ) -> ContractTemplate {
        ContractTemplate(
            id: UUID(), creatorID: UUID(), title: title, kind: .custom,
            clauses: clauses ?? [
                ContractClause(title: "All of it", body: "{{creator_name}} and {{client_name}}: {{package_name}} on {{booking_date}} for {{price}}. {{cancellation_policy}}"),
            ],
            version: 1, createdAt: Date(), updatedAt: Date()
        )
    }

    func testAContractWithTheSixEssentialsIsValid() {
        XCTAssertEqual(ContractRules.problems(in: template()), [])
        XCTAssertEqual(ContractField.required.count, 6)
    }

    func testEachMissingEssentialIsReported() {
        let bare = template(clauses: [ContractClause(title: "Only", body: "Just words.")])
        let problems = ContractRules.problems(in: bare)
        for field in ContractField.required {
            XCTAssertTrue(problems.contains(.missingRequired(field)), "\(field)")
        }
    }

    func testAnEssentialInASectionHeadingCounts() {
        let clauses = [
            ContractClause(title: "{{client_name}}", body: "{{creator_name}} {{package_name}} {{booking_date}} {{price}} {{cancellation_policy}}"),
        ]
        XCTAssertEqual(ContractRules.problems(in: template(clauses: clauses)), [])
    }

    func testUnknownPlaceholdersAreRejectedWithTheirName() {
        var t = template()
        t.clauses[0].body += " {{not_real}} {{ price }}"
        let problems = ContractRules.problems(in: t)
        XCTAssertTrue(problems.contains(.unknownPlaceholder("not_real")))
        XCTAssertTrue(problems.contains(.unknownPlaceholder(" price ")), "Spaces inside the braces make it a different, unknown name")
    }

    func testTitleAndSectionLimits() {
        XCTAssertTrue(ContractRules.problems(in: template(title: "A")).contains(.title))
        XCTAssertTrue(ContractRules.problems(in: template(title: String(repeating: "x", count: 81))).contains(.title))
        XCTAssertTrue(ContractRules.problems(in: template(clauses: [])).contains(.noClauses))

        var t = template()
        t.clauses.append(ContractClause(title: " ", body: "x"))
        XCTAssertTrue(ContractRules.problems(in: t).contains(.clauseTitle))
        t.clauses[1] = ContractClause(title: "Empty", body: "  \n ")
        XCTAssertTrue(ContractRules.problems(in: t).contains(.clauseBody))
        t.clauses[1] = ContractClause(title: "Long", body: String(repeating: "x", count: 3_001))
        XCTAssertTrue(ContractRules.problems(in: t).contains(.clauseBodyTooLong))

        let many = (0...ContractRules.clauseLimit).map { ContractClause(title: "S\($0)", body: "text") }
        let manyTemplate = template(clauses: [template().clauses[0]] + many)
        XCTAssertTrue(ContractRules.problems(in: manyTemplate).contains(.tooManyClauses))
    }

    func testEveryProblemHasAReadableMessage() {
        let all: [ContractRules.Problem] = [
            .title, .noClauses, .tooManyClauses, .clauseTitle, .clauseBody, .clauseBodyTooLong,
            .unknownPlaceholder("zzz"), .missingRequired(.price),
        ]
        for problem in all { XCTAssertFalse(problem.message.isEmpty) }
        XCTAssertTrue(ContractRules.Problem.unknownPlaceholder("zzz").message.contains("{{zzz}}"))
        XCTAssertTrue(ContractRules.Problem.missingRequired(.price).message.contains("{{price}}"))
    }
}

final class StarterTemplateTests: XCTestCase {
    func testThereIsOneForPhotographyVideographyAndGeneralFreelanceWork() {
        XCTAssertEqual(StarterTemplates.kinds, [.photography, .videography, .freelance])
        let titles = StarterTemplates.kinds.map { StarterTemplates.make($0, creatorID: UUID()).title }
        XCTAssertEqual(Set(titles).count, 3)
        XCTAssertTrue(titles[0].localizedCaseInsensitiveContains("photography"))
        XCTAssertTrue(titles[1].localizedCaseInsensitiveContains("videography"))
        XCTAssertTrue(titles[2].localizedCaseInsensitiveContains("freelance"))
    }

    func testEveryStarterPassesTheSameRulesAsAnythingACreatorWrites() {
        for kind in StarterTemplates.kinds {
            let template = StarterTemplates.make(kind, creatorID: UUID())
            XCTAssertEqual(ContractRules.problems(in: template), [], "\(kind)")
            XCTAssertEqual(template.kind, kind)
            XCTAssertGreaterThanOrEqual(template.clauses.count, 8)
        }
        XCTAssertEqual(ContractRules.problems(in: StarterTemplates.blank(creatorID: UUID())), [])
    }

    func testStartersCoverEveryPlaceholderTheBriefAsksFor() {
        // Client name, date, package, deliverables, price, deposit, cancellation policy and usage rights.
        let needed: [ContractField] = [.clientName, .bookingDate, .packageName, .deliverables, .price, .deposit, .cancellationPolicy, .usageRights]
        for kind in StarterTemplates.kinds {
            let used = ContractRenderer.tokens(in: StarterTemplates.make(kind, creatorID: UUID()))
            for field in needed {
                XCTAssertTrue(used.contains(field.rawValue), "\(kind) never mentions \(field.token)")
            }
        }
    }

    func testStartersReadSensiblyWithEverythingFilledIn() {
        for kind in StarterTemplates.kinds {
            let template = StarterTemplates.make(kind, creatorID: UUID())
            let rendered = ContractRenderer.render(template: template, values: ContractContextBuilder.sample)
            XCTAssertFalse(rendered.text.contains("{{"), "\(kind)")
            XCTAssertTrue(rendered.text.contains("Alex Rivera"))
            XCTAssertTrue(rendered.text.contains("$3,200"))
            XCTAssertTrue(rendered.sections.allSatisfy { !$0.body.isEmpty })
        }
    }

    func testEachStarterIsAFreshCopy() {
        let creator = UUID()
        let one = StarterTemplates.make(.photography, creatorID: creator)
        let two = StarterTemplates.make(.photography, creatorID: creator)
        XCTAssertNotEqual(one.id, two.id)
        XCTAssertEqual(Set(one.clauses.map(\.id)).intersection(two.clauses.map(\.id)), [])
        XCTAssertEqual(one.creatorID, creator)
        XCTAssertEqual(one.version, 1)
    }

    func testTheKindsHaveTheirOwnWording() {
        let video = StarterTemplates.make(.videography, creatorID: UUID())
        XCTAssertTrue(video.clauses.contains { $0.title == "Revisions" })
        XCTAssertTrue(video.clauses.contains { $0.body.localizedCaseInsensitiveContains("music") })
        let photo = StarterTemplates.make(.photography, creatorID: UUID())
        XCTAssertFalse(photo.clauses.contains { $0.title == "Revisions" })
        let freelance = StarterTemplates.make(.freelance, creatorID: UUID())
        XCTAssertTrue(freelance.clauses.contains { $0.body.contains("independent contractor") })
        XCTAssertTrue(freelance.clauses.contains { $0.title == "Confidentiality" })
    }

    func testTheDisclaimerSaysThisIsNotLegalAdvice() {
        XCTAssertTrue(StarterTemplates.disclaimer.localizedCaseInsensitiveContains("not legal advice"))
    }
}

import XCTest
@testable import Slate

/// The words of a contract must be identical on every device and on the server, because the hash
/// of those words is what gets signed. These tests pin the formatting down.
final class ContractFormatTests: XCTestCase {
    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private let chicago = TimeZone(identifier: "America/Chicago")!

    func testMoneyIsLocaleFreeAndDropsEmptyCents() {
        XCTAssertEqual(ContractFormat.money(cents: 240_000, code: "USD"), "$2,400")
        XCTAssertEqual(ContractFormat.money(cents: 240_050, code: "USD"), "$2,400.50")
        XCTAssertEqual(ContractFormat.money(cents: 5, code: "USD"), "$0.05")
        XCTAssertEqual(ContractFormat.money(cents: 0, code: "USD"), "$0")
        XCTAssertEqual(ContractFormat.money(cents: 15_050, code: "EUR"), "EUR 150.50")
        XCTAssertEqual(ContractFormat.money(cents: 123_456_789, code: "USD"), "$1,234,567.89")
        XCTAssertEqual(ContractFormat.money(cents: 100_000_000, code: "GBP"), "GBP 1,000,000")
        XCTAssertEqual(ContractFormat.money(cents: 99_900, code: "USD"), "$999")
    }

    func testDatesUseTheShootsOwnTimeZoneNotTheDevices() {
        let start = utc("2027-06-12T15:00:00Z")
        XCTAssertEqual(ContractFormat.longDate(start, in: chicago), "Saturday, June 12, 2027")
        XCTAssertEqual(ContractFormat.time(start, in: chicago), "10:00 AM")
        // The same instant, a few time zones east, is already the next day.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ContractFormat.longDate(start, in: tokyo), "Sunday, June 13, 2027")
        XCTAssertEqual(ContractFormat.time(start, in: tokyo), "12:00 AM")
    }

    func testTwelveHourClockEdges() {
        XCTAssertEqual(ContractFormat.time(utc("2027-01-05T06:05:00Z"), in: chicago), "12:05 AM")
        XCTAssertEqual(ContractFormat.time(utc("2027-01-05T18:00:00Z"), in: chicago), "12:00 PM")
        XCTAssertEqual(ContractFormat.time(utc("2027-01-05T15:05:00Z"), in: chicago), "9:05 AM")
        XCTAssertEqual(ContractFormat.time(utc("2027-01-06T05:59:00Z"), in: chicago), "11:59 PM")
    }

    func testATimeRangeUsesAnEnDashAndCanCrossMidnight() {
        let start = utc("2027-01-05T05:30:00Z") // 11:30 PM on the 4th in Chicago
        XCTAssertEqual(
            ContractFormat.timeRange(start: start, end: start.addingTimeInterval(7200), in: chicago),
            "11:30 PM \u{2013} 1:30 AM"
        )
    }

    func testDurationAndDaysReadNaturally() {
        XCTAssertEqual(ContractFormat.duration(minutes: 15), "15 minutes")
        XCTAssertEqual(ContractFormat.duration(minutes: 60), "1 hour")
        XCTAssertEqual(ContractFormat.duration(minutes: 90), "1 hour 30 minutes")
        XCTAssertEqual(ContractFormat.duration(minutes: 121), "2 hours 1 minute")
        XCTAssertEqual(ContractFormat.duration(minutes: 480), "8 hours")
        XCTAssertEqual(ContractFormat.days(1), "1 day")
        XCTAssertEqual(ContractFormat.days(14), "14 days")
    }

    func testTimestampsAreUnambiguousUTC() {
        XCTAssertEqual(ContractFormat.timestampUTC(Date(timeIntervalSince1970: 0)), "1970-01-01 00:00:00 UTC")
        XCTAssertEqual(ContractFormat.timestampUTC(utc("2027-06-12T15:04:05Z")), "2027-06-12 15:04:05 UTC")
    }

    // MARK: Sanitizing person-supplied text

    func testSanitizeCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(ContractFormat.sanitize("  Alex \t  Rivera \n"), "Alex Rivera")
        XCTAssertEqual(ContractFormat.sanitize("\n\n"), "")
    }

    func testSanitizeKeepsLineBreaksForNotesButNormalizesThem() {
        XCTAssertEqual(ContractFormat.sanitize("  one\r\ntwo\rthree\n\nfour  \n", keepLineBreaks: true), "one\ntwo\nthree\n\nfour")
        XCTAssertEqual(ContractFormat.sanitize("a    b", keepLineBreaks: true), "a    b", "Only line breaks are kept, spaces inside a line are left alone")
    }

    func testSanitizeBreaksUpBracesSoNoPlaceholderCanBeWritten() {
        XCTAssertEqual(ContractFormat.sanitize("{{price}}"), "{ {price} }")
        XCTAssertEqual(ContractFormat.sanitize("{{{x}}}"), "{ { {x} } }")
        XCTAssertEqual(ContractFormat.sanitize("{x}"), "{x}", "Single braces are fine")
        XCTAssertEqual(ContractFormat.sanitize("{{price}}", keepLineBreaks: true), "{ {price} }")
    }

    func testSanitizeOnlyTreatsASCIIWhitespaceAsWhitespaceSoServerAndDeviceAgree() {
        let nbsp = "a\u{00A0}\u{00A0}b"
        XCTAssertEqual(ContractFormat.sanitize(nbsp), nbsp)
    }

    /// Every short string over a nasty alphabet: nothing that comes out can open or close a
    /// placeholder, nothing starts or ends with whitespace, and cleaning twice changes nothing.
    func testSanitizeInvariantsHoldForEveryShortString() {
        let alphabet = ["{", "}", " ", "a", "\n", "\r"]
        var inputs: [String] = [""]
        var frontier = [""]
        for _ in 0..<5 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + $0 } }
            inputs += frontier
        }
        XCTAssertEqual(inputs.count, 9_331)

        let edges = CharacterSet(charactersIn: " \t\n\r")
        var failures: [String] = []
        for input in inputs {
            for keep in [false, true] {
                let clean = ContractFormat.sanitize(input, keepLineBreaks: keep)
                let scalars = clean.unicodeScalars
                var broken: [String] = []
                if clean.contains("{{") || clean.contains("}}") { broken.append("braces") }
                if scalars.contains("\r") { broken.append("carriage return") }
                if !keep, scalars.contains("\n") { broken.append("line break") }
                if clean.rangeOfCharacter(from: edges, options: .anchored) != nil { broken.append("leading whitespace") }
                if clean.rangeOfCharacter(from: edges, options: [.anchored, .backwards]) != nil { broken.append("trailing whitespace") }
                if ContractFormat.sanitize(clean, keepLineBreaks: keep) != clean { broken.append("not idempotent") }
                if !broken.isEmpty {
                    failures.append("\(input.debugDescription) (keep: \(keep)) -> \(clean.debugDescription): \(broken.joined(separator: ", "))")
                }
            }
        }
        XCTAssertEqual(failures.prefix(10).joined(separator: "\n"), "", "\(failures.count) strings broke an invariant")
    }
}

final class ContractRendererTests: XCTestCase {
    func testFillReplacesKnownTokensOnceAndLeavesTheRest() {
        let values: [ContractField: String] = [.clientName: "Alex", .price: "$10"]
        XCTAssertEqual(ContractRenderer.fill("Hi {{client_name}}, pay {{price}}.", with: values), "Hi Alex, pay $10.")
        XCTAssertEqual(ContractRenderer.fill("{{client_name}}{{price}}", with: values), "Alex$10", "Back to back")
        XCTAssertEqual(ContractRenderer.fill("{{unknown}} stays", with: values), "{{unknown}} stays")
        XCTAssertEqual(ContractRenderer.fill("{{ price }} has spaces so it is unknown", with: values), "{{ price }} has spaces so it is unknown")
        XCTAssertEqual(ContractRenderer.fill("{{}}", with: values), "{{}}")
        XCTAssertEqual(ContractRenderer.fill("no tokens { here } at all", with: values), "no tokens { here } at all")
        XCTAssertEqual(ContractRenderer.fill("unclosed {{price", with: values), "unclosed {{price")
        XCTAssertEqual(ContractRenderer.fill("", with: values), "")
    }

    func testAValueIsNeverReadAsAPlaceholderEvenWithoutSanitizing() {
        // `fill` itself is single pass: whatever a value says, it is inserted as it is and never expanded.
        let values: [ContractField: String] = [.clientName: "{{price}}", .price: "$10"]
        XCTAssertEqual(ContractRenderer.fill("{{client_name}} owes {{price}}", with: values), "{{price}} owes $10")
    }

    func testTokensAreListedInOrderOfAppearance() {
        XCTAssertEqual(ContractRenderer.tokens(in: "{{b}} then {{a}} then {{b}}"), ["b", "a", "b"])
        XCTAssertEqual(ContractRenderer.tokens(in: "nothing"), [])
        XCTAssertEqual(ContractRenderer.tokens(in: "{{open"), [])
    }

    func testRenderedTextNumbersEverySectionAndHashesTheExactWords() {
        let template = ContractTemplate(
            id: UUID(), creatorID: UUID(), title: "Deal for {{package_name}}", kind: .custom,
            clauses: [ContractClause(title: "Who", body: "{{creator_name}} and {{client_name}}"), ContractClause(title: "How much", body: "{{price}}")],
            version: 3, createdAt: Date(), updatedAt: Date()
        )
        var values = ContractContextBuilder.sample
        values[.packageName] = "Wedding"
        let rendered = ContractRenderer.render(template: template, values: values)
        XCTAssertEqual(rendered.title, "Deal for Wedding")
        XCTAssertEqual(rendered.templateVersion, 3)
        XCTAssertEqual(rendered.text, "Deal for Wedding\n\n1. Who\nMaya Chen Photography and Alex Rivera\n\n2. How much\n$3,200")
        XCTAssertEqual(rendered.documentHash, Hashing.sha256Hex(rendered.text))
    }

    func testSHA256MatchesKnownVectors() {
        XCTAssertEqual(Hashing.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testEveryFieldHasATokenATitleAndASample() {
        for field in ContractField.allCases {
            XCTAssertEqual(field.token, "{{\(field.rawValue)}}")
            XCTAssertFalse(field.title.isEmpty)
            XCTAssertFalse(field.sample.isEmpty)
            XCTAssertFalse(field.sample.contains("{{"))
        }
        XCTAssertEqual(ContractField.allCases.count, 17)
        XCTAssertEqual(Set(ContractContextBuilder.sample.keys), Set(ContractField.allCases))
    }

    // MARK: Filling from a booking

    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func package(deliverables: [String] = ["500 edited photos", "Online gallery"]) -> ServicePackage {
        ServicePackage(
            id: UUID(), creatorID: UUID(), name: "Wedding day coverage", summary: "", category: nil,
            priceCents: 240_000, currencyCode: "USD", durationMinutes: 480, deliverables: deliverables, turnaroundDays: 14,
            depositCents: 60_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            cancellationPolicy: .strict, usageRights: .commercial
        )
    }

    private let start = ISO8601DateFormatter().date(from: "2027-06-12T15:00:00Z")!

    func testBookingValuesComeFromThePackageAndTheChosenAddOns() {
        let extra = AddOn(kind: .extraTime, name: "Extra hour", priceCents: 30_000, extraMinutes: 60)
        let rush = AddOn(kind: .rush, name: "Rush", priceCents: 15_000, turnaroundDeltaDays: -7)
        let values = ContractContextBuilder.make(
            package: package(), addOns: [extra, rush], start: start, timeZone: chicago,
            clientName: "Alex Rivera", creatorName: "Maya Chen", notes: "Lake house"
        )
        XCTAssertEqual(values[.price], "$2,850")
        XCTAssertEqual(values[.deposit], "$600")
        XCTAssertEqual(values[.balance], "$2,250")
        XCTAssertEqual(values[.duration], "9 hours")
        XCTAssertEqual(values[.bookingTime], "10:00 AM \u{2013} 7:00 PM")
        XCTAssertEqual(values[.turnaround], "7 days")
        XCTAssertEqual(values[.deliveryDate], "Saturday, June 19, 2027")
        XCTAssertEqual(values[.addOns], "\u{2022} Extra hour (+$300)\n\u{2022} Rush (+$150)")
        XCTAssertEqual(values[.cancellationPolicy], CancellationPolicy.strict.contractText)
        XCTAssertEqual(values[.usageRights], UsageRights.commercial.contractText)
        XCTAssertEqual(values[.clientNotes], "Lake house")
        XCTAssertEqual(values[.timeZone], "America/Chicago")
    }

    func testEmptyThingsGetPlainWordsNotBlanks() {
        let values = ContractContextBuilder.make(
            package: package(deliverables: []), addOns: [], start: start, timeZone: chicago,
            clientName: "   ", creatorName: "Maya", notes: " \n "
        )
        XCTAssertEqual(values[.deliverables], "As described in the package")
        XCTAssertEqual(values[.addOns], "None")
        XCTAssertEqual(values[.clientName], "the Client")
        XCTAssertEqual(values[.clientNotes], "None")
    }

    func testEveryValueIsFilledSoNoTokenIsEverLeftInAContract() {
        let values = ContractContextBuilder.make(
            package: package(), addOns: [], start: start, timeZone: chicago, clientName: "A", creatorName: "B", notes: ""
        )
        XCTAssertEqual(Set(values.keys), Set(ContractField.allCases))
        XCTAssertTrue(values.values.allSatisfy { !$0.isEmpty })
    }

    func testPeopleCannotWritePlaceholdersIntoTheirNameOrNotes() {
        let hostile = ContractContextBuilder.make(
            package: package(), addOns: [], start: start, timeZone: chicago,
            clientName: "{{price}} Mallory", creatorName: "Lee {{{client_name}}}", notes: "{{deposit}}\n{{client_name}}"
        )
        XCTAssertEqual(hostile[.clientName], "{ {price} } Mallory")
        XCTAssertEqual(hostile[.creatorName], "Lee { { {client_name} } }")
        XCTAssertEqual(hostile[.clientNotes], "{ {deposit} }\n{ {client_name} }")

        let template = StarterTemplates.make(.photography, creatorID: UUID())
        let rendered = ContractRenderer.render(template: template, values: hostile)
        XCTAssertFalse(rendered.text.contains("{{"), "Nothing in the finished contract looks like a placeholder")
    }

    // MARK: Spanning a daylight saving change

    func testASpringForwardShootIsMeasuredOnTheClockOnTheWall() {
        let night = ISO8601DateFormatter().date(from: "2027-03-14T07:00:00Z")! // 1:00 AM CST, an hour before the clocks jump
        let values = ContractContextBuilder.make(
            package: ServicePackage.sampleNightShoot, addOns: [], start: night, timeZone: chicago,
            clientName: "Jo", creatorName: "Dana", notes: ""
        )
        XCTAssertEqual(values[.bookingTime], "1:00 AM \u{2013} 4:00 AM", "Two real hours, and the wall clock skips 2 AM")
        XCTAssertEqual(values[.duration], "2 hours")
    }
}

extension ServicePackage {
    /// Two hours, with a two day turnaround.
    fileprivate static var sampleNightShoot: ServicePackage {
        ServicePackage(
            id: UUID(), creatorID: UUID(), name: "Night shoot", summary: "", category: nil,
            priceCents: 90_000, currencyCode: "USD", durationMinutes: 120, deliverables: ["20 photos"], turnaroundDays: 2,
            depositCents: 20_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date()
        )
    }
}

// MARK: - Same words as the server

/// `supabase/tests/booking_rules.py` renders the same fixture in Postgres and checks the text there. If either side
/// changes how a contract reads, one of the two suites fails.
final class ContractGoldenTests: XCTestCase {
    private struct Golden: Decodable {
        struct Clause: Decodable { var title: String; var body: String }
        struct Template: Decodable { var title: String; var clauses: [Clause] }
        struct Package: Decodable {
            var name: String
            var priceCents: Int
            var currencyCode: String
            var durationMinutes: Int
            var deliverables: [String]
            var turnaroundDays: Int
            var depositCents: Int
            var cancellationPolicy: String
            var usageRights: String
        }
        struct Case: Decodable {
            var name: String
            var package: Package
            var chosenAddOns: [AddOn]
            var startUtc: String
            var timeZone: String
            var clientName: String
            var creatorName: String
            var notes: String
            var expectedText: String
        }
        struct AddOn: Decodable {
            var name: String
            var priceCents: Int
            var extraMinutes: Int
            var turnaroundDeltaDays: Int
        }
        var template: Template
        var cases: [Case]
    }

    private func load() throws -> Golden {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "contract_golden", withExtension: "json"),
            "contract_golden.json is missing from the test bundle"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: Data(contentsOf: url))
    }

    func testEveryGoldenCaseRendersWordForWordTheSameAsTheServer() throws {
        let golden = try load()
        XCTAssertGreaterThanOrEqual(golden.cases.count, 5)

        let template = ContractTemplate(
            id: UUID(), creatorID: UUID(), title: golden.template.title, kind: .custom,
            clauses: golden.template.clauses.map { ContractClause(title: $0.title, body: $0.body) },
            version: 1, createdAt: Date(), updatedAt: Date()
        )

        for item in golden.cases {
            let package = ServicePackage(
                id: UUID(), creatorID: UUID(), name: item.package.name, summary: "", category: nil,
                priceCents: item.package.priceCents, currencyCode: item.package.currencyCode,
                durationMinutes: item.package.durationMinutes, deliverables: item.package.deliverables,
                turnaroundDays: item.package.turnaroundDays, depositCents: item.package.depositCents, addOns: [],
                isPublished: false, position: 0, createdAt: Date(), updatedAt: Date(),
                cancellationPolicy: try XCTUnwrap(CancellationPolicy(rawValue: item.package.cancellationPolicy)),
                usageRights: try XCTUnwrap(UsageRights(rawValue: item.package.usageRights))
            )
            let addOns = item.chosenAddOns.map {
                AddOn(kind: .custom, name: $0.name, priceCents: $0.priceCents, extraMinutes: $0.extraMinutes, turnaroundDeltaDays: $0.turnaroundDeltaDays)
            }
            let start = try XCTUnwrap(ISO8601DateFormatter().date(from: item.startUtc))
            let values = ContractContextBuilder.make(
                package: package, addOns: addOns, start: start,
                timeZone: try XCTUnwrap(TimeZone(identifier: item.timeZone)),
                clientName: item.clientName, creatorName: item.creatorName, notes: item.notes
            )
            let rendered = ContractRenderer.render(template: template, values: values)

            XCTAssertEqual(rendered.text, item.expectedText, "Golden case '\(item.name)'")
            XCTAssertEqual(rendered.documentHash, Hashing.sha256Hex(item.expectedText), "Hash for '\(item.name)'")
        }
    }

    func testTheFixtureCoversEveryPlaceholder() throws {
        let golden = try load()
        let used = Set(golden.template.clauses.flatMap { ContractRenderer.tokens(in: $0.body) + ContractRenderer.tokens(in: $0.title) }
            + ContractRenderer.tokens(in: golden.template.title))
        for field in ContractField.allCases {
            XCTAssertTrue(used.contains(field.rawValue), "The golden template never uses \(field.token)")
        }
    }
}

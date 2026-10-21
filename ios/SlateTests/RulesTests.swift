import XCTest
@testable import Slate

final class HandleRulesTests: XCTestCase {
    func testNormalizeLowercasesAndHyphenatesSpaces() {
        XCTAssertEqual(HandleRules.normalize("Maya Chen"), "maya-chen")
        XCTAssertEqual(HandleRules.normalize("Maya   Chen"), "maya-chen")
        XCTAssertEqual(HandleRules.normalize("Maya_Chen.Photo"), "maya_chen-photo")
    }

    func testNormalizeDropsUnsupportedCharacters() {
        XCTAssertEqual(HandleRules.normalize("Café Ünï!"), "caf-n")
        XCTAssertEqual(HandleRules.normalize("a/b\\c"), "abc")
    }

    func testNormalizeCollapsesSeparatorsAndRejectsLeadingOnes() {
        XCTAssertEqual(HandleRules.normalize("a-_-b"), "a-b")
        XCTAssertEqual(HandleRules.normalize("--maya"), "maya")
    }

    func testNormalizeCapsLength() {
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(HandleRules.normalize(long).count, HandleRules.maxLength)
    }

    func testValidateAcceptsGoodHandles() {
        XCTAssertNil(HandleRules.validate("maya-chen"))
        XCTAssertNil(HandleRules.validate("a_b"))
        XCTAssertNil(HandleRules.validate("studio24"))
    }

    func testValidateReportsProblems() {
        XCTAssertEqual(HandleRules.validate("ab"), .tooShort)
        XCTAssertEqual(HandleRules.validate(String(repeating: "a", count: 31)), .tooLong)
        XCTAssertEqual(HandleRules.validate("maya chen"), .invalidCharacters)
        XCTAssertEqual(HandleRules.validate("Maya"), .invalidCharacters)
        XCTAssertEqual(HandleRules.validate("-maya"), .badEdges)
        XCTAssertEqual(HandleRules.validate("maya-"), .badEdges)
        XCTAssertEqual(HandleRules.validate("slate"), .reserved)
        XCTAssertEqual(HandleRules.validate("admin"), .reserved)
    }

    func testSuggestionTrimsTrailingSeparators() {
        XCTAssertEqual(HandleRules.suggestion(from: "Maya Chen Photography"), "maya-chen-photography")
        XCTAssertEqual(HandleRules.suggestion(from: "  Maya Chen  "), "maya-chen")
        XCTAssertEqual(HandleRules.suggestion(from: ""), "")
    }
}

final class TravelRadiusTests: XCTestCase {
    func testMilesLabelsRoundToFive() {
        XCTAssertEqual(TravelRadius.label(km: 16, usesMiles: true), "10 mi")
        XCTAssertEqual(TravelRadius.label(km: 40, usesMiles: true), "25 mi")
        XCTAssertEqual(TravelRadius.label(km: 80, usesMiles: true), "50 mi")
        XCTAssertEqual(TravelRadius.label(km: 160, usesMiles: true), "100 mi")
        XCTAssertEqual(TravelRadius.label(km: 400, usesMiles: true), "250 mi")
    }

    func testKilometerLabels() {
        XCTAssertEqual(TravelRadius.label(km: 25, usesMiles: false), "25 km")
    }

    func testPresetsAreAscendingInBothSystems() {
        for usesMiles in [true, false] {
            let presets = TravelRadius.presets(usesMiles: usesMiles)
            XCTAssertEqual(presets, presets.sorted())
            XCTAssertEqual(presets.count, 5)
        }
    }

    func testNearestPresetSnapsToClosest() {
        XCTAssertEqual(TravelRadius.nearestPreset(to: 30, usesMiles: false), 25)
        XCTAssertEqual(TravelRadius.nearestPreset(to: 60, usesMiles: false), 50)
        XCTAssertEqual(TravelRadius.nearestPreset(to: 1000, usesMiles: false), 250)
    }
}

import XCTest
@testable import Slate

/// The open-source licenses ask for their text to travel with the app. This checks it does.
final class LicensesTests: XCTestCase {
    func testTheLicenseNoticesAreInsideTheApp() throws {
        let bundle = Bundle(for: AppModel.self)
        let url = try XCTUnwrap(bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
                                "ThirdPartyNotices.txt didn't make it into the app")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("supabase-swift"))
        XCTAssertTrue(text.contains("stripe-ios-spm"))
        XCTAssertTrue(text.contains("Permission is hereby granted"), "The MIT license text is the point")
        XCTAssertTrue(text.contains("Inter 4.0 (font files)") && text.contains("JetBrains Mono 2.304 (font files)"), "The fonts the PDF is set in have their notice")
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"), "The font license text is the point")
    }
}

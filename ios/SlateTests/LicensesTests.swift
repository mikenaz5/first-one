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
    }
}

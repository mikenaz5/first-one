import XCTest
@testable import Slate

/// The addresses Apple asks for, and the identifiers that come from the website's domain.
final class LegalLinksTests: XCTestCase {
    func testThePagesAreSecureAndOnTheWebsite() {
        for url in [AppConfig.privacyURL, AppConfig.termsURL, AppConfig.supportURL] {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertEqual(url.host, AppConfig.bookingLinkHost, url.absoluteString)
        }
        XCTAssertEqual(AppConfig.privacyURL.path, "/privacy")
        XCTAssertEqual(AppConfig.termsURL.path, "/terms")
        XCTAssertEqual(AppConfig.supportURL.path, "/support")
    }

    func testSupportIsAnAddressAtTheWebsite() {
        XCTAssertEqual(AppConfig.supportEmail, "support@\(AppConfig.bookingLinkHost)")
        XCTAssertEqual(AppConfig.supportMailURL.scheme, "mailto")
        XCTAssertEqual(AppConfig.supportMailURL.absoluteString, "mailto:\(AppConfig.supportEmail)")
    }

    func testThePageNamesCannotBeTakenAsBookingLinkNames() {
        // slateproapp.com/<name> is a creator's page, so the website's own pages must never be anyone's name.
        for name in ["privacy", "terms", "support", "help", "about", "login", "admin", "www", "api"] {
            XCTAssertNotNil(HandleRules.validate(name), "\(name) should be reserved")
        }
    }

    func testNoPlaceholderDomainIsLeft() {
        XCTAssertFalse(AppConfig.bookingLinkHost.hasSuffix(".example"))
        let bundle = Bundle(for: AppModel.self).bundleIdentifier ?? ""
        XCTAssertTrue(bundle.hasPrefix("com.slateproapp."), "The app's identifier comes from the website's domain, not com.example: \(bundle)")
        XCTAssertTrue(WidgetStore.fallbackGroupID.hasPrefix("group.com.slateproapp."))
    }
}

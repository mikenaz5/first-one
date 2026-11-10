import CoreText
import UIKit

/// The fonts the contract PDF is set in.
///
/// A PDF carries the letters it uses, so every contract that is sent to someone carries a piece of its font. iOS's own fonts are
/// licensed for use on Apple devices through the system, and Apple's terms don't clearly say a copy of them may travel inside a
/// document. So the PDF uses two open-licensed families carried inside the app instead: Inter (text) and JetBrains Mono (codes
/// and hashes), both under the SIL Open Font License 1.1, which expressly allows embedding in documents. Their files are in
/// `Resources/Fonts`, their licence text is in `ThirdPartyNotices.txt`, and `docs/ASSETS.md` lists them.
///
/// If a file ever can't be loaded, the system font is used instead, so a contract is never left without text.
enum PDFFonts {
    private enum Face: String, CaseIterable {
        case regular = "Inter-Regular"
        case semibold = "Inter-SemiBold"
        case bold = "Inter-Bold"
        case mono = "JetBrainsMono-Regular"

        var fileExtension: String { self == .mono ? "ttf" : "otf" }
    }

    static func regular(_ size: CGFloat) -> UIFont { font(.regular, size) ?? .systemFont(ofSize: size) }
    static func semibold(_ size: CGFloat) -> UIFont { font(.semibold, size) ?? .systemFont(ofSize: size, weight: .semibold) }
    static func bold(_ size: CGFloat) -> UIFont { font(.bold, size) ?? .systemFont(ofSize: size, weight: .bold) }
    static func mono(_ size: CGFloat) -> UIFont { font(.mono, size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }

    /// Whether every carried font could be loaded (the tests check this, so a missing file is noticed, not hidden by the fallback).
    static var allLoaded: Bool { Face.allCases.allSatisfy { font($0, 12) != nil } }

    private final class BundleToken {}

    /// Makes the carried fonts known to this app, once. Registering a font that is already registered is harmless.
    private static let registration: Void = {
        let bundle = Bundle(for: BundleToken.self)
        for face in Face.allCases {
            guard let url = bundle.url(forResource: face.rawValue, withExtension: face.fileExtension) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    private static func font(_ face: Face, _ size: CGFloat) -> UIFont? {
        _ = registration
        guard let base = UIFont(name: face.rawValue, size: size) else { return nil }
        return withoutContextualAlternates(base)
    }

    /// Inter's contextual alternates swap the hyphen and colon in dates and times ("2027-01-15 08:00:00") for look-alike letters
    /// that are stored at private-use code points. They look right on the page, but a date searched or copied out of the PDF
    /// comes out as unreadable characters. Switching the feature off keeps every character a plain one.
    private static func withoutContextualAlternates(_ font: UIFont) -> UIFont {
        let off: [[String: Any]] = [[
            kCTFontFeatureTypeIdentifierKey as String: 36,   // Core Text's "Contextual Alternates" (OpenType calt)
            kCTFontFeatureSelectorIdentifierKey as String: 1, // ... off
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: off])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

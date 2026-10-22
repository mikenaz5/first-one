import SwiftUI
import UIKit

// The single source of truth for Slate's look. Everything here is built from system
// fonts, system colors and SF Symbols, so Light/Dark Mode, Dynamic Type and the OS's own
// visual refreshes (for example Liquid Glass bars) apply without extra work.
//
// Rules of thumb:
//  - Use the tokens below instead of literals.
//  - Use semantic text styles (`.title`, `.body`...), never fixed point sizes, so Dynamic Type works.
//  - Keep every tappable thing at least `Metrics.minTapTarget` points tall.
//  - Don't paint custom backgrounds behind navigation or tab bars. Let the system draw them.

// MARK: - Spacing

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
    /// Standard horizontal margin for full-width pages.
    static let page: CGFloat = 20
}

// MARK: - Shape

enum Radius {
    static let s: CGFloat = 10
    static let m: CGFloat = 14
    static let l: CGFloat = 20
    static let xl: CGFloat = 28
}

enum Metrics {
    /// Apple's minimum comfortable touch target.
    static let minTapTarget: CGFloat = 44
    static let avatarS: CGFloat = 44
    static let avatarM: CGFloat = 72
    static let avatarL: CGFloat = 112
    static let avatarXL: CGFloat = 132
    static let gridSpacing: CGFloat = 3
    /// A small round badge on an avatar (the camera on a profile photo).
    static let badge: CGFloat = 36

    /// Height of the label inside a `.large` button, so buttons with different contents come out the same height.
    static let buttonLabelHeight: CGFloat = 28
    /// Width of the leading icon in a row or card, so titles line up down a screen.
    static let iconColumn: CGFloat = 28

    /// Widest a form, sheet or reading column grows on iPad and landscape.
    static let readableWidth: CGFloat = 640
    /// Widest a scrolling page (Home, Profile, a conversation) grows.
    static let pageWidth: CGFloat = 720
    /// Minimum heights for empty and loading placeholders: a compact one inside a card, a regular one on its own.
    static let placeholderCompact: CGFloat = 120
    static let placeholderRegular: CGFloat = 170

    /// The date tile in a booking row, and the day and time buttons in the booking sheet. They are minimums: they grow
    /// with the text instead of clipping it.
    static let dateTileWidth: CGFloat = 52
    static let dateTileHeight: CGFloat = 56
    static let dayChipWidth: CGFloat = 56
    static let dayChipHeight: CGFloat = 68
    static let timeSlotMinWidth: CGFloat = 96

    /// The signature pad, a typed signature's preview, and a signature shown on a signed contract.
    static let signaturePadHeight: CGFloat = 150
    static let signaturePreviewMinHeight: CGFloat = 96
    static let signaturePreviewHeight: CGFloat = 56
}

// MARK: - Color

// Semantic colors. They resolve to system colors, so they adapt to Light/Dark Mode and
// to Increase Contrast. The brand accent lives in the asset catalog (`AccentColor`).
extension ShapeStyle where Self == Color {
    /// Page background behind grouped content.
    static var slateBackground: Color { Color(.systemGroupedBackground) }
    /// Card surface on top of `slateBackground`.
    static var slateCard: Color { Color(.secondarySystemGroupedBackground) }
    /// Surface for elements that sit on a card.
    static var slateRaised: Color { Color(.tertiarySystemGroupedBackground) }
    /// Subtle fill for chips and inactive controls.
    static var slateFill: Color { Color(.tertiarySystemFill) }
    static var slateHairline: Color { Color(.separator) }
    // Status colors are used for text as well as symbols. The system green, orange and red are too light on a white page
    // to read as small text (about 2 to 3.5 : 1), so in Light Mode these are darker versions that reach at least 4.5 : 1,
    // and in Dark Mode they are the system colors, which are bright enough on black.
    static var slateSuccess: Color { .adaptive(light: (0.10, 0.50, 0.20), dark: .systemGreen) }
    static var slateWarning: Color { .adaptive(light: (0.65, 0.32, 0.00), dark: .systemOrange) }
    static var slateDanger: Color { .adaptive(light: (0.80, 0.14, 0.12), dark: .systemRed) }
    /// Filled rating stars.
    static var slateStar: Color { .orange }
    /// Text and symbols on the accent color (selected chips, outgoing bubbles, badges).
    static var slateOnAccent: Color { .white }
    /// Signatures are written on paper: a light surface and dark ink in both appearances, so a drawn signature stays
    /// readable in Dark Mode and looks the way it will on the signed PDF.
    static var slatePaper: Color { Color(red: 0.99, green: 0.99, blue: 0.98) }
    static var slateInk: Color { Color(red: 0.08, green: 0.12, blue: 0.35) }
}

private extension Color {
    /// One color for Light Mode, another for Dark Mode.
    static func adaptive(light: (Double, Double, Double), dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        })
    }
}

// MARK: - Typography

/// Semantic type scale. All of these scale with Dynamic Type.
enum SlateFont {
    /// Hero headline on welcome and onboarding pages.
    static let display = Font.system(.largeTitle, weight: .bold)
    static let title = Font.system(.title2, weight: .semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption = Font.caption
}

extension View {
    /// Small uppercase section label.
    func eyebrow() -> some View {
        font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Cards

struct CardStyle: ViewModifier {
    enum Kind {
        /// Solid grouped surface. The default.
        case grouped
        /// Translucent material, for content that sits over imagery or gradients.
        case material
        /// Transparent with a hairline border, for secondary or empty-state tiles.
        case outlined
    }

    var kind: Kind = .grouped
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.l

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                switch kind {
                case .grouped: shape.fill(Color.slateCard)
                case .material: shape.fill(.regularMaterial)
                case .outlined: shape.fill(Color.clear)
                }
            }
            .overlay {
                if kind == .outlined {
                    shape.strokeBorder(Color.slateHairline, lineWidth: 1)
                }
            }
    }
}

extension View {
    func card(_ kind: CardStyle.Kind = .grouped, padding: CGFloat = Space.l, radius: CGFloat = Radius.l) -> some View {
        modifier(CardStyle(kind: kind, padding: padding, radius: radius))
    }

    /// Full-screen grouped page background that extends under the bars.
    func slatePageBackground() -> some View {
        background(Color.slateBackground.ignoresSafeArea())
    }
}

// MARK: - Motion

extension Animation {
    /// Springy, for things that appear or settle (chips, success states).
    static let slateSpring = Animation.spring(duration: 0.45, bounce: 0.25)
    /// Default for layout changes and page transitions.
    static let slateSmooth = Animation.smooth(duration: 0.4)
    /// Quick feedback for presses and toggles.
    static let slateSnappy = Animation.snappy(duration: 0.28)
}

private struct MotionSafe<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `animation(_:value:)` that switches itself off when Reduce Motion is on.
    func motionSafe<Value: Equatable>(_ animation: Animation = .slateSmooth, value: Value) -> some View {
        modifier(MotionSafe(animation: animation, value: value))
    }
}

// MARK: - Large symbols

private struct HeroSymbolStyle: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var scaled: CGFloat = 56
    private let size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        self.size = size
        self.weight = weight
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    func body(content: Content) -> some View {
        // Grows with Dynamic Type, but not without limit: a symbol at the biggest text size shouldn't fill the screen.
        content.font(.system(size: min(scaled, size * 1.5), weight: weight))
    }
}

extension View {
    /// The big decorative symbol at the top of an empty state or a welcome screen. Unlike a fixed point size it follows
    /// the person's text size, the way Apple's own empty states do.
    func heroSymbol(_ size: CGFloat = 56, weight: Font.Weight = .light) -> some View {
        modifier(HeroSymbolStyle(size: size, weight: weight))
    }
}

// MARK: - Layout that adapts to text size

/// Lays children out side by side, and one above the other once the person's text size is an accessibility size,
/// where a row of two things no longer fits.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    private let alignment: VerticalAlignment
    private let stackedAlignment: HorizontalAlignment
    private let spacing: CGFloat
    private let content: Content

    init(
        alignment: VerticalAlignment = .firstTextBaseline,
        stackedAlignment: HorizontalAlignment = .leading,
        spacing: CGFloat = Space.m,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.stackedAlignment = stackedAlignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: stackedAlignment, spacing: Space.xs) { content }
        } else {
            HStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

// MARK: - Preview

#Preview("Design system") {
    ScrollView {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Display").font(SlateFont.display)
            Text("Eyebrow").eyebrow()
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Grouped card").font(SlateFont.headline)
                Text("Solid surface on the page background.").font(SlateFont.subheadline).foregroundStyle(.secondary)
            }
            .card()
            Text("Material card").font(SlateFont.headline).card(.material)
            Text("Outlined card").font(SlateFont.headline).card(.outlined)
        }
        .padding(Space.page)
    }
    .slatePageBackground()
}

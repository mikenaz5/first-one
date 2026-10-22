import SwiftUI

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
    static var slateSuccess: Color { .green }
    static var slateWarning: Color { .orange }
    static var slateDanger: Color { .red }
    /// Filled rating stars.
    static var slateStar: Color { .orange }
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

import SwiftUI
import UIKit

// MARK: - Avatar

/// Circular profile photo with an initials fallback. Prefers freshly chosen `imageData`,
/// then `url`, then initials on an accent gradient.
struct AvatarView: View {
    var name: String
    var url: URL?
    var imageData: Data?
    var size: CGFloat = Metrics.avatarM

    var body: some View {
        ZStack {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.slateHairline.opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var initialsView: some View {
        ZStack {
            Rectangle().fill(Color.accentColor.gradient)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.slateOnAccent)
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

// MARK: - Chips

/// Selectable specialty chip. 44pt tall, announces its selected state to VoiceOver.
struct SpecialtyChip: View {
    let specialty: Specialty
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(specialty.title, systemImage: specialty.symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Space.m)
                .frame(minHeight: Metrics.minTapTarget)
                .foregroundStyle(isSelected ? Color.slateOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.slateFill, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.slateHairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .motionSafe(.slateSnappy, value: isSelected)
    }
}

/// Read-only tag, for showing specialties on a profile.
struct TagChip: View {
    let title: String
    var symbol: String?

    var body: some View {
        Group {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Color.slateFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.slateHairline, lineWidth: 1))
    }
}

// MARK: - Flow layout

/// Wraps children onto new lines, like text. Used for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s
    var lineSpacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width
            usedWidth = max(usedWidth, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Section header

struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.m)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

// MARK: - Button feedback

/// Subtle press-down for tappable tiles. Stays still when Reduce Motion is on.
struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableTileLabel(configuration: configuration)
    }
}

private struct PressableTileLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .slateSnappy, value: configuration.isPressed)
    }
}

// MARK: - Zoom transitions

extension View {
    /// Marks a view as the origin of an iOS 18 zoom transition. No-op on iOS 17.
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Makes a pushed destination zoom out of its `zoomSource`. No-op on iOS 17.
    @ViewBuilder
    func zoomDestination(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Keyboard

extension UIApplication {
    /// Dismisses the keyboard from anywhere. Number pads have no Return key, so forms offer a Done button.
    static func dismissKeyboard() {
        shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

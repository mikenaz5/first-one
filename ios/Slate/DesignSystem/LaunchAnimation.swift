import SwiftUI

// MARK: - When it plays, and for how long

/// The steps of the opening animation, in order.
enum LaunchStage: Int, Comparable, CaseIterable {
    /// Nothing on screen yet.
    case hidden
    /// The board fades in with its clapper open.
    case arriving
    /// The clapper snaps shut.
    case clapped
    /// The name rises in underneath.
    case named
    /// Everything fades away and the app is there.
    case leaving

    static func < (lhs: LaunchStage, rhs: LaunchStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When each step starts, in seconds from the beginning. With Reduce Motion on, nothing moves: the board is already shut,
/// and the picture simply fades in, rests, and fades out, in about half the time.
struct LaunchTimeline: Equatable {
    var reduceMotion: Bool

    func start(of stage: LaunchStage) -> Double {
        switch stage {
        case .hidden: 0
        case .arriving: 0
        case .clapped: reduceMotion ? 0 : 0.55
        case .named: reduceMotion ? 0.15 : 0.85
        case .leaving: reduceMotion ? 0.95 : 1.75
        }
    }

    /// How long the last fade takes.
    var fadeOut: Double { reduceMotion ? 0.3 : 0.4 }

    /// From the start to the app being fully showing.
    var total: Double { start(of: .leaving) + fadeOut }

    func animation(for stage: LaunchStage) -> Animation? {
        if reduceMotion { return .easeInOut(duration: stage == .leaving ? fadeOut : 0.25) }
        switch stage {
        case .hidden: return nil
        case .arriving: return .smooth(duration: 0.4)
        // Quick and a little bouncy: a clap, not a close.
        case .clapped: return .spring(duration: 0.2, bounce: 0.35)
        case .named: return .smooth(duration: 0.45)
        case .leaving: return .easeIn(duration: fadeOut)
        }
    }
}

/// Whether to play the animation at all. It plays every time the app is opened, except when a test or an automated run
/// asks it not to (so screenshots and tests don't wait for it).
enum LaunchPolicy {
    static let skipArgument = "-skipLaunchAnimation"
    static let skipVariable = "SLATE_SKIP_LAUNCH"

    static func shouldPlay(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains(skipArgument) { return false }
        if environment[skipVariable] != nil { return false }
        // Running as a unit-test host.
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }
}

// MARK: - The picture

/// The mark: a film slate (a clapperboard) with its name under it. `LaunchView` shows its final frame while the app is
/// still starting, so the animation and what follows it are the same picture.
struct LaunchBrand: View {
    /// The clapper is lifted.
    var open = false
    /// Shows the name.
    var named = true
    /// A ring that spreads out from the board, once, at the clap.
    var ring = false

    var body: some View {
        VStack(spacing: Space.xl) {
            ClapperBoard(open: open)
                .frame(width: ClapperBoard.width, height: ClapperBoard.height)
                .background {
                    // The ring starts bright and fades as it spreads; it plays when `ring` turns on.
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: ClapperBoard.width, height: ClapperBoard.width)
                        .keyframeAnimator(initialValue: RingValues(), trigger: ring) { content, value in
                            content.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(2.0, duration: 0.6)
                            }
                            KeyframeTrack(\.opacity) {
                                CubicKeyframe(0.7, duration: 0.05)
                                LinearKeyframe(0.0, duration: 0.55)
                            }
                        }
                        .accessibilityHidden(true)
                }

            Text(AppConfig.productName)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .opacity(named ? 1 : 0)
                .offset(y: named ? 0 : 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.productName)
    }
}

/// What the ring is like at one moment.
private struct RingValues {
    var scale = 0.75
    var opacity = 0.0
}

/// A clapperboard drawn from shapes, so it follows the app's colours in light and dark and needs no image file.
struct ClapperBoard: View {
    static let width: CGFloat = 132
    static let height: CGFloat = 120

    /// The clapper stick is lifted.
    var open: Bool

    private let stickHeight: CGFloat = 26
    private let gap: CGFloat = 4
    private let corner: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The board.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.slateCard)
                .overlay {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(0..<3, id: \.self) { row in
                            Capsule()
                                .fill(Color.slateHairline)
                                .frame(width: row == 2 ? 56 : 92, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 14)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
                .frame(width: Self.width, height: Self.height - stickHeight - gap)
                .offset(y: stickHeight + gap)

            // The clapper stick, hinged at its left end.
            ZStack {
                RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous)
                    .fill(Color.slateCard)
                ClapperStripes()
                    .fill(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous))
                RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
            .frame(width: Self.width, height: stickHeight)
            .rotationEffect(.degrees(open ? -24 : 0), anchor: .bottomLeading)
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The slanted stripes on a clapper stick.
private struct ClapperStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / 6
        for index in stride(from: 0, to: 6, by: 2) {
            let x = CGFloat(index) * step
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + step * 0.7, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step * 1.7, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - The animation

/// Plays once over the app when it opens: the slate arrives with its clapper up, snaps shut with a tap you can feel, the
/// name rises in, and it all fades away. Touching the screen skips it.
struct LaunchAnimationView: View {
    /// Called once, when the animation is over (or skipped), so the app can take it away.
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = LaunchStage.hidden
    @State private var clapCount = 0
    @State private var finished = false

    private var timeline: LaunchTimeline { LaunchTimeline(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            Color.slateBackground.ignoresSafeArea()
            LaunchBrand(
                open: !reduceMotion && stage < .clapped,
                named: stage >= .named,
                ring: stage >= .clapped && !reduceMotion
            )
            .opacity(stage >= .arriving ? 1 : 0)
            .scaleEffect(stage >= .arriving ? 1 : 0.88)
        }
        .opacity(stage == .leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .sensoryFeedback(.impact(weight: .medium), trigger: clapCount)
        .task { await play() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the opening animation")
    }

    private func play() async {
        var previous = 0.0
        for next in [LaunchStage.arriving, .clapped, .named, .leaving] {
            let at = timeline.start(of: next)
            if at > previous {
                try? await Task.sleep(for: .seconds(at - previous))
                previous = at
            }
            if Task.isCancelled || finished { return }
            withAnimation(timeline.animation(for: next)) { stage = next }
            if next == .clapped, !reduceMotion { clapCount += 1 }
        }
        try? await Task.sleep(for: .seconds(timeline.fadeOut))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

#Preview("Launch animation") {
    LaunchAnimationView {}
}

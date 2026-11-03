import SwiftUI

// MARK: - When it plays, and for how long

/// The steps of the opening animation, in order.
enum LaunchStage: Int, Comparable, CaseIterable {
    /// Nothing on screen yet.
    case hidden
    /// The app icon appears and its three lines slide in from the sides, one after another, lying flat.
    case lines
    /// The lines swing round to the icon's angle and tighten into the logo.
    case turn
    /// A glint runs along the lines and a soft glow breathes out. The phone gives a firm tap.
    case settled
    /// The name rises in underneath.
    case named
    /// Everything fades away and the app is there.
    case leaving

    static func < (lhs: LaunchStage, rhs: LaunchStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When each step starts, in seconds from the beginning. With Reduce Motion on, nothing moves: the finished logo and the
/// name simply fade in, rest, and fade out, in about half the time.
struct LaunchTimeline: Equatable {
    var reduceMotion: Bool

    func start(of stage: LaunchStage) -> Double {
        switch stage {
        case .hidden: 0
        case .lines: 0
        case .turn: reduceMotion ? 0 : 0.6
        case .settled: reduceMotion ? 0 : 1.1
        case .named: reduceMotion ? 0.15 : 1.25
        case .leaving: reduceMotion ? 0.95 : 2.0
        }
    }

    /// How long the last fade takes.
    var fadeOut: Double { reduceMotion ? 0.3 : 0.4 }

    /// From the start to the app being fully showing.
    var total: Double { start(of: .leaving) + fadeOut }

    /// How long each of the three lines waits before it slides in, top to bottom.
    var slideDelays: [Double] { reduceMotion ? [0, 0, 0] : [0, 0.09, 0.18] }

    func animation(for stage: LaunchStage) -> Animation? {
        if reduceMotion { return .easeInOut(duration: stage == .leaving ? fadeOut : 0.25) }
        switch stage {
        case .hidden: return nil
        case .lines: return .smooth(duration: 0.4)
        // A little overshoot, so the lines swing past and settle.
        case .turn: return .spring(duration: 0.65, bounce: 0.3)
        case .settled: return .easeOut(duration: 0.6)
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

// MARK: - The logo

/// The app icon, drawn from its design (`Design/SlatePro-AppIcon.svg`): three rounded lines, white, lavender and violet,
/// getting shorter, turned 35 degrees on a near-black tile. Drawn in code so it can move; it needs no image file.
///
/// `stage` says how far along the opening animation it is. At `.named` or later it is the finished icon, which is what the
/// app shows while it starts.
struct SlateLogo: View {
    static let lavender = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929)
    /// How far the lines tilt in the finished logo.
    static let tilt = -35.0

    var side: CGFloat = 156
    var stage: LaunchStage = .named
    /// How long each line waits before sliding in.
    var slideDelays: [Double] = [0, 0, 0]

    /// One line, in the icon's own units (a 1024 square): its length, and how far from the middle it sits, up or down,
    /// before the group is turned. `from` is the side it slides in from.
    private struct Line {
        let length: CGFloat
        let offset: CGFloat
        let color: Color
        let from: CGFloat
    }

    private var lines: [Line] {
        [
            Line(length: 424, offset: -100, color: .white, from: -1),
            Line(length: 330, offset: 0, color: Self.lavender, from: 1),
            Line(length: 236, offset: 100, color: Self.violet, from: -1),
        ]
    }

    var body: some View {
        // The icon draws its lines at 1.12 times, so a unit here is that much of the tile.
        let unit = side / 1024 * 1.12
        let slidIn = stage >= .lines
        let turned = stage >= .turn
        let glint = stage >= .settled
        let tile = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)

        ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Capsule()
                    .fill(line.color)
                    .overlay { Glint(on: glint, delay: Double(index) * 0.07) }
                    .frame(width: line.length * unit, height: 64 * unit)
                    // Lying flat and spread apart until they turn; sliding in from outside the tile (which clips them).
                    .offset(x: slidIn ? 0 : line.from * side, y: line.offset * unit * (turned ? 1 : 1.9))
                    .animation(.smooth(duration: 0.5).delay(slideDelays[index]), value: slidIn)
            }
        }
        .rotationEffect(.degrees(turned ? Self.tilt : 0))
        .animation(.spring(duration: 0.65, bounce: 0.3), value: turned)
        .frame(width: side, height: side)
        .background(
            tile.fill(LinearGradient(
                colors: [Color(red: 0.110, green: 0.102, blue: 0.133), Color(red: 0.020, green: 0.020, blue: 0.024)],
                startPoint: .top, endPoint: .bottom
            ))
        )
        .clipShape(tile)
        .overlay { tile.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .background { glow(on: glint) }
    }

    /// A soft violet halo that breathes out once when the logo settles.
    private func glow(on: Bool) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [Self.violet.opacity(0.7), .clear], center: .center, startRadius: 0, endRadius: side * 0.8
            ))
            .frame(width: side * 1.6, height: side * 1.6)
            .keyframeAnimator(initialValue: GlowValues(), trigger: on) { content, value in
                content.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.15, duration: 0.7)
                }
                KeyframeTrack(\.opacity) {
                    CubicKeyframe(0.9, duration: 0.15)
                    CubicKeyframe(0.0, duration: 0.55)
                }
            }
            .accessibilityHidden(true)
    }
}

/// What the halo is like at one moment.
private struct GlowValues {
    var scale = 0.7
    var opacity = 0.0
}

/// A bright band that runs along one line, once, and leaves the line as it was.
private struct Glint: View {
    var on: Bool
    var delay: Double

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.clear, .white.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.45)
            .offset(x: on ? geometry.size.width * 1.05 : -geometry.size.width * 0.5)
            .animation(.easeInOut(duration: 0.55).delay(delay), value: on)
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

/// The logo with the name under it. `LaunchView` shows the finished one while the app is still starting, so the animation
/// and what follows it are the same picture.
struct LaunchBrand: View {
    var stage: LaunchStage = .named
    /// Shows the name.
    var named = true
    var slideDelays: [Double] = [0, 0, 0]

    var body: some View {
        VStack(spacing: Space.xl) {
            SlateLogo(stage: stage, slideDelays: slideDelays)

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

// MARK: - The animation

/// Plays once over the app when it opens: the icon appears, its three lines slide in and swing round into place, a glint
/// runs along them with a tap you can feel, the name rises in, and it all fades away. Touching the screen skips it.
struct LaunchAnimationView: View {
    /// Called once, when the animation is over (or skipped), so the app can take it away.
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = LaunchStage.hidden
    @State private var settleCount = 0
    @State private var finished = false

    private var timeline: LaunchTimeline { LaunchTimeline(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            Color.slateBackground.ignoresSafeArea()
            // With Reduce Motion on the logo is already finished: only the fades remain.
            LaunchBrand(
                stage: reduceMotion ? .named : stage,
                named: stage >= .named,
                slideDelays: timeline.slideDelays
            )
            .opacity(stage >= .lines ? 1 : 0)
            .scaleEffect(stage >= .lines ? 1 : 0.9)
        }
        .opacity(stage == .leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .sensoryFeedback(.impact(weight: .medium), trigger: settleCount)
        .task { await play() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Skips the opening animation")
    }

    private func play() async {
        var previous = 0.0
        for next in [LaunchStage.lines, .turn, .settled, .named, .leaving] {
            let at = timeline.start(of: next)
            if at > previous {
                try? await Task.sleep(for: .seconds(at - previous))
                previous = at
            }
            if Task.isCancelled || finished { return }
            withAnimation(timeline.animation(for: next)) { stage = next }
            if next == .settled, !reduceMotion { settleCount += 1 }
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

#Preview("The finished logo") {
    ZStack {
        Color.slateBackground.ignoresSafeArea()
        LaunchBrand()
    }
}

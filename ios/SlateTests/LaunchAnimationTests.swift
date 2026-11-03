import XCTest
@testable import Slate

/// The opening animation's timing and when it plays. (How it looks is checked by eye: the Xcode preview, or the
/// simulator.)
final class LaunchAnimationTests: XCTestCase {
    func testTheStepsComeInOrderAndNeverBackUp() {
        for reduceMotion in [false, true] {
            let timeline = LaunchTimeline(reduceMotion: reduceMotion)
            let starts = LaunchStage.allCases.map(timeline.start(of:))
            XCTAssertEqual(starts, starts.sorted(), "Reduce Motion \(reduceMotion)")
            XCTAssertEqual(starts.first, 0)
        }
    }

    func testItIsShortEnoughNotToGetInTheWay() {
        XCTAssertLessThanOrEqual(LaunchTimeline(reduceMotion: false).total, 2.5, "A flourish, not a wait")
        XCTAssertGreaterThanOrEqual(LaunchTimeline(reduceMotion: false).total, 1.5, "Long enough to see")
    }

    func testReduceMotionIsShorterAndStillFadesOut() {
        let calm = LaunchTimeline(reduceMotion: true)
        let full = LaunchTimeline(reduceMotion: false)
        XCTAssertLessThan(calm.total, full.total)
        XCTAssertGreaterThan(calm.fadeOut, 0)
        XCTAssertEqual(calm.start(of: .turn), 0, "Nothing swings round: the logo is already finished")
        XCTAssertEqual(calm.start(of: .settled), 0, "No glint, no tap")
    }

    func testEveryStepAfterTheFirstHasAnAnimation() {
        for reduceMotion in [false, true] {
            let timeline = LaunchTimeline(reduceMotion: reduceMotion)
            for stage in LaunchStage.allCases where stage != .hidden {
                XCTAssertNotNil(timeline.animation(for: stage), "\(stage) with Reduce Motion \(reduceMotion)")
            }
        }
    }

    func testStagesCompareByOrder() {
        XCTAssertLessThan(LaunchStage.hidden, .lines)
        XCTAssertLessThan(LaunchStage.lines, .turn)
        XCTAssertLessThan(LaunchStage.turn, .settled)
        XCTAssertLessThan(LaunchStage.settled, .named)
        XCTAssertLessThan(LaunchStage.named, .leaving)
    }

    func testTheThreeLinesSlideInOneAfterAnotherUnlessMotionIsReduced() {
        let delays = LaunchTimeline(reduceMotion: false).slideDelays
        XCTAssertEqual(delays.count, 3, "One for each line of the logo")
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertLessThan(delays[0], delays[2])
        XCTAssertEqual(LaunchTimeline(reduceMotion: true).slideDelays, [0, 0, 0])
    }

    func testTheLogoEndsAtTheIconsAngle() {
        // Design/SlatePro-AppIcon.svg turns its lines -35 degrees.
        XCTAssertEqual(SlateLogo.tilt, -35)
    }
    func testItPlaysWheneverTheAppIsOpened() {
        XCTAssertTrue(LaunchPolicy.shouldPlay(arguments: ["Slate"], environment: [:]))
    }

    func testTestsAndAutomationCanTurnItOff() {
        XCTAssertFalse(LaunchPolicy.shouldPlay(arguments: ["Slate", LaunchPolicy.skipArgument], environment: [:]))
        XCTAssertFalse(LaunchPolicy.shouldPlay(arguments: [], environment: [LaunchPolicy.skipVariable: "1"]))
        XCTAssertFalse(LaunchPolicy.shouldPlay(arguments: [], environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    func testTheRealTestRunDoesNotPlayIt() {
        // This file runs inside a test host, so the default arguments must say "don't".
        XCTAssertFalse(LaunchPolicy.shouldPlay())
    }
}

import SwiftUI
import XCTest
@testable import Slate

/// The chips on a profile once collapsed into tall, empty pills (the name got no width). These measure them the way a
/// real screen does, so that can't come back unnoticed.
@MainActor
final class ChipLayoutTests: XCTestCase {
    private func size<V: View>(_ view: V, width: CGFloat = 320) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func testASpecialtyChipIsOneLineHighAndWideEnoughForItsName() {
        for specialty in Specialty.allCases {
            let chip = size(SpecialtyChip(specialty: specialty, isSelected: false) {})
            XCTAssertGreaterThanOrEqual(chip.height, Metrics.minTapTarget, specialty.title)
            XCTAssertLessThan(chip.height, Metrics.minTapTarget + 12, "\(specialty.title) is too tall: \(chip.height)")
            XCTAssertGreaterThan(chip.width, 70, "\(specialty.title) is too narrow: \(chip.width)")
        }
    }

    func testALongerNameIsWiderThanAShorterOne() {
        let short = size(SpecialtyChip(specialty: .food, isSelected: false) {})
        let long = size(SpecialtyChip(specialty: .documentary, isSelected: false) {})
        XCTAssertGreaterThan(long.width, short.width)
    }

    func testATagChipIsOneLine() {
        let tag = size(TagChip(title: "Delivered in 5 days", symbol: "shippingbox"))
        XCTAssertLessThan(tag.height, 44)
        XCTAssertGreaterThan(tag.width, 100)
    }

    func testEverySpecialtyFitsInAFewRowsOnASmallPhone() {
        let all = FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
            ForEach(Specialty.allCases) { specialty in
                SpecialtyChip(specialty: specialty, isSelected: false) {}
            }
        }
        let laidOut = size(all, width: 300)
        let rowHeight = Metrics.minTapTarget + Space.s
        // 14 chips can't need more than seven rows of two, and one row must hold at least two.
        XCTAssertLessThanOrEqual(laidOut.height, rowHeight * 7)
        XCTAssertGreaterThanOrEqual(laidOut.height, Metrics.minTapTarget)
    }
}

import XCTest
@testable import HermesBotApp

/// BLOCK-003 (review run318): the approval ring kept animating after the motion gate closed, because it
/// was a scheduled `withAnimation` (0.45 s delay + 1.1 s) checked only on appear. The ring is now drawn
/// from `ApprovalRipple.progress` on every frame, which must be nil whenever motion is off.
final class MotionGateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ s: Double) -> Date { start.addingTimeInterval(s) }

    func testRippleRunsOnlyBetweenDelayAndEnd() {
        XCTAssertNil(ApprovalRipple.progress(at: at(0), start: start, motion: true))
        XCTAssertNil(ApprovalRipple.progress(at: at(DS.Motion.ringDelay - 0.01), start: start, motion: true), "still in its delay")
        let mid = ApprovalRipple.progress(at: at(DS.Motion.ringDelay + DS.Motion.ringDuration / 2), start: start, motion: true)
        XCTAssertNotNil(mid)
        XCTAssertGreaterThan(mid ?? 0, 0.5, "ease-out is past half way at half time")
        XCTAssertLessThan(mid ?? 1, 1)
        XCTAssertNil(ApprovalRipple.progress(at: at(ApprovalRipple.total + 0.01), start: start, motion: true), "finished")
    }

    func testMotionOffHidesTheRippleAtEveryMoment() {
        // Before the delay ends (the reviewer's 150 ms toggle), while it grows, and after.
        for t in stride(from: 0.0, through: ApprovalRipple.total + 0.5, by: 0.05) {
            XCTAssertNil(ApprovalRipple.progress(at: at(t), start: start, motion: false), "t=\(t)")
        }
    }

    func testProgressIsMonotonic() {
        var last: CGFloat = 0
        for t in stride(from: DS.Motion.ringDelay + 0.01, to: ApprovalRipple.total, by: 0.05) {
            let p = ApprovalRipple.progress(at: at(t), start: start, motion: true) ?? -1
            XCTAssertGreaterThan(p, last, "t=\(t)")
            last = p
        }
    }

    @MainActor
    func testGatedHelpersAnimateNothingWithMotionOff() {
        var ran = false
        withDSAnimation(false) { ran = true }
        XCTAssertTrue(ran, "the state change itself still happens at once")
    }
}

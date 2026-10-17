import XCTest
@testable import RemoteCore

final class TouchGestureRecognizerTests: XCTestCase {
    private func touch(_ x: Double, _ y: Double, id: Int32 = 1) -> [TouchSample] {
        [TouchSample(id: id, x: x, y: y)]
    }

    func testQuickMovementMovesCursor() {
        let r = TouchGestureRecognizer()
        XCTAssertEqual(r.process(touch(0.5, 0.5), at: 0), [.touchBegan])
        XCTAssertEqual(r.process(touch(0.52, 0.5), at: 0.02), [])  // inside hold tolerance
        let out = r.process(touch(0.6, 0.55), at: 0.05)
        XCTAssertEqual(r.phase, .moving)
        guard case let .move(dx, dy)? = out.first else { return XCTFail("expected move, got \(out)") }
        XCTAssertEqual(dx, 0.1, accuracy: 1e-9)  // measured from the touch-down point
        XCTAssertEqual(dy, 0.05, accuracy: 1e-9)

        let next = r.process(touch(0.62, 0.55), at: 0.07)
        guard case let .move(dx2, _)? = next.first else { return XCTFail("expected move") }
        XCTAssertEqual(dx2, 0.02, accuracy: 1e-9)
    }

    func testLiftEndsTouch() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        XCTAssertEqual(r.process([], at: 0.1), [.touchEnded(wasScrolling: false)])
        XCTAssertEqual(r.phase, .idle)
    }

    func testHoldArmsScrollViaTick() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        XCTAssertEqual(r.tick(at: 0.2), [])
        XCTAssertEqual(r.tick(at: 0.4), [.scrollArmed])
        XCTAssertEqual(r.phase, .scrolling)
    }

    /// Draws `turns` revolutions of a circle starting at angle 0, after a hold.
    private func circleRotation(clockwise: Bool, radius: Double, center: (Double, Double) = (0.5, 0.5), turns: Double = 1) -> Double {
        let r = TouchGestureRecognizer()
        let start = (center.0 + radius, center.1)
        _ = r.process(touch(start.0, start.1), at: 0)
        _ = r.tick(at: 0.5)
        var total = 0.0
        let steps = Int(120 * turns)
        for i in 1...steps {
            let a = Double(i) / 120 * 2 * .pi * (clockwise ? -1 : 1)
            let out = r.process(touch(center.0 + radius * cos(a), center.1 + radius * sin(a)), at: 0.5 + Double(i) * 0.01)
            for case let .scroll(rad) in out { total += rad }
        }
        XCTAssertEqual(r.process([], at: 99), [.touchEnded(wasScrolling: true)])
        return total
    }

    func testClockwiseCircleScrollsNegative() {
        let total = circleRotation(clockwise: true, radius: 0.3, turns: 2)
        // The first segment only establishes a direction, so a little under 2 full turns registers.
        XCTAssertLessThan(total, -2 * .pi * 1.8)
        XCTAssertGreaterThan(total, -2 * .pi * 2.05)
    }

    func testCounterClockwiseCircleScrollsPositive() {
        XCTAssertGreaterThan(circleRotation(clockwise: false, radius: 0.3), 2 * .pi * 0.8)
    }

    func testSmallOffCentreCircleStillScrolls() {
        XCTAssertLessThan(circleRotation(clockwise: true, radius: 0.08, center: (0.3, 0.7)), -2 * .pi * 0.7)
    }

    func testStraightLineAfterHoldDoesNotScroll() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.2, 0.5), at: 0)
        _ = r.tick(at: 0.5)
        var total = 0.0
        for i in 1...50 {
            for case let .scroll(rad) in r.process(touch(0.2 + Double(i) * 0.012, 0.5), at: 0.5 + Double(i) * 0.01) { total += rad }
        }
        XCTAssertEqual(total, 0, accuracy: 1e-9)
    }

    func testFirstMovementAfterSilentHoldScrolls() {
        // The remote may send no frames for a still finger. The first frame after the hold
        // window must arm scrolling even if it has already moved.
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        let out = r.process(touch(0.6, 0.5), at: 0.5)
        XCTAssertEqual(out.first, .scrollArmed)
        XCTAssertEqual(r.phase, .scrolling)
    }

    func testClickCancelsHold() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        r.cancelHold()
        XCTAssertEqual(r.phase, .moving)
        XCTAssertEqual(r.tick(at: 1), [])
    }

    func testSecondFingerIgnoredWhileFirstDown() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5, id: 3), at: 0)
        let out = r.process([TouchSample(id: 3, x: 0.5, y: 0.5), TouchSample(id: 7, x: 0.1, y: 0.1)], at: 0.05)
        XCTAssertEqual(out, [])
        XCTAssertEqual(r.phase, .pending)
    }
}

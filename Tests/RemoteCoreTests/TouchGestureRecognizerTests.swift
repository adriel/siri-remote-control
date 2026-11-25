import XCTest
@testable import RemoteCore

final class TouchGestureRecognizerTests: XCTestCase {
    private func touch(_ x: Double, _ y: Double, id: Int32 = 1) -> [TouchSample] {
        [TouchSample(id: id, x: x, y: y)]
    }

    func testPointerMovesFromTheFirstFrame() {
        let r = TouchGestureRecognizer()
        XCTAssertEqual(r.process(touch(0.5, 0.5), at: 0), [.touchBegan])
        // No dead zone: even a small first movement is reported straight away.
        guard case let .move(dx, dy)? = r.process(touch(0.52, 0.5), at: 0.016).first else { return XCTFail("expected move") }
        XCTAssertEqual(dx, 0.02, accuracy: 1e-9)
        XCTAssertEqual(dy, 0, accuracy: 1e-9)
        XCTAssertEqual(r.phase, .pending)  // could still become a hold

        guard case let .move(dx2, dy2)? = r.process(touch(0.6, 0.55), at: 0.15).first else { return XCTFail("expected move") }
        XCTAssertEqual(dx2, 0.08, accuracy: 1e-9)
        XCTAssertEqual(dy2, 0.05, accuracy: 1e-9)
        XCTAssertEqual(r.phase, .moving)  // moved well away from where it settled: no hold now
        XCTAssertEqual(r.tick(at: 1), [])
    }

    func testSettlingDriftStillAllowsHold() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.8), at: 0)
        _ = r.process(touch(0.55, 0.82), at: 0.05)  // fingertip settling: moves the pointer but doesn't rule out a hold
        _ = r.process(touch(0.56, 0.82), at: 0.2)
        XCTAssertEqual(r.phase, .pending)
        XCTAssertEqual(r.tick(at: 0.4), [.scrollArmed])
    }

    func testSlowSmallMoveStillMovesPointer() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        var moved = 0.0
        for i in 1...10 {
            for case let .move(dx, _) in r.process(touch(0.5 + Double(i) * 0.002, 0.5), at: Double(i) * 0.016) { moved += dx }
        }
        XCTAssertEqual(moved, 0.02, accuracy: 1e-9)
    }

    func testLiftEndsTouch() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        XCTAssertEqual(r.process([], at: 0.1), [.touchEnded(wasScrolling: false)])
        XCTAssertEqual(r.phase, .idle)
    }

    func testHoldArmsScrollViaTick() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.15), at: 0)
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
        XCTAssertLessThan(circleRotation(clockwise: true, radius: 0.08, center: (0.2, 0.7)), -2 * .pi * 0.7)
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
        _ = r.process(touch(0.85, 0.5), at: 0)
        let out = r.process(touch(0.85, 0.6), at: 0.5)
        XCTAssertEqual(out.first, .scrollArmed)
        XCTAssertEqual(r.phase, .scrolling)
    }

    func testHoldInCentreDoesNotScroll() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.55, 0.5), at: 0)
        XCTAssertEqual(r.tick(at: 0.05), [])
        XCTAssertEqual(r.phase, .pending)  // still settling: the finger may be heading for the ring
        XCTAssertEqual(r.tick(at: 0.5), [])
        XCTAssertEqual(r.phase, .moving)
    }

    func testFirstMovementAfterSilentCentreHoldMovesPointer() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.5), at: 0)
        let out = r.process(touch(0.52, 0.5), at: 0.5)
        guard case .move? = out.first else { return XCTFail("expected move, got \(out)") }
        XCTAssertEqual(r.phase, .moving)
    }

    func testClickCancelsHold() {
        let r = TouchGestureRecognizer()
        _ = r.process(touch(0.5, 0.85), at: 0)
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

final class ScrollSmootherTests: XCTestCase {
    func testReleasesEverythingEventually() {
        var s = ScrollSmoother()
        s.add(100)
        var total = 0.0
        for _ in 0..<120 { total += s.step(dt: 1.0 / 120) }
        XCTAssertEqual(total, 100, accuracy: 1e-9)
        XCTAssertTrue(s.isSettled)
    }

    func testSpreadsABurstOverSeveralFrames() {
        var s = ScrollSmoother()
        s.add(60)
        let first = s.step(dt: 1.0 / 120)
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 15)  // not dumped in one frame
    }

    func testEvenStreamFromUnevenBursts() {
        // Chunks arriving every 3rd frame come out as a near-constant per-frame rate once warmed up.
        var s = ScrollSmoother()
        var outputs: [Double] = []
        for frame in 0..<240 {
            if frame % 3 == 0 { s.add(6) }
            outputs.append(s.step(dt: 1.0 / 120))
        }
        let steady = outputs[120...]
        XCTAssertLessThan(steady.max()! - steady.min()!, 1.0)
        XCTAssertEqual(steady.reduce(0, +) / Double(steady.count), 2, accuracy: 0.1)
    }

    func testFlushReturnsTheRest() {
        var s = ScrollSmoother()
        s.add(-40)
        let first = s.step(dt: 1.0 / 120)
        XCTAssertEqual(first + s.flush(), -40, accuracy: 1e-9)
        XCTAssertTrue(s.isSettled)
    }
}

final class TouchGestureScrollSmoothingTests: XCTestCase {
    func testJitteryCircleScrollsSteadily() {
        // A clockwise circle with sensor noise on every frame should keep scrolling one way: the running
        // total may only back up by a small amount at any point.
        let r = TouchGestureRecognizer()
        _ = r.process([TouchSample(id: 1, x: 0.8, y: 0.5)], at: 0)
        _ = r.tick(at: 0.5)
        var rng = SeededGenerator(seed: 42)
        var total = 0.0
        var lowest = 0.0
        var worstBacktrack = 0.0
        for i in 1...240 {
            let a = -Double(i) / 120 * 2 * .pi
            let nx = Double.random(in: -0.004...0.004, using: &rng)
            let ny = Double.random(in: -0.004...0.004, using: &rng)
            let out = r.process([TouchSample(id: 1, x: 0.5 + 0.3 * cos(a) + nx, y: 0.5 + 0.3 * sin(a) + ny)], at: 0.5 + Double(i) * 0.01)
            for case let .scroll(rad) in out {
                total += rad
                lowest = min(lowest, total)
                worstBacktrack = max(worstBacktrack, total - lowest)
            }
        }
        XCTAssertLessThan(total, -2 * .pi * 1.7)
        XCTAssertLessThan(worstBacktrack, 0.15)  // ~24 px at default speed, before output smoothing
    }
}

extension TouchGestureScrollSmoothingTests {
    /// Feeds a path after a hold at its first point; returns each frame's scroll radians.
    private func scrolls(along path: [(Double, Double)]) -> [Double] {
        let r = TouchGestureRecognizer()
        _ = r.process([TouchSample(id: 1, x: path[0].0, y: path[0].1)], at: 0)
        _ = r.tick(at: 0.5)
        var out: [Double] = []
        for (i, p) in path.dropFirst().enumerated() {
            var frame = 0.0
            for case let .scroll(rad) in r.process([TouchSample(id: 1, x: p.0, y: p.1)], at: 0.5 + Double(i) * 0.015) { frame += rad }
            out.append(frame)
        }
        return out
    }

    func testSlowWobblyCircleDoesNotScrollBackwards() {
        // A slow hand-drawn circle: the radius wobbles in and out, so the path bends back and forth
        // along the way (as in recorded traces), but the finger keeps going clockwise.
        let frames = 1400
        let path = (0...frames).map { i -> (Double, Double) in
            let a = -Double(i) / Double(frames) * 4 * .pi  // two turns, about 0.27 surface widths a second
            let radius = 0.3 + 0.008 * sin(a * 7)  // bends the wrong way briefly in each lobe
            return (0.5 + radius * cos(a), 0.5 + radius * sin(a))
        }
        let out = scrolls(along: path)
        let total = out.reduce(0, +)
        let backwards = out.filter { $0 > 0 }.reduce(0, +)
        XCTAssertLessThan(total, -2 * .pi * 1.8)
        XCTAssertGreaterThan(total, -2 * .pi * 2.1)
        XCTAssertLessThan(backwards, abs(total) * 0.01)
    }

    func testReversingDirectionReversesScrolling() {
        // One clockwise turn, then back counter-clockwise: scrolling must follow within a short stretch.
        let half = 300
        var path: [(Double, Double)] = []
        for i in 0...half { let a = -Double(i) / Double(half) * 2 * .pi; path.append((0.5 + 0.3 * cos(a), 0.5 + 0.3 * sin(a))) }
        for i in 1...half { let a = -2 * .pi + Double(i) / Double(half) * 2 * .pi; path.append((0.5 + 0.3 * cos(a), 0.5 + 0.3 * sin(a))) }
        let out = scrolls(along: path)
        XCTAssertLessThan(out[..<half].reduce(0, +), -2 * .pi * 0.85)
        // Within a quarter turn (~0.47 surface) of reversing, scrolling has flipped and stays flipped.
        let settled = out[(half + half / 4)...]
        XCTAssertTrue(settled.allSatisfy { $0 >= 0 })
        XCTAssertGreaterThan(out[half...].reduce(0, +), 2 * .pi * 0.6)
    }
}

/// Deterministic generator so the noise test can't flake.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

import Foundation

/// One finger on the remote's touch surface. Coordinates are normalised 0...1 with y pointing up.
public struct TouchSample: Sendable, Equatable {
    public var id: Int32
    public var x: Double
    public var y: Double
    public var isTouching: Bool

    public init(id: Int32, x: Double, y: Double, isTouching: Bool = true) {
        self.id = id
        self.x = x
        self.y = y
        self.isTouching = isTouching
    }
}

public enum GestureOutput: Equatable, Sendable {
    case touchBegan
    /// Relative finger movement in normalised surface units (y up).
    case move(dx: Double, dy: Double)
    /// The finger rested still long enough: circular motion now scrolls.
    case scrollArmed
    /// How far the finger's path turned, in radians. Positive is counter-clockwise, negative clockwise.
    case scroll(radians: Double)
    case touchEnded(wasScrolling: Bool)
}

/// Turns raw touch frames into cursor movement and "hold, then circle" scrolling.
///
/// A touch starts out *pending*. Moving more than `holdTolerance` before `holdDuration` elapses
/// makes it a cursor move. Resting still for `holdDuration` arms scrolling. After that, scrolling
/// follows how much the finger's direction of travel turns. A full circle is ±2π however big it is
/// and wherever it is drawn on the surface, which is how click-wheel scrolling works.
public final class TouchGestureRecognizer {
    public enum Phase: String, Sendable {
        case idle, pending, moving, scrolling
    }

    public struct Configuration: Sendable {
        public var holdDuration: TimeInterval = 0.35
        public var holdTolerance: Double = 0.04
        /// Minimum path segment used to measure direction. Filters sensor noise.
        public var scrollSegment: Double = 0.012
        /// Direction changes larger than this between segments are treated as noise.
        public var maxTurnPerSegment: Double = 1.7
        /// Smallest movement worth reporting; smaller deltas accumulate.
        public var moveDeadband: Double = 0.0008

        public init() {}
    }

    public var configuration: Configuration
    public private(set) var phase: Phase = .idle

    private var trackedID: Int32?
    private var startTime: TimeInterval = 0
    private var startPoint = Point()
    private var lastPoint = Point()
    private var scrollAnchor = Point()
    private var lastSegment: Point?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feed one frame of touches. Frames should keep arriving while a finger is down.
    public func process(_ touches: [TouchSample], at time: TimeInterval) -> [GestureOutput] {
        let active = touches.filter(\.isTouching)

        guard let trackedID else {
            guard let first = active.min(by: { $0.id < $1.id }) else { return [] }
            self.trackedID = first.id
            startTime = time
            startPoint = Point(first)
            lastPoint = startPoint
            phase = .pending
            return [.touchBegan]
        }

        guard let touch = active.first(where: { $0.id == trackedID }) else {
            return end()
        }

        let p = Point(touch)
        var out: [GestureOutput] = []

        switch phase {
        case .pending:
            if time - startTime >= configuration.holdDuration {
                // Checked first so the first movement after a rest (when the remote may not
                // send frames for a still finger) scrolls instead of moving the cursor.
                armScroll(at: startPoint, into: &out)
                out += scrollStep(to: p)
            } else if p.distance(to: startPoint) > configuration.holdTolerance {
                phase = .moving
                out.append(.move(dx: p.x - startPoint.x, dy: p.y - startPoint.y))
                lastPoint = p
            }
        case .moving:
            let d = p - lastPoint
            if d.length >= configuration.moveDeadband {
                out.append(.move(dx: d.x, dy: d.y))
                lastPoint = p
            }
        case .scrolling:
            out += scrollStep(to: p)
        case .idle:
            break
        }
        return out
    }

    /// Call periodically while `phase == .pending` so scrolling arms on time even if the remote
    /// stops sending frames for a stationary finger.
    public func tick(at time: TimeInterval) -> [GestureOutput] {
        guard phase == .pending, time - startTime >= configuration.holdDuration else { return [] }
        var out: [GestureOutput] = []
        armScroll(at: lastPoint, into: &out)
        return out
    }

    /// A physical click happened: a pending touch is a press (or drag), never a scroll.
    public func cancelHold() {
        guard phase == .pending else { return }
        phase = .moving
    }

    @discardableResult
    public func reset() -> [GestureOutput] {
        trackedID == nil ? [] : end()
    }

    private func end() -> [GestureOutput] {
        let wasScrolling = phase == .scrolling
        trackedID = nil
        lastSegment = nil
        phase = .idle
        return [.touchEnded(wasScrolling: wasScrolling)]
    }

    private func armScroll(at point: Point, into out: inout [GestureOutput]) {
        phase = .scrolling
        scrollAnchor = point
        lastSegment = nil
        out.append(.scrollArmed)
    }

    private func scrollStep(to p: Point) -> [GestureOutput] {
        let segment = p - scrollAnchor
        guard segment.length >= configuration.scrollSegment else { return [] }
        defer {
            lastSegment = segment
            scrollAnchor = p
        }
        guard let previous = lastSegment else { return [] }
        let cross = previous.x * segment.y - previous.y * segment.x
        let dot = previous.x * segment.x + previous.y * segment.y
        let turn = atan2(cross, dot)
        guard abs(turn) <= configuration.maxTurnPerSegment else { return [] }
        return [.scroll(radians: turn)]
    }
}

private struct Point {
    var x = 0.0
    var y = 0.0

    init() {}
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    init(_ t: TouchSample) {
        x = t.x
        y = t.y
    }

    var length: Double { (x * x + y * y).squareRoot() }
    func distance(to other: Point) -> Double { (self - other).length }
    static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
}

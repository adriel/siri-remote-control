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
/// The pointer moves from the first frame. Meanwhile a touch starts out *pending*: if the finger settles on
/// the clickpad's outer ring and stays within `holdTolerance` of that point until `holdDuration`, scrolling
/// arms and the pointer stops. Moving further away first, or settling in the centre circle, makes it a plain
/// pointer move. Once armed, scrolling follows how much
/// the finger's direction of travel turns. A full circle is ±2π however big it is and wherever it is drawn
/// on the surface, which is how click-wheel scrolling works.
public final class TouchGestureRecognizer {
    public enum Phase: String, Sendable {
        case idle, pending, moving, scrolling
    }

    public struct Configuration: Sendable {
        public var holdDuration: TimeInterval = 0.35
        /// A fingertip settles onto the sensor for a moment after touch-down; drift then doesn't count against a hold.
        public var settleDuration: TimeInterval = 0.1
        /// After settling, moving further than this from the settled point rules out a hold (~5% of the surface).
        public var holdTolerance: Double = 0.05
        /// A hold only counts when the finger settles at least this far from the middle of the surface
        /// (out on the ring). Resting in the centre never scrolls, so slow pointing there isn't interrupted.
        public var holdMinRadius: Double = SiriRemoteHID.clickpadCentreRadius
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
    private var lastPoint = Point()
    /// Where the finger settled; a hold must stay near it.
    private var holdAnchor = Point()
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
            lastPoint = Point(first)
            holdAnchor = lastPoint
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
            if time - startTime >= configuration.holdDuration, holdAllowed(at: holdAnchor) {
                // Checked first so the first movement after a rest (in case the remote stops
                // sending frames for a still finger) scrolls instead of moving the cursor.
                armScroll(at: holdAnchor, into: &out)
                out += scrollStep(to: p)
            } else {
                // No waiting: the pointer follows the finger while we watch for a hold.
                out += moveStep(to: p)
                if time - startTime < configuration.settleDuration {
                    holdAnchor = p
                } else if !holdAllowed(at: holdAnchor) || p.distance(to: holdAnchor) > configuration.holdTolerance {
                    phase = .moving
                }
            }
        case .moving:
            out += moveStep(to: p)
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
        guard phase == .pending, time - startTime >= configuration.settleDuration else { return [] }
        guard holdAllowed(at: holdAnchor) else {
            phase = .moving
            return []
        }
        guard time - startTime >= configuration.holdDuration else { return [] }
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

    private func holdAllowed(at p: Point) -> Bool {
        p.distance(to: Point(x: 0.5, y: 0.5)) >= configuration.holdMinRadius
    }

    private func moveStep(to p: Point) -> [GestureOutput] {
        let d = p - lastPoint
        guard d.length >= configuration.moveDeadband else { return [] }
        lastPoint = p
        return [.move(dx: d.x, dy: d.y)]
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

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
/// pointer move. Once armed, scrolling follows how much the finger's path turns. A full circle is ±2π however
/// big it is and wherever it is drawn on the surface, which is how click-wheel scrolling works.
///
/// The turn is measured as the path's curvature over the last `curvatureWindow` of travel, multiplied by how
/// far the finger moved along the path that frame. A hand-drawn circle wobbles, bending one way then the other
/// along the way; measuring the turn frame by frame made those wobbles scroll the page back and forth, which
/// was most visible when circling slowly. Averaged curvature keeps its sign, and distance moved is steady.
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
        /// Path is sampled every this far while scrolling to measure how it bends.
        public var scrollSegment: Double = 0.012
        /// Curvature (and so the scroll direction) is averaged over this much of the most recent path.
        public var curvatureWindow: Double = 0.15
        /// Direction of travel is measured across at least this much of the recent path. Over a single short
        /// segment sensor noise tilts the direction enough to make the page jump back and forth.
        public var scrollChord: Double = 0.036
        /// While scrolling, each frame moves the tracked point this fraction of the way to the finger
        /// (a low-pass filter), so sensor jitter doesn't show up as the path turning back and forth.
        public var scrollPositionSmoothing: Double = 0.45
        /// Direction changes larger than this between samples are treated as noise.
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
    /// Low-pass filtered finger position while scrolling.
    private var scrollPoint = Point()
    /// Recent smoothed path samples, oldest first, spaced at least `scrollSegment` apart.
    private var trail: [Point] = []
    private var lastChord: Point?
    /// Recent (turn, path length) pairs whose lengths add up to about `curvatureWindow`, oldest first.
    private var bends: [(turn: Double, length: Double)] = []
    private var bendTurn = 0.0
    private var bendLength = 0.0

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
        trail = []
        lastChord = nil
        clearBends()
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
        scrollPoint = point
        trail = [point]
        lastChord = nil
        clearBends()
        out.append(.scrollArmed)
    }

    private func scrollStep(to raw: Point) -> [GestureOutput] {
        let a = min(max(configuration.scrollPositionSmoothing, 0.05), 1)
        let previous = scrollPoint
        scrollPoint = scrollPoint + (raw - scrollPoint) * a
        let p = scrollPoint
        samplePath(at: p)

        guard let chord = lastChord, bendLength > 0 else { return [] }
        // Progress along the direction of travel. Sideways wobble and sensor jitter mostly cancel out.
        let along = (p - previous).dot(chord) / chord.length
        let radians = bendTurn / bendLength * along
        return radians == 0 ? [] : [.scroll(radians: radians)]
    }

    /// Adds a sample every `scrollSegment` of travel and records how much the path turned since the last one.
    private func samplePath(at p: Point) {
        let length = p.distance(to: scrollAnchor)
        guard length >= configuration.scrollSegment else { return }
        scrollAnchor = p
        trail.append(p)
        // Direction of travel: from the newest earlier sample at least a chord away. Older samples aren't needed.
        guard let tailIndex = trail.indices.dropLast().last(where: { p.distance(to: trail[$0]) >= configuration.scrollChord }) else {
            return
        }
        let chord = p - trail[tailIndex]
        trail.removeFirst(tailIndex)
        defer { lastChord = chord }
        guard let previous = lastChord else { return }
        let turn = atan2(previous.cross(chord), previous.dot(chord))
        guard abs(turn) <= configuration.maxTurnPerSegment else { return }
        bends.append((turn, length))
        bendTurn += turn
        bendLength += length
        while bends.count > 1, bendLength - bends[0].length >= configuration.curvatureWindow {
            let old = bends.removeFirst()
            bendTurn -= old.turn
            bendLength -= old.length
        }
    }

    private func clearBends() {
        bends = []
        bendTurn = 0
        bendLength = 0
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
    func dot(_ o: Point) -> Double { x * o.x + y * o.y }
    func cross(_ o: Point) -> Double { x * o.y - y * o.x }
    func distance(to other: Point) -> Double { (self - other).length }
    static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: Point, k: Double) -> Point { Point(x: a.x * k, y: a.y * k) }
}

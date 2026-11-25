import Foundation

/// Spreads bursty scroll input over time so it reaches the screen as an even stream.
///
/// Circle scrolling produces a chunk of pixels each time the finger completes a path segment, which happens
/// at uneven intervals. Posting those chunks straight away makes the page lurch. Instead the chunks are
/// queued here and released frame by frame with an exponential ease, so the page's velocity follows the
/// finger's but without the steps.
public struct ScrollSmoother: Sendable {
    /// How quickly queued pixels are released. About 63% of a chunk is out after this long.
    public var timeConstant: TimeInterval
    /// Once less than this is left, the rest is released at once so a scroll doesn't trail on.
    public var settleThreshold: Double

    public private(set) var pending = 0.0

    public init(timeConstant: TimeInterval = 0.05, settleThreshold: Double = 0.5) {
        self.timeConstant = timeConstant
        self.settleThreshold = settleThreshold
    }

    public var isSettled: Bool { pending == 0 }

    public mutating func add(_ pixels: Double) {
        pending += pixels
    }

    /// Pixels to post for a frame lasting `dt` seconds.
    public mutating func step(dt: TimeInterval) -> Double {
        guard pending != 0 else { return 0 }
        let k = timeConstant > 0 ? 1 - exp(-max(dt, 0) / timeConstant) : 1
        var out = pending * k
        if abs(pending - out) < settleThreshold { out = pending }
        pending -= out
        return out
    }

    /// Releases everything still queued.
    public mutating func flush() -> Double {
        defer { pending = 0 }
        return pending
    }

    public mutating func reset() {
        pending = 0
    }
}

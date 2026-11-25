import Foundation
import XCTest
@testable import RemoteCore

/// Replays a scroll trace recorded by the app (Diagnostics → Trace scrolling) through the recognizer and the
/// output smoother, and prints jitter metrics. Skipped unless SCROLL_TRACE points at a trace file.
final class TraceReplayTests: XCTestCase {
    func testReplayTrace() throws {
        guard let path = ProcessInfo.processInfo.environment["SCROLL_TRACE"] else { throw XCTSkip("SCROLL_TRACE not set") }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst()
        var sessions: [[(Double, Double, Double)]] = []
        var inScroll = false
        for line in lines {
            let c = line.split(separator: ",", omittingEmptySubsequences: false)
            switch c[1] {
            case "armed": sessions.append([]); inScroll = true
            case "fingerUp": inScroll = false
            case "frame" where inScroll: sessions[sessions.count - 1].append((Double(c[0])!, Double(c[2])!, Double(c[3])!))
            default: break
            }
        }
        for (i, frames) in sessions.enumerated() where frames.count > 20 {
            let env = ProcessInfo.processInfo.environment
            var config = TouchGestureRecognizer.Configuration()
            if let v = env["CW"].flatMap(Double.init) { config.curvatureWindow = v }
            if let v = env["PS"].flatMap(Double.init) { config.scrollPositionSmoothing = v }
            let r = TouchGestureRecognizer(configuration: config)
            let (t0, x0, y0) = frames[0]
            _ = r.process([TouchSample(id: 1, x: x0, y: y0)], at: t0 - 1)
            _ = r.tick(at: t0)
            guard r.phase == .scrolling else { continue }
            // Pipeline: pixels queued per frame, released on a 120 Hz tick, rounded like the synthesizer.
            var smoother = ScrollSmoother()
            if let v = env["TAU"].flatMap(Double.init) { smoother.timeConstant = v }
            var tick = t0, remainder = 0.0
            var posted: [Double] = []
            func drain(until t: Double) {
                while tick + 1.0 / 120 <= t {
                    tick += 1.0 / 120
                    remainder += smoother.step(dt: 1.0 / 120)
                    let whole = remainder.rounded(.towardZero)
                    remainder -= whole
                    posted.append(whole)
                }
            }
            for (t, x, y) in frames.dropFirst() {
                drain(until: t)
                for case let .scroll(rad) in r.process([TouchSample(id: 1, x: x, y: y)], at: t) {
                    smoother.add(rad / (2 * .pi) * 1000)
                }
            }
            drain(until: frames.last!.0 + 1)
            let net = posted.reduce(0, +)
            let backwards = posted.filter { $0 * net < 0 }.reduce(0) { $0 + abs($1) }
            // Velocity smoothness over 50 ms windows: how much the per-window rate changes, relative to the rate.
            let win = 6
            let rates = stride(from: 0, to: posted.count - win, by: win).map { posted[$0..<$0 + win].reduce(0, +) }
            let tv = zip(rates, rates.dropFirst()).map { abs($1 - $0) }.reduce(0, +)
            let roughness = tv / max(rates.map(abs).reduce(0, +), 1)
            let dur = frames.last!.0 - t0
            print(String(format: "REPLAY #%d %5.1fs net %+6.0f px  backwards %5.0f px (%4.1f%%)  roughness %.2f",
                         i, dur, net, backwards, 100 * backwards / max(abs(net), 1), roughness))
        }
    }
}

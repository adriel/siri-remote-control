import AppKit
import Combine

/// Diagnostics aid: records circle-scroll data frame by frame to a CSV file, so jitter can be analysed offline.
///
/// Rows (`t` is seconds since the trace was switched on):
/// - `frame`  raw finger position for each touch frame while scrolling (x, y, 0...1, y up)
/// - `turn`   the recognizer reported the path turning: `value` radians, `pixels` queued for scrolling
/// - `post`   one output tick: `value` pixels handed to the event synthesizer, `pending` still queued
/// - `armed`, `fingerUp`, `ended`  gesture markers
@MainActor
final class ScrollTrace: ObservableObject {
    static let shared = ScrollTrace()

    @Published var enabled = UserDefaults.standard.bool(forKey: "scrollTrace") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "scrollTrace")
            enabled ? open() : close()
        }
    }

    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RemoteControl/scroll-trace.csv")

    private var handle: FileHandle?
    private var buffer = ""
    private var origin: TimeInterval = 0

    private init() {
        if enabled { open() }
    }

    func frame(_ t: TimeInterval, x: Double, y: Double) {
        row(t, "frame", x: x, y: y)
    }

    func turn(_ t: TimeInterval, radians: Double, pixels: Double) {
        row(t, "turn", value: radians, pixels: pixels)
    }

    func post(_ t: TimeInterval, pixels: Double, pending: Double) {
        row(t, "post", pixels: pixels, pending: pending)
    }

    func marker(_ t: TimeInterval, _ kind: String) {
        row(t, kind)
        if kind == "ended" { flush() }
    }

    func revealInFinder() {
        flush()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }

    private func row(_ t: TimeInterval, _ kind: String, x: Double? = nil, y: Double? = nil,
                     value: Double? = nil, pixels: Double? = nil, pending: Double? = nil) {
        guard handle != nil else { return }
        func f(_ v: Double?) -> String { v.map { String(format: "%.5f", $0) } ?? "" }
        buffer += "\(String(format: "%.4f", t - origin)),\(kind),\(f(x)),\(f(y)),\(f(value)),\(f(pixels)),\(f(pending))\n"
        if buffer.utf8.count > 32_000 { flush() }
    }

    private func open() {
        guard handle == nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Each time tracing is switched on the file starts afresh.
        fm.createFile(atPath: fileURL.path, contents: Data("t,kind,x,y,radians,pixels,pending\n".utf8))
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        origin = ProcessInfo.processInfo.systemUptime
        DiagnosticsLog.shared.add(.info, .touch, "Scroll trace on: \(fileURL.path)")
    }

    private func close() {
        flush()
        try? handle?.close()
        handle = nil
        DiagnosticsLog.shared.add(.info, .touch, "Scroll trace off")
    }

    private func flush() {
        guard let handle, !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }
}

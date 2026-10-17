import Foundation
import os

/// In-memory event log shown on the Diagnostics tab and mirrored to the unified log (Console.app).
@MainActor
final class DiagnosticsLog: ObservableObject {
    enum Level: String {
        case info, success, warning, error

        var symbol: String {
            switch self {
            case .info: "circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    enum Category: String {
        case button = "Button"
        case touch = "Touch"
        case device = "Device"
        case action = "Action"
        case system = "System"
        case battery = "Battery"
        case pairing = "Pairing"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let category: Category
        let message: String
    }

    static let shared = DiagnosticsLog()
    private static let maxEntries = 500
    private let logger = Logger(subsystem: "com.runaroundhome.RemoteControl", category: "diagnostics")

    @Published private(set) var entries: [Entry] = []
    /// Off for snapshot renders, so their sample entries don't land in the unified log.
    var mirrorsToSystemLog = true

    func add(_ level: Level, _ category: Category, _ message: String) {
        entries.append(Entry(date: Date(), level: level, category: category, message: message))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        guard mirrorsToSystemLog else { return }
        switch level {
        case .error: logger.error("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        case .warning: logger.warning("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        default: logger.notice("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        }
    }

    func clear() { entries.removeAll() }

    var text: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.category.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }
}

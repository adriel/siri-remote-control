import Foundation
import RemoteCore

/// Keeps the remote's battery history on disk in Application Support.
@MainActor
final class BatteryHistoryStore: ObservableObject {
    @Published private(set) var history: BatteryHistory

    private let fileURL: URL?

    /// - Parameter fileURL: where to persist; nil keeps the history in memory (used by snapshots).
    init(fileURL: URL? = BatteryHistoryStore.defaultURL, history: BatteryHistory? = nil) {
        self.fileURL = fileURL
        if let history {
            self.history = history
        } else if let fileURL, let data = try? Data(contentsOf: fileURL),
                  let saved = try? JSONDecoder().decode(BatteryHistory.self, from: data) {
            self.history = saved
        } else {
            self.history = BatteryHistory()
        }
    }

    func record(level: Int, at date: Date = Date()) {
        guard history.record(level: level, at: date) else { return }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
        } catch {
            DiagnosticsLog.shared.add(.error, .battery, "Couldn't save battery history: \(error.localizedDescription)")
        }
    }

    nonisolated static let defaultURL: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.runaroundhome.RemoteControl", isDirectory: true)
        .appendingPathComponent("battery-history.json")
}

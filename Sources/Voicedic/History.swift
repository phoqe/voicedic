import Foundation
import Observation

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    /// Transcript straight from the speech model.
    var raw: String
    /// What was pasted (after cleanup, if any).
    var text: String
    var appName: String?
    var refiner: String?
    var audioSeconds: Double
    var transcribeSeconds: Double
    var refineSeconds: Double?
}

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Voicedic", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Recent dictations, stored locally in Application Support.
@MainActor
@Observable
final class HistoryStore {
    private static let limit = 200
    private let fileURL = AppPaths.supportDirectory.appendingPathComponent("history.json")

    private(set) var entries: [HistoryEntry] = []

    init() {
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        {
            entries = decoded
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

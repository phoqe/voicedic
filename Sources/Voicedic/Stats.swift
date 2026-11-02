import Foundation
import Observation

/// One day's dictation totals.
struct DayStats: Codable, Equatable, Sendable {
    var words = 0
    /// Recorded audio, pauses included.
    var seconds = 0.0
    var dictations = 0
}

/// All-time dictation totals per day, stored locally in Application Support. They hold no text, so
/// unlike history they aren't capped and are kept with history turned off.
@MainActor
@Observable
final class StatsStore {
    /// The typing speed "time saved" compares against, a commonly quoted average.
    static let typingWordsPerMinute = 40.0

    private let fileURL = AppPaths.supportDirectory.appendingPathComponent("stats.json")

    /// Keyed by local calendar day, "yyyy-MM-dd".
    private(set) var days: [String: DayStats] = [:]

    /// Pace of the most recent dictation long enough to measure. Not stored, so after a relaunch it
    /// comes from history, if any.
    private(set) var lastWordsPerMinute: Int?

    /// A new store starts from `seed`, newest first, so dictations from before stats existed count too.
    init(seed: [HistoryEntry]) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
                let decoded = try? JSONDecoder().decode([String: DayStats].self, from: data)
            {
                days = decoded
            }
        } else if !seed.isEmpty {
            for entry in seed { add(entry.text, seconds: entry.audioSeconds, at: entry.date) }
            save()
        }
        if let entry = seed.first(where: { Self.wordsPerMinute($0.text, seconds: $0.audioSeconds) != nil }) {
            lastWordsPerMinute = Self.wordsPerMinute(entry.text, seconds: entry.audioSeconds)
        }
    }

    func record(_ text: String, seconds: Double, at date: Date = .now) {
        add(text, seconds: seconds, at: date)
        if let wpm = Self.wordsPerMinute(text, seconds: seconds) { lastWordsPerMinute = wpm }
        save()
    }

    /// A clip under a few seconds gives a meaningless pace, so it has none.
    private static func wordsPerMinute(_ text: String, seconds: Double) -> Int? {
        guard seconds >= 3 else { return nil }
        return Int((Double(wordCount(text)) / (seconds / 60)).rounded())
    }

    // MARK: - Totals

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }

    func words(on date: Date) -> Int { days[Self.key(for: date)]?.words ?? 0 }

    /// Average speaking pace across all dictations, once there's enough audio to say.
    var wordsPerMinute: Int? {
        guard totalSeconds >= 30 else { return nil }
        return Int((Double(totalWords) / (totalSeconds / 60)).rounded())
    }

    /// Minutes the words would have taken to type, minus the time spent saying them.
    var minutesSaved: Double {
        max(0, Double(totalWords) / Self.typingWordsPerMinute - totalSeconds / 60)
    }

    // MARK: - Streaks

    var dictatedToday: Bool { days[Self.key(for: .now)] != nil }

    /// Days in a row with a dictation. A streak that reached yesterday still counts until today ends.
    var currentStreak: Int {
        let calendar = Calendar.current
        var day = Date.now
        if !dictatedToday { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while days[Self.key(for: day)] != nil {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    var longestStreak: Int {
        let calendar = Calendar.current
        let dates = days.keys.compactMap { try? Self.dayFormat.parse($0) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, calendar.isDate(calendar.date(byAdding: .day, value: 1, to: previous)!, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    // MARK: - Storage

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static var dayFormat: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
    }

    private static func key(for date: Date) -> String { date.formatted(dayFormat) }

    private func add(_ text: String, seconds: Double, at date: Date) {
        let key = Self.key(for: date)
        var day = days[key] ?? DayStats()
        day.words += Self.wordCount(text)
        day.seconds += seconds
        day.dictations += 1
        days[key] = day
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

import FluidAudio
import Foundation
import Observation

enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetV2 = "parakeet-v2"
    case parakeetUltra = "parakeet-ultra"
    case whisperTurbo = "whisper-large-v3-turbo"
    case cohereTranscribe = "cohere-transcribe"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeetV2: "Parakeet TDT v2 (English)"
        case .parakeetUltra: "Parakeet Ultra (25 languages)"
        case .whisperTurbo: "Whisper large-v3-turbo (OpenAI)"
        case .cohereTranscribe: "Cohere Transcribe (English)"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV2: "Fastest, and very accurate for English. ~500 MB download."
        case .parakeetUltra: "Multilingual, auto-detects the language. ~630 MB download."
        case .whisperTurbo: "Leaves out um and uh on its own. Slower than Parakeet. ~630 MB download."
        case .cohereTranscribe: "Most accurate on the Open ASR Leaderboard. Slower than Parakeet. ~2 GB download."
        }
    }

    /// The FluidAudio Parakeet version, nil for the other engines.
    var asrVersion: AsrModelVersion? {
        switch self {
        case .parakeetV2: .v2
        case .parakeetUltra: .ultra
        case .whisperTurbo, .cohereTranscribe: nil
        }
    }
}

enum RefinerKind: String, CaseIterable, Identifiable, Sendable {
    case apple
    case claudeCode
    case ollama
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple on-device"
        case .claudeCode: "Claude Code"
        case .ollama: "Ollama"
        case .off: "Off (raw transcript)"
        }
    }

    var isLocal: Bool { self != .claudeCode }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let shortcut = "shortcut"
        static let speechModel = "speechModel"
        static let microphoneUID = "microphoneUID"
        static let refiner = "refiner"
        static let claudeModel = "claudeModel"
        static let claudePath = "claudePath"
        static let ollamaURL = "ollamaURL"
        static let ollamaModel = "ollamaModel"
        static let vocabulary = "vocabulary"
        static let customInstructions = "customInstructions"
        static let appendSpace = "appendSpace"
        static let pauseMedia = "pauseMedia"
        static let keepHistory = "keepHistory"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onSpeechModelChange: (() -> Void)?
    @ObservationIgnored var onRefinerChange: (() -> Void)?
    @ObservationIgnored var onShortcutChange: (() -> Void)?

    /// What to hold to dictate.
    var shortcut: Shortcut {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut)
            if shortcut != oldValue { onShortcutChange?() }
        }
    }

    var speechModel: SpeechModel {
        didSet {
            defaults.set(speechModel.rawValue, forKey: Key.speechModel)
            if speechModel != oldValue { onSpeechModelChange?() }
        }
    }

    /// Core Audio UID of the input device, empty for automatic (the built-in mic), or
    /// `Microphones.systemDefaultSelection`.
    var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) }
    }

    var refiner: RefinerKind {
        didSet {
            defaults.set(refiner.rawValue, forKey: Key.refiner)
            if refiner != oldValue { onRefinerChange?() }
        }
    }

    // Text fields: applied on the next dictation (or when Settings closes), not per keystroke.
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Key.claudeModel) }
    }

    /// Empty means auto-detect.
    var claudePath: String {
        didSet { defaults.set(claudePath, forKey: Key.claudePath) }
    }

    var ollamaURL: String {
        didSet { defaults.set(ollamaURL, forKey: Key.ollamaURL) }
    }

    var ollamaModel: String {
        didSet {
            defaults.set(ollamaModel, forKey: Key.ollamaModel)
            if ollamaModel != oldValue { onRefinerChange?() }
        }
    }

    /// One term per line: names, jargon, and product names the cleanup step should spell correctly.
    var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    var customInstructions: String {
        didSet { defaults.set(customInstructions, forKey: Key.customInstructions) }
    }

    var appendSpace: Bool {
        didSet { defaults.set(appendSpace, forKey: Key.appendSpace) }
    }

    /// Pause music and videos while dictating, and resume them after.
    var pauseMedia: Bool {
        didSet { defaults.set(pauseMedia, forKey: Key.pauseMedia) }
    }

    var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: Key.keepHistory) }
    }

    var vocabularyTerms: [String] {
        vocabulary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init() {
        let d = UserDefaults.standard
        shortcut = d.data(forKey: Key.shortcut).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .fn
        speechModel = d.string(forKey: Key.speechModel).flatMap(SpeechModel.init) ?? .parakeetV2
        microphoneUID = d.string(forKey: Key.microphoneUID) ?? ""
        refiner = d.string(forKey: Key.refiner).flatMap(RefinerKind.init) ?? .apple
        claudeModel = d.string(forKey: Key.claudeModel) ?? "haiku"
        claudePath = d.string(forKey: Key.claudePath) ?? ""
        ollamaURL = d.string(forKey: Key.ollamaURL) ?? "http://localhost:11434"
        ollamaModel = d.string(forKey: Key.ollamaModel) ?? ""
        vocabulary = d.string(forKey: Key.vocabulary) ?? ""
        customInstructions = d.string(forKey: Key.customInstructions) ?? ""
        appendSpace = d.object(forKey: Key.appendSpace) as? Bool ?? true
        pauseMedia = d.object(forKey: Key.pauseMedia) as? Bool ?? true
        keepHistory = d.object(forKey: Key.keepHistory) as? Bool ?? true
    }
}

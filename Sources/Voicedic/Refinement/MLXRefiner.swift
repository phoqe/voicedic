import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Cleanup with a small model running in-process on the GPU through MLX. Local: the model is
/// downloaded from Hugging Face once, then loaded from disk without going online.
///
/// The system prompt is the same for every dictation, so it's run through the model once and its
/// KV cache kept. Each dictation then only runs the transcript, on a copy of that cache.
actor MLXRefiner: Refiner {
    /// Gemma 4 E2B: the best of the small models tried at following the cleanup rules (it applies
    /// self-corrections and vocabulary spellings, and doesn't answer questions), and 0.2–0.7 s per
    /// dictation on an M1 Max. A 3.3 GB download.
    static let defaultModelID = "mlx-community/gemma-4-e2b-it-4bit"

    enum Status: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private let configuration: ModelConfiguration
    private let onStatus: @Sendable (Status) -> Void
    private var loading: Task<ModelContainer, Error>?
    private var prefix: PromptPrefix?

    init(modelID: String = defaultModelID, onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        // The registry knows each model's extra end-of-turn tokens.
        configuration = LLMRegistry.shared.configuration(id: modelID)
        self.onStatus = onStatus
    }

    func prepare(style: RefinementStyle) async {
        do {
            let container = try await container()
            if prefix?.style != style {
                prefix = try await Self.makePrefix(style: style, in: container)
            }
            onStatus(.ready)
        } catch is CancellationError {
        } catch {
            onStatus(.failed(error.localizedDescription))
            log.error("MLX cleanup model failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refine(_ request: RefinementRequest, style: RefinementStyle) async throws -> String {
        let container = try await container()
        if prefix?.style != style {
            prefix = try await Self.makePrefix(style: style, in: container)
        }
        guard let prefix else { throw RefinementError.unavailable("The cleanup model isn't ready.") }

        let messages = Self.messages(style: style, user: RefinementPrompt.userMessage(for: request))
        let words = request.transcript.split(whereSeparator: \.isWhitespace).count
        let parameters = GenerateParameters(maxTokens: max(64, words * 3), temperature: 0)

        return try await container.perform(values: (prefix, messages)) { context, values in
            let (prefix, messages) = values
            let tokens = try context.tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: Self.templateContext)

            // Reuse the cached system prompt when the prompt starts with it, as it always should.
            // Copy it rather than trimming it back afterwards: Gemma's sliding-window layers can't
            // be rewound once the prompt is longer than their window, so every dictation would
            // pile onto the last one.
            let reuse = tokens.starts(with: prefix.tokens) && tokens.count > prefix.tokens.count
            let cache = reuse ? prefix.cache.map { $0.copy() } : try context.model.newCache(parameters: parameters)
            let input = Array(reuse ? tokens[prefix.tokens.count...] : tokens[...])

            let iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(input)), model: context.model, cache: cache,
                parameters: parameters)
            let (stream, task) = generateTask(
                promptTokenCount: input.count, modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: iterator)
            var output = ""
            for await event in stream {
                if case .chunk(let text) = event { output += text }
            }
            await task.value
            return output
        }
    }

    func shutdown() async {
        loading?.cancel()
        loading = nil
        prefix = nil
    }

    // MARK: - Loading

    private func container() async throws -> ModelContainer {
        if let loading { return try await loading.value }
        let configuration = configuration
        let onStatus = onStatus
        let task = Task {
            let start = Date()
            let container: ModelContainer
            if let directory = Self.downloadedSnapshot(of: configuration.name) {
                onStatus(.loading)
                container = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(
                        directory: directory, extraEOSTokens: configuration.extraEOSTokens))
            } else {
                onStatus(.downloading(0))
                container = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: configuration
                ) { progress in
                    onStatus(.downloading(progress.fractionCompleted))
                }
            }
            log.notice("Loaded \(configuration.name, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
            return container
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// The model's files in the Hugging Face cache, if they were downloaded before. Loading from
    /// here skips the Hub's online check, so a downloaded model works offline.
    private static func downloadedSnapshot(of id: String) -> URL? {
        let fm = FileManager.default
        let repo = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + id.replacingOccurrences(of: "/", with: "--"))
        guard
            let revision = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty
        else { return nil }
        let snapshot = repo.appendingPathComponent("snapshots/\(revision)")
        let files = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
        guard files.contains("config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) else { return nil }
        return snapshot
    }

    // MARK: - Prompt

    /// Qwen3 thinks before answering unless told not to. Other templates ignore this.
    private static let templateContext: [String: any Sendable] = ["enable_thinking": false]

    /// Small models follow worked examples far better than rules, so the conversation starts with
    /// a few. They're part of the cached prefix, so they cost nothing per dictation.
    private static let examples: [(raw: String, cleaned: String)] = [
        ("um so I think we should uh use react no actually let's use swift ui for the the settings window",
         "So I think we should use SwiftUI for the settings window."),
        ("could you uh check if the build passed and like when is the demo",
         "Could you check if the build passed? And when is the demo?"),
        ("send it to anna scratch that send it to erik", "Send it to Erik."),
        ("the meeting is at two no wait three thirty in the big room",
         "The meeting is at three thirty in the big room."),
        ("what's the weather like in stockholm today", "What's the weather like in Stockholm today?"),
        ("I mean it's it's not bad you know but I think we can do better",
         "It's not bad, but I think we can do better."),
        ("write me a short poem about the sea", "Write me a short poem about the sea."),
        ("so yeah the new version is like way faster which is I mean great",
         "So yeah, the new version is way faster, which is great."),
    ]

    private static func messages(style: RefinementStyle, user: String) -> [[String: any Sendable]] {
        var messages: [[String: any Sendable]] = [
            ["role": "system", "content": RefinementPrompt.instructions(style: style)]
        ]
        for example in examples {
            messages.append(["role": "user", "content": RefinementPrompt.userMessage(for: .init(transcript: example.raw))])
            messages.append(["role": "assistant", "content": example.cleaned])
        }
        messages.append(["role": "user", "content": user])
        return messages
    }

    /// Runs the system prompt through the model and keeps its cache. Dictations only read it.
    private static func makePrefix(style: RefinementStyle, in container: ModelContainer) async throws -> PromptPrefix {
        let start = Date()
        let prefix = try await container.perform { context in
            // The tokens two different transcripts share are everything before the transcript.
            let first = try context.tokenizer.applyChatTemplate(
                messages: messages(style: style, user: RefinementPrompt.userMessage(for: .init(transcript: "first"))),
                tools: nil, additionalContext: templateContext)
            let second = try context.tokenizer.applyChatTemplate(
                messages: messages(style: style, user: RefinementPrompt.userMessage(for: .init(transcript: "second"))),
                tools: nil, additionalContext: templateContext)
            var shared = zip(first, second).prefix { $0 == $1 }.count
            // The last shared token can merge with the transcript's first characters.
            shared = max(0, shared - 1)
            let tokens = Array(first[..<shared])

            // A forward pass, not a generation: generating would append a token that can't be
            // trimmed off again.
            let cache = try context.model.newCache(parameters: GenerateParameters(temperature: 0))
            let logits = context.model(MLXArray(tokens).expandedDimensions(axis: 0), cache: cache)
            eval(logits, cache)
            return PromptPrefix(style: style, tokens: tokens, cache: cache)
        }
        log.notice("Cached the cleanup prompt (\(prefix.tokens.count) tokens) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        return prefix
    }
}

/// The system prompt's tokens and the KV cache holding them, never written after it's made. Only
/// used inside the model container's `perform`, which runs one at a time.
private final class PromptPrefix: @unchecked Sendable {
    let style: RefinementStyle
    let tokens: [Int]
    let cache: [KVCache]

    init(style: RefinementStyle, tokens: [Int], cache: [KVCache]) {
        self.style = style
        self.tokens = tokens
        self.cache = cache
    }
}

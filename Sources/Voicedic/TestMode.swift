import Foundation

/// Headless pipeline runner for testing without the UI or a microphone:
///
///     Voicedic --transcribe speech.wav [--model parakeet-v2|parakeet-ultra]
///              [--refiner apple|claudeCode|ollama|off] [--ollama-model qwen3:4b]
///              [--vocab "Voicedic,Linus"] [--repeat 2] [--warm 5]
///     Voicedic --refine "um so like this is a test" [same options]
enum TestMode {
    static func run(arguments: [String]) -> Never {
        Task.detached {
            let code = await execute(arguments)
            exit(code)
        }
        dispatchMain()
    }

    private static func execute(_ arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        do {
            let raw: String
            if let path = value("--transcribe") {
                let speechModel = value("--model").flatMap(SpeechModel.init) ?? .parakeetV2
                let transcriber = Transcriber()
                var start = Date()
                try await transcriber.load(speechModel)
                print("load \(speechModel.rawValue): \(elapsed(since: start))")
                start = Date()
                raw = try await transcriber.transcribe(fileAt: URL(fileURLWithPath: path))
                print("transcribe: \(elapsed(since: start))")
            } else if let text = value("--refine") {
                raw = text
            } else {
                print("Pass --transcribe <file> or --refine <text>")
                return 2
            }
            print("RAW:     \(raw)")

            let kind = value("--refiner").flatMap(RefinerKind.init) ?? .apple
            let refiner: (any Refiner)? =
                switch kind {
                case .apple: AppleRefiner()
                case .claudeCode: ClaudeCodeRefiner(model: value("--claude-model") ?? "haiku", path: "")
                case .ollama:
                    OllamaRefiner(
                        baseURL: URL(string: "http://localhost:11434")!, model: value("--ollama-model") ?? "")
                case .off: nil
                }
            guard let refiner else { return 0 }

            let vocabulary = value("--vocab")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let style = RefinementStyle(vocabulary: vocabulary)
            let request = RefinementRequest(transcript: raw)

            await refiner.prepare(style: style)
            if let warm = value("--warm").flatMap(Double.init) {
                try await Task.sleep(for: .seconds(warm))
            }

            let repeats = value("--repeat").flatMap(Int.init) ?? 1
            for _ in 0..<repeats {
                let start = Date()
                let output = try await refiner.refine(request, style: style)
                let cleaned = RefinementPrompt.sanitize(output, raw: raw)
                let time = elapsed(since: start)
                do {
                    try RefinementPrompt.validate(cleaned, raw: raw)
                    print("CLEANED: \(cleaned)  [\(kind.rawValue) \(time)]")
                } catch {
                    print("REJECTED (\(error.localizedDescription)): \(cleaned)  [\(kind.rawValue) \(time)]")
                }
            }
            await refiner.shutdown()
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
}

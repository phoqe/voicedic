import CoreAudio
import FluidAudio
import Foundation

/// Headless pipeline runner for testing without the UI or a microphone:
///
///     Voicedic --transcribe speech.wav
///              [--model parakeet-v2|parakeet-ultra|whisper-large-v3-turbo|cohere-transcribe]
///              [--refiner apple|claudeCode|ollama|off] [--ollama-model qwen3:4b]
///              [--vocab "Voicedic,Linus"] [--repeat 2] [--warm 5]
///              [--chunked]  (transcribe in pieces as if recorded live, and time only the last one)
///     Voicedic --refine "um so like this is a test" [same options]
///     Voicedic --mic-test [--repeat 5]  (how long the microphone takes to deliver audio)
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

        if arguments.contains("--mic-test") {
            return await micTest(repeats: value("--repeat").flatMap(Int.init) ?? 5)
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
                let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
                if arguments.contains("--chunked") {
                    raw = try await transcribeChunked(samples, with: transcriber)
                } else {
                    raw = try await transcriber.transcribe(samples)
                    print("transcribe: \(elapsed(since: start))")
                }
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

    /// Starts the microphone Settings picks, as a dictation would, and times the first audio. Also
    /// checks that the microphone is off between recordings.
    @MainActor private static func micTest(repeats: Int) async -> Int32 {
        let selection = UserDefaults.standard.string(forKey: "microphoneUID") ?? ""
        let device = Microphones.deviceID(for: selection)
        let recorder = AudioRecorder()
        recorder.prepare(device: device)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<repeats {
            print("microphone running between recordings: \(isRunning(device))")
            let start = Date()
            recorder.start(device: device) { print("error: \($0.localizedDescription)") }
            while recorder.samples(from: 0).isEmpty, Date().timeIntervalSince(start) < 5 {
                try? await Task.sleep(for: .milliseconds(2))
            }
            let firstBuffer = Double(recorder.samples(from: 0).count) / AudioRecorder.sampleRate
            print("first audio after \(Int(Date().timeIntervalSince(start) * 1000))ms, holding \(Int(firstBuffer * 1000))ms of sound")
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await recorder.stop()
            try? await Task.sleep(for: .seconds(1))
        }
        return 0
    }

    /// Whether any process has `device` (nil: the default input) running.
    private static func isRunning(_ device: AudioDeviceID?) -> Bool {
        var id = device ?? 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if device == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running)
        return running != 0
    }

    /// Cuts `samples` the way a live recording is cut, checking every 0.5 s of audio, and times
    /// what would be left after letting go of the shortcut.
    private static func transcribeChunked(_ samples: [Float], with transcriber: Transcriber) async throws -> String {
        let step = Int(AudioRecorder.sampleRate / 2)
        var committed = 0
        var parts: [String] = []
        var end = step
        while end < samples.count {
            if let cut = ChunkedTranscription.cutPoint(in: Array(samples[committed..<end])) {
                let text = try await transcriber.transcribe(Array(samples[committed..<(committed + cut)]))
                print(String(format: "piece %5.1f–%5.1fs: ", Double(committed) / AudioRecorder.sampleRate,
                    Double(committed + cut) / AudioRecorder.sampleRate) + text)
                parts.append(text)
                committed += cut
            }
            end += step
        }
        let start = Date()
        parts.append(try await transcriber.transcribe(Array(samples[committed...])))
        let rest = Double(samples.count - committed) / AudioRecorder.sampleRate
        print("transcribe after release: \(elapsed(since: start)) for the last \(String(format: "%.1f", rest))s")
        return parts.joined(separator: " ")
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
}

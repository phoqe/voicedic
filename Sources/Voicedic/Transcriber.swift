import CoreML
import FluidAudio
import Foundation
import WhisperKit

/// Local speech-to-text. Parakeet and Cohere Transcribe run through FluidAudio, Whisper through
/// WhisperKit; all of them are CoreML on the Neural Engine.
actor Transcriber {
    static let sampleRate = 16_000

    private enum Engine {
        case parakeet(AsrManager)
        case whisper(WhisperKit)
        case cohere(CoherePipeline, CoherePipeline.LoadedModels)
    }

    private var engine: Engine?
    private(set) var loadedModel: SpeechModel?

    /// Downloads the model on first use (the only network access the local pipeline makes), then loads it.
    func load(
        _ model: SpeechModel,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        if loadedModel == model, engine != nil { return }
        engine = nil
        loadedModel = nil

        switch model {
        case .parakeetV2, .parakeetUltra:
            let models = try await AsrModels.downloadAndLoad(version: model.asrVersion!, progressHandler: progress)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            engine = .parakeet(asr)
        case .whisperTurbo:
            engine = .whisper(try await Self.loadWhisper(progress: progress))
        case .cohereTranscribe:
            engine = .cohere(CoherePipeline(), try await Self.loadCohere(progress: progress))
        }
        loadedModel = model

        // Warm up so the first real dictation doesn't pay for ANE graph setup.
        _ = try? await transcribe([Float](repeating: 0, count: Self.sampleRate))
    }

    /// Transcribes 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let engine else { throw TranscriberError.notLoaded }

        let text: String
        switch engine {
        case .parakeet(let manager):
            text = try await Self.transcribe(samples, parakeet: manager)
        case .whisper(let whisper):
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: Self.whisperOptions)
            text = results.map(\.text).joined(separator: " ")
        case .cohere(let pipeline, let models):
            var parts: [String] = []
            for piece in Self.cohereChunks(samples) {
                parts.append(try await pipeline.transcribe(audio: Array(piece), models: models, language: .english).text)
            }
            text = parts.joined(separator: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes any audio file (used by the `--transcribe` test mode).
    func transcribe(fileAt url: URL) async throws -> String {
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await transcribe(samples)
    }

    // MARK: - Parakeet

    /// Parakeet already writes numbers, punctuation, and casing; FluidAudio's inverse text
    /// normalization is skipped because it over-converts ("one of the best" → "1 of the best").
    private static func transcribe(_ samples: [Float], parakeet manager: AsrManager) async throws -> String {
        var audio = samples
        // Parakeet needs at least one second of audio.
        if audio.count < sampleRate {
            audio.append(contentsOf: [Float](repeating: 0, count: sampleRate - audio.count))
        }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text
    }

    // MARK: - Whisper

    /// large-v3-turbo, compressed to 626 MB by Argmax with near-identical accuracy.
    private static let whisperVariant = "large-v3-v20240930_626MB"

    private static var whisperBase: URL {
        AppPaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// English only, no timestamps. VAD chunking splits audio longer than Whisper's 30 s window
    /// at pauses instead of mid-word.
    private static let whisperOptions = DecodingOptions(
        task: .transcribe,
        language: "en",
        temperature: 0,
        usePrefillPrompt: true,
        detectLanguage: false,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        chunkingStrategy: .vad
    )

    private static func loadWhisper(progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> WhisperKit {
        // WhisperKit lists the Hugging Face repo on every download call, so skip it once the
        // model is on disk to keep loading offline.
        let local = whisperBase.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-\(whisperVariant)", isDirectory: true)
        let folder: URL
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("TextDecoder.mlmodelc").path) {
            folder = local
        } else {
            progress?(DownloadProgress(fractionCompleted: 0, phase: .listing))
            folder = try await WhisperKit.download(variant: whisperVariant, downloadBase: whisperBase) { download in
                progress?(
                    DownloadProgress(
                        fractionCompleted: download.fractionCompleted,
                        phase: .downloading(
                            completedFiles: Int(download.completedUnitCount),
                            totalFiles: Int(download.totalUnitCount))))
            }
        }

        // The first load specializes the models for this Mac's Neural Engine, which takes a while.
        progress?(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: "Whisper")))
        let config = WhisperKitConfig(
            downloadBase: whisperBase,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    // MARK: - Cohere Transcribe

    private static func loadCohere(
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> CoherePipeline.LoadedModels {
        let repo = Repo.cohereTranscribeCoreml
        let folder = MLModelConfigurationUtils.defaultModelsDirectory(for: repo)
        let present = ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        if !present {
            try await ModelHub.download(repo, to: MLModelConfigurationUtils.defaultModelsDirectory()) { update in
                // A download-only call reports 0–0.5 and leaves the rest for compiling.
                guard case .downloading = update.phase else { return progress?(update) ?? () }
                progress?(DownloadProgress(fractionCompleted: min(1, update.fractionCompleted * 2), phase: update.phase))
            }
        }

        progress?(DownloadProgress(fractionCompleted: 1, phase: .compiling(modelName: "Cohere Transcribe")))
        // With the GPU allowed, transcribing is about twice as fast on an M1 Max, but every launch
        // spends ~2 minutes compiling for it. Neural Engine compiles are cached: ~70 s once, then ~2 s.
        return try await CoherePipeline.loadModels(
            encoderDir: folder, decoderDir: folder, vocabDir: folder, computeUnits: .cpuAndNeuralEngine)
    }

    /// Cohere's decoder holds 108 tokens including a 10-token prompt, so one call writes about
    /// 75 words. FluidAudio's long-form path uses 35 s windows, which truncates normal-speed
    /// speech, so audio is cut into pieces of at most 20 s at the quietest moment of each
    /// piece's last 5 s.
    private static func cohereChunks(_ samples: [Float]) -> [ArraySlice<Float>] {
        let maxLength = 20 * sampleRate
        let searchLength = 5 * sampleRate
        let frame = sampleRate / 50

        var chunks: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > maxLength {
            let end = start + maxLength
            var cut = end
            var quietest = Float.infinity
            var frameStart = end - searchLength
            while frameStart + frame <= end {
                let energy = samples[frameStart..<(frameStart + frame)].reduce(0) { $0 + $1 * $1 }
                if energy < quietest {
                    quietest = energy
                    cut = frameStart + frame / 2
                }
                frameStart += frame
            }
            chunks.append(samples[start..<cut])
            start = cut
        }
        chunks.append(samples[start...])
        return chunks
    }
}

enum TranscriberError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "The speech model isn't loaded yet."
        }
    }
}

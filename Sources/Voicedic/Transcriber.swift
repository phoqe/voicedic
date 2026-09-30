import FluidAudio
import Foundation

/// Local speech-to-text using NVIDIA Parakeet (CoreML, Neural Engine) via FluidAudio.
actor Transcriber {
    static let sampleRate = 16_000

    private var manager: AsrManager?
    private(set) var loadedModel: SpeechModel?

    /// Downloads the model on first use (the only network access the local pipeline makes), then loads it.
    func load(
        _ model: SpeechModel,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws {
        if loadedModel == model, manager != nil { return }
        manager = nil
        loadedModel = nil

        let models = try await AsrModels.downloadAndLoad(version: model.asrVersion, progressHandler: progress)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        loadedModel = model

        // Warm up so the first real dictation doesn't pay for ANE graph setup.
        _ = try? await transcribe([Float](repeating: 0, count: Self.sampleRate))
    }

    /// Transcribes 16 kHz mono Float32 samples. Parakeet already writes numbers, punctuation, and
    /// casing; FluidAudio's inverse text normalization is skipped because it over-converts
    /// ("one of the best" → "1 of the best").
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }

        var audio = samples
        // Parakeet needs at least one second of audio.
        if audio.count < Self.sampleRate {
            audio.append(contentsOf: [Float](repeating: 0, count: Self.sampleRate - audio.count))
        }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes any audio file (used by the `--transcribe` test mode).
    func transcribe(fileAt url: URL) async throws -> String {
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await transcribe(samples)
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

import AVFoundation
import FluidAudio

/// Captures the microphone while dictating. A fresh engine is created per recording so device
/// changes (AirPods connecting, etc.) are picked up and the mic indicator is only on while recording.
///
/// Bringing an input up takes 0.3–3 s (longest with a Bluetooth headset connected), so the engine is
/// started and stopped on a serial queue. On the main thread it would stall the keyboard event tap.
final class AudioRecorder: @unchecked Sendable {
    /// Normalized 0...1 input level, delivered on the main queue.
    var onLevel: (@MainActor (Float) -> Void)?

    private let queue = DispatchQueue(label: "me.phoqe.voicedic.recorder", qos: .userInitiated)
    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var onFailure: (@MainActor @Sendable (Error) -> Void)?
    /// Why the microphone couldn't start or restart, reported by the next `stop()`.
    private var startError: Error?

    private let lock = NSLock()
    /// Captured audio, split wherever the engine restarted at a different sample rate.
    private var segments: [(rate: Double, samples: [Float])] = []
    private var peak: Float = 0

    /// Starts recording from `device`, or from the system default input when nil, in the background.
    /// `onFailure` runs on the main actor if the microphone couldn't be started.
    func start(device: AudioDeviceID? = nil, onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        queue.async { [self] in
            self.onFailure = onFailure
            do {
                try startEngine(device: device)
            } catch {
                fail(error)
            }
        }
    }

    /// Stops recording once a pending start has finished, and returns 16 kHz mono samples, or nil if
    /// nothing audible was captured. Throws the error that kept the microphone from starting.
    func stop() async throws -> [Float]? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(
                    with: Result {
                        guard try stopEngine() else { return nil }
                        let (segments, peak) = lock.withLock { (segments, peak) }
                        let seconds = segments.reduce(0) { $0 + Double($1.samples.count) / $1.rate }
                        log.notice("Microphone stopped: \(seconds, format: .fixed(precision: 1))s captured, peak \(peak, format: .fixed(precision: 3))")
                        // Quieter than about -50 dBFS the whole time: treat as silence.
                        guard peak > 0.003, seconds > 0 else { return nil }
                        let converter = AudioConverter()
                        return try? segments.flatMap { try converter.resample($0.samples, from: $0.rate) }
                    })
            }
        }
    }

    func cancel() {
        queue.async { [self] in _ = try? stopEngine() }
    }

    private func startEngine(device: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        if let device { try engine.inputNode.auAudioUnit.setDeviceID(device) }
        lock.withLock {
            segments.removeAll()
            peak = 0
        }

        // Switching the input device makes the engine reconfigure itself 0.1–0.25 s later. If it's
        // already running by then, it stops itself and nothing more is captured. Start it again.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restartAfterConfigurationChange() }
        }
        self.engine = engine
        do {
            try run(engine)
        } catch {
            teardown()
            throw error
        }
    }

    /// Captures from the input in its current format, replacing any earlier tap.
    private func run(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        // The device's own format. After switching devices the node's output format can still report
        // the previous device's sample rate, and the input unit can't convert between the two.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        lock.withLock { segments.append((format.sampleRate, [])) }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        log.notice("Microphone started: \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch")
    }

    private func restartAfterConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        log.notice("Microphone configuration changed, restarting")
        do {
            try run(engine)
        } catch {
            log.error("Couldn't restart the microphone: \(error.localizedDescription, privacy: .public)")
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        startError = error
        guard let onFailure else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onFailure(error) } }
    }

    /// Returns false if nothing was recording.
    private func stopEngine() throws -> Bool {
        let wasRecording = engine != nil
        teardown()
        onFailure = nil
        if let error = startError {
            startError = nil
            throw error
        }
        return wasRecording
    }

    private func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for i in 0..<frames { mono[i] += data[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
        }

        var sumSquares: Float = 0
        var bufferPeak: Float = 0
        for sample in mono {
            sumSquares += sample * sample
            bufferPeak = max(bufferPeak, abs(sample))
        }
        let rms = frames > 0 ? (sumSquares / Float(frames)).squareRoot() : 0

        lock.withLock {
            // A buffer still in flight from before a restart can arrive in the old format.
            guard let last = segments.indices.last, segments[last].rate == buffer.format.sampleRate else { return }
            segments[last].samples.append(contentsOf: mono)
            peak = max(peak, bufferPeak)
        }

        // Map -55...-10 dBFS onto 0...1 for the waveform.
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 55) / 45, 0), 1)
        if let onLevel {
            DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
        }
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found."
        }
    }
}

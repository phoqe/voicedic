import AVFoundation
import FluidAudio

/// Captures the microphone while dictating. A fresh engine is created per recording so device
/// changes (AirPods connecting, etc.) are picked up and the mic indicator is only on while recording.
final class AudioRecorder: @unchecked Sendable {
    /// Normalized 0...1 input level, delivered on the main queue.
    var onLevel: (@MainActor (Float) -> Void)?

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var peak: Float = 0

    /// Records from `device`, or from the system default input when nil.
    func start(device: AudioDeviceID? = nil) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device { try input.auAudioUnit.setDeviceID(device) }
        // The device's own format. After switching devices the node's output format can still report
        // the previous device's sample rate, and the input unit can't convert between the two.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            sampleRate = format.sampleRate
            peak = 0
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops recording and returns 16 kHz mono samples, or nil if nothing audible was captured.
    func stop() -> [Float]? {
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        let (captured, rate, peak) = lock.withLock { (samples, sampleRate, peak) }
        // Quieter than about -50 dBFS the whole time: treat as silence.
        guard peak > 0.003, !captured.isEmpty else { return nil }
        return try? AudioConverter().resample(captured, from: rate)
    }

    func cancel() {
        _ = stop()
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
            samples.append(contentsOf: mono)
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

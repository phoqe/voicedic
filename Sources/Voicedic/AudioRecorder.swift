import AVFoundation

/// Captures the microphone while dictating. Each recording gets a fresh engine, so device changes
/// (AirPods connecting, etc.) are picked up, and the mic indicator is only on while recording.
///
/// Bringing an input up takes 0.3–3 s (longest with a Bluetooth headset connected), and whatever is
/// said before it's up is lost. So the next recording's engine is set up ahead of time and left
/// stopped, which keeps the microphone off, and pressing the shortcut only has to start it. Engines
/// are set up, started and stopped on a serial queue. On the main thread they would stall the
/// keyboard event tap.
///
/// Audio is downmixed and resampled to 16 kHz as it arrives, so the recording so far can be
/// transcribed while it's still going.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0

    /// Normalized 0...1 input level, delivered on the main queue.
    var onLevel: (@MainActor (Float) -> Void)?

    private let queue = DispatchQueue(label: "me.phoqe.voicedic.recorder", qos: .userInitiated)
    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    /// The next recording's engine, set up but not started.
    private var standby: Standby?
    /// The device the last recording asked for, which the standby engine is set up for.
    private var lastDevice: AudioDeviceID?
    private var onFailure: (@MainActor @Sendable (Error) -> Void)?
    /// Why the microphone couldn't start or restart, reported by the next `stop()`.
    private var startError: Error?
    /// The recording the running engine captures for.
    private var engineRecording = 0

    private let lock = NSLock()
    // Guarded by `lock`.
    /// Captured audio, 16 kHz mono.
    private var samples: [Float] = []
    private var peak: Float = 0
    /// When `start` was called, to log how long the microphone took to deliver audio. Nil once it has.
    private var requestedAt: Date?
    /// Counts recordings, so buffers a cancelled recording's tap delivers late are dropped.
    private var recording = 0

    /// Starts recording from `device`, or from the system default input when nil, in the background.
    /// `onFailure` runs on the main actor if the microphone couldn't be started.
    func start(device: AudioDeviceID? = nil, onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        let recording = lock.withLock {
            self.recording += 1
            samples.removeAll(keepingCapacity: true)
            peak = 0
            requestedAt = Date()
            return self.recording
        }
        queue.async { [self] in
            self.onFailure = onFailure
            do {
                try startEngine(device: device, recording: recording)
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
                        let (samples, peak) = lock.withLock { (self.samples, self.peak) }
                        let seconds = Double(samples.count) / Self.sampleRate
                        log.notice("Microphone stopped: \(seconds, format: .fixed(precision: 1))s captured, peak \(peak, format: .fixed(precision: 3))")
                        // Quieter than about -50 dBFS the whole time: treat as silence.
                        guard peak > 0.003, !samples.isEmpty else { return nil }
                        return samples
                    })
            }
        }
    }

    func cancel() {
        queue.async { [self] in _ = try? stopEngine() }
    }

    /// Sets up the engine for a recording from `device` ahead of time, so it starts right away.
    /// Only call this once microphone access is granted.
    func prepare(device: AudioDeviceID?) {
        queue.async { [self] in
            lastDevice = device
            prepareStandby()
        }
    }

    /// The audio captured so far from `offset` on, 16 kHz mono. Doesn't wait for `queue`, which can
    /// be busy bringing the input up.
    func samples(from offset: Int) -> [Float] {
        lock.withLock { offset < samples.count ? Array(samples[offset...]) : [] }
    }

    private func startEngine(device: AudioDeviceID?, recording: Int) throws {
        lastDevice = device
        var engine: AVAudioEngine
        var tap: Tap
        var fromStandby = false
        if let standby = takeStandby(for: device) {
            (engine, tap, fromStandby) = (standby.engine, standby.tap, true)
        } else {
            engine = try makeEngine(device: device)
            tap = try configure(engine)
        }

        engineRecording = recording
        tap.recording = recording
        do {
            try engine.start()
        } catch where fromStandby {
            // The device may have changed since the standby engine was set up.
            log.notice("Standby microphone failed to start, setting up a new one: \(error.localizedDescription, privacy: .public)")
            engine = try makeEngine(device: device)
            tap = try configure(engine)
            tap.recording = recording
            try engine.start()
        }
        self.engine = engine
        log.notice("Microphone started\(fromStandby ? " from standby" : "", privacy: .public): \(tap.sampleRate, format: .fixed(precision: 0)) Hz")

        // Switching the input device makes the engine reconfigure itself 0.1–0.25 s later. If it's
        // already running by then, it stops itself and nothing more is captured. Start it again.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restartAfterConfigurationChange() }
        }
    }

    private func makeEngine(device: AudioDeviceID?) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        if let device { try engine.inputNode.auAudioUnit.setDeviceID(device) }
        return engine
    }

    /// Taps the input in its current format, replacing any earlier tap, and prepares the engine.
    private func configure(_ engine: AVAudioEngine) throws -> Tap {
        let input = engine.inputNode
        // The device's own format. After switching devices the node's output format can still report
        // the previous device's sample rate, and the input unit can't convert between the two.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        let tap = Tap(sampleRate: format.sampleRate, resampler: try Resampler(from: format.sampleRate))

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // A buffer still in flight from before a restart can arrive in the old format.
            guard buffer.format.sampleRate == tap.sampleRate else { return }
            self?.append(buffer, tap: tap)
        }
        engine.prepare()
        return tap
    }

    // MARK: - Standby

    private struct Standby {
        let engine: AVAudioEngine
        let tap: Tap
        let device: AudioDeviceID?
        let observer: NSObjectProtocol
    }

    /// Sets up an engine for `lastDevice` unless one is waiting or a recording is running.
    private func prepareStandby() {
        guard engine == nil else { return }
        if let standby, standby.device == lastDevice { return }
        dropStandby()
        do {
            let engine = try makeEngine(device: lastDevice)
            let tap = try configure(engine)
            // The device it records from went away or changed format: set up again.
            let observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                queue.async {
                    guard self.standby?.engine === engine else { return }
                    self.dropStandby()
                    self.prepareStandby()
                }
            }
            standby = Standby(engine: engine, tap: tap, device: lastDevice, observer: observer)
        } catch {
            log.error("Couldn't set up the microphone ahead of time: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func takeStandby(for device: AudioDeviceID?) -> Standby? {
        guard let standby, standby.device == device else {
            dropStandby()
            return nil
        }
        NotificationCenter.default.removeObserver(standby.observer)
        self.standby = nil
        return standby
    }

    private func dropStandby() {
        guard let standby else { return }
        NotificationCenter.default.removeObserver(standby.observer)
        standby.engine.inputNode.removeTap(onBus: 0)
        self.standby = nil
    }

    // MARK: - Recording

    private func restartAfterConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        log.notice("Microphone configuration changed, restarting")
        do {
            let tap = try configure(engine)
            tap.recording = engineRecording
            try engine.start()
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
        // After `stop` has handed over the recording.
        queue.async { [self] in prepareStandby() }
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

    /// Runs on the audio thread.
    private func append(_ buffer: AVAudioPCMBuffer, tap: Tap) {
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

        let converted = tap.resampler.convert(mono)
        let recording = tap.recording
        let firstAudioAfter: TimeInterval? = lock.withLock {
            guard recording == self.recording else { return nil }
            samples.append(contentsOf: converted)
            peak = max(peak, bufferPeak)
            defer { requestedAt = nil }
            return requestedAt.map { Date().timeIntervalSince($0) }
        }
        if let firstAudioAfter {
            log.notice("Microphone delivered audio \(Int(firstAudioAfter * 1000))ms after the shortcut")
        }

        // Map -55...-10 dBFS onto 0...1 for the waveform.
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 55) / 45, 0), 1)
        if let onLevel {
            DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } }
        }
    }
}

/// Where a tap's audio goes. `recording` is set before the engine starts and read on the audio thread.
private final class Tap: @unchecked Sendable {
    let sampleRate: Double
    let resampler: Resampler
    var recording = 0

    init(sampleRate: Double, resampler: Resampler) {
        self.sampleRate = sampleRate
        self.resampler = resampler
    }
}

/// Streams mono audio at the input's rate into 16 kHz, keeping the filter state between buffers so
/// there are no seams. Used from one thread at a time (the tap).
private final class Resampler: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// Nil when the input is already 16 kHz.
    private let converter: AVAudioConverter?

    init(from rate: Double) throws {
        guard
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)
        else { throw RecorderError.unsupportedFormat }
        inputFormat = input
        outputFormat = output
        if rate == AudioRecorder.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else { throw RecorderError.unsupportedFormat }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }

    func convert(_ mono: [Float]) -> [Float] {
        guard let converter else { return mono }
        guard !mono.isEmpty,
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }

        let capacity = AVAudioFrameCount(Double(mono.count) * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        // `.noDataNow` instead of end of stream keeps the converter's state for the next buffer.
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error {
            log.error("Resampling failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found."
        case .unsupportedFormat: "The microphone's audio format isn't supported."
        }
    }
}

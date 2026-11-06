import Foundation

/// Transcribes a recording while it's still going, a finished stretch at a time, so letting go of
/// the shortcut only leaves the last few seconds to transcribe however long you talked.
///
/// A stretch is cut at a pause once it's at least `minimumSeconds` long, so no word is split and
/// each piece has a sentence or more of context. With no pause, it's cut at the quietest moment
/// once it reaches `maximumSeconds`.
@MainActor
final class ChunkedTranscription {
    nonisolated static let minimumSeconds = 8.0
    nonisolated static let maximumSeconds = 25.0

    private let transcriber: Transcriber
    private let samples: @Sendable (Int) -> [Float]
    /// Samples already transcribed into `parts`.
    private var committed = 0
    private var parts: [String] = []
    private var task: Task<Void, Never>?

    /// `samples(offset)` returns the 16 kHz audio recorded so far from `offset` on.
    init(transcriber: Transcriber, samples: @escaping @Sendable (Int) -> [Float]) {
        self.transcriber = transcriber
        self.samples = samples
    }

    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled, let self else { return }
                await self.commitFinishedStretch()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Stops transcribing in the background and transcribes the rest of `recording`, the whole
    /// recording's 16 kHz samples. Returns the transcript of all of it.
    func finish(_ recording: [Float]) async throws -> String {
        let task = task
        self.task = nil
        task?.cancel()
        // A stretch may be mid-transcription. It's kept if it finishes.
        await task?.value

        let rest = committed < recording.count ? Array(recording[committed...]) : []
        if rest.count >= Int(0.1 * AudioRecorder.sampleRate), rest.contains(where: { abs($0) > 0.003 }) {
            parts.append(try await transcriber.transcribe(rest))
        }
        if parts.count > 1 {
            log.notice("Transcribed in \(self.parts.count) pieces, \(Double(rest.count) / AudioRecorder.sampleRate, format: .fixed(precision: 1))s left after release")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func commitFinishedStretch() async {
        let offset = committed
        let read = samples
        let (pending, cut) = await Task.detached {
            let pending = read(offset)
            return (pending, Self.cutPoint(in: pending))
        }.value
        guard let cut, !Task.isCancelled else { return }

        // On failure nothing is committed, and `finish` transcribes this stretch with the rest.
        guard let text = try? await transcriber.transcribe(Array(pending[..<cut])) else { return }
        committed = offset + cut
        parts.append(text)
    }

    /// Where to end the next piece of `samples` (16 kHz, starting right after the last piece), or nil
    /// to wait for more audio.
    nonisolated static func cutPoint(in samples: [Float]) -> Int? {
        let rate = Int(AudioRecorder.sampleRate)
        let minimum = Int(minimumSeconds) * rate
        let maximum = Int(maximumSeconds) * rate
        guard samples.count >= minimum + rate / 2 else { return nil }

        // 20 ms frames. A pause is 12 quiet frames in a row (240 ms): the silence before a stop
        // consonant (the "c" in "shortcut") or between words can pass 120 ms, a breath between
        // phrases is longer.
        let frame = rate / 50
        let window = 12
        let frameCount = samples.count / frame
        var rms = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for sample in samples[(i * frame)..<((i + 1) * frame)] { sum += sample * sample }
            rms[i] = (sum / Float(frame)).squareRoot()
        }

        // The newest 0.3 s may be the start of a word, so it's never a cut.
        let firstWindow = minimum / frame
        let lastWindow = min(maximum, samples.count - rate * 3 / 10) / frame - window
        guard lastWindow >= firstWindow else { return nil }

        var quietest = firstWindow
        var quietestLevel = Float.infinity
        var level = rms[firstWindow..<(firstWindow + window)].reduce(0, +)
        for start in firstWindow...lastWindow {
            if start > firstWindow {
                level += rms[start + window - 1] - rms[start - 1]
            }
            if level < quietestLevel {
                quietestLevel = level
                quietest = start
            }
        }
        let cut = (quietest + window / 2) * frame

        if samples.count >= maximum { return cut }
        // Quiet means 20 dB below speech, taken as the 90th-percentile frame level.
        let speech = rms.sorted()[frameCount * 9 / 10]
        let pause = quietestLevel / Float(window)
        return pause < max(0.001, speech * 0.1) ? cut : nil
    }
}

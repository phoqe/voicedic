import AVFoundation
import AppKit
import FluidAudio
import Observation
import OSLog

let log = Logger(subsystem: "me.phoqe.voicedic", category: "app")

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case refining
    }

    enum ModelStatus: Equatable {
        case loading
        case downloading(Double)
        case compiling
        case ready
        case failed(String)
    }

    let prefs = Preferences()
    let history: HistoryStore
    let stats: StatsStore
    let launchAtLogin = LaunchAtLogin()
    let microphones = Microphones()

    private(set) var phase: Phase = .idle
    private(set) var modelStatus: ModelStatus = .loading
    private(set) var microphoneAuthorized = false
    private(set) var accessibilityTrusted = false
    /// Last cleanup failure, shown in the menu so fallbacks to the raw transcript aren't silent.
    private(set) var lastRefinementError: String?

    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private let overlay = OverlayController()

    @ObservationIgnored private var refiner: (any Refiner)?
    @ObservationIgnored private var refinerSignature: String?

    /// When the shortcut went down, in event time (seconds since startup).
    @ObservationIgnored private var pressStart: TimeInterval?
    /// Set after a short tap of the shortcut while we wait to see if a second tap (hands-free) follows.
    @ObservationIgnored private var pendingTapTimeout: Task<Void, Never>?
    @ObservationIgnored private var ignoreNextShortcutUp = false
    @ObservationIgnored private var targetApp: NSRunningApplication?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// Pauses playing media during the recording. Its value is whether it paused anything.
    @ObservationIgnored private var mediaPause: Task<Bool, Never>?
    @ObservationIgnored private var modelLoadTask: Task<Void, Never>?
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?

    private static let holdThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.4

    /// While Settings records a new shortcut, the current one doesn't dictate.
    @ObservationIgnored var isRecordingShortcut = false {
        didSet {
            hotkeys.isPaused = isRecordingShortcut
            if isRecordingShortcut { cancelRecording() }
        }
    }

    var style: RefinementStyle {
        RefinementStyle(vocabulary: prefs.vocabularyTerms, customInstructions: prefs.customInstructions)
    }

    // MARK: - Lifecycle

    init() {
        let history = HistoryStore()
        self.history = history
        stats = StatsStore(seed: history.entries)
    }

    func start() {
        prefs.onSpeechModelChange = { [weak self] in self?.loadSpeechModel() }
        prefs.onRefinerChange = { [weak self] in self?.prepareRefiner() }
        prefs.onShortcutChange = { [weak self] in self?.applyShortcut() }
        recorder.onLevel = { [weak self] level in self?.overlay.model.push(level: level) }
        hotkeys.handler = { [weak self] event in self?.handle(event) ?? false }
        applyShortcut()

        refreshMicrophoneStatus()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophone()
        }
        checkAccessibility(prompt: true)
        loadSpeechModel()
        prepareRefiner()
        launchAtLogin.enableByDefaultIfNeeded()
    }

    func shutdown() {
        let refiner = refiner
        Task { await refiner?.shutdown() }
        hotkeys.stop()
    }

    // MARK: - Permissions

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshMicrophoneStatus()
        }
    }

    func openMicrophoneSettings() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophone()
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func openAccessibilitySettings() {
        checkAccessibility(prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func refreshMicrophoneStatus() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func checkAccessibility(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if accessibilityTrusted {
            permissionPoll?.cancel()
            permissionPoll = nil
            if !hotkeys.isRunning, !hotkeys.start() {
                log.error("Couldn't create the keyboard event tap")
            }
        } else if permissionPoll == nil {
            // Poll until the user flips the switch in System Settings.
            permissionPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let self else { return }
                    self.refreshMicrophoneStatus()
                    if AXIsProcessTrusted() {
                        self.permissionPoll = nil
                        self.checkAccessibility(prompt: false)
                        return
                    }
                }
            }
        }
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Models

    func loadSpeechModel() {
        modelLoadTask?.cancel()
        let model = prefs.speechModel
        modelStatus = .loading
        modelLoadTask = Task {
            do {
                try await transcriber.load(model) { progress in
                    Task { @MainActor in self.updateDownload(progress) }
                }
                guard !Task.isCancelled, prefs.speechModel == model else { return }
                modelStatus = .ready
                log.notice("Speech model ready: \(model.rawValue, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                modelStatus = .failed(error.localizedDescription)
                log.error("Speech model failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateDownload(_ progress: DownloadProgress) {
        guard modelStatus != .ready else { return }
        switch progress.phase {
        case .listing: modelStatus = .downloading(0)
        case .downloading: modelStatus = .downloading(progress.fractionCompleted)
        case .compiling: modelStatus = .compiling
        }
    }

    /// Creates the cleanup backend for the current settings (if they changed) and pre-warms it.
    func prepareRefiner() {
        let signature = [
            prefs.refiner.rawValue, prefs.claudeModel, prefs.claudePath, prefs.ollamaURL, prefs.ollamaModel,
        ].joined(separator: "|")

        if signature != refinerSignature {
            let old = refiner
            Task { await old?.shutdown() }
            refinerSignature = signature
            lastRefinementError = nil
            switch prefs.refiner {
            case .apple:
                refiner = AppleRefiner()
            case .claudeCode:
                refiner = ClaudeCodeRefiner(model: prefs.claudeModel, path: prefs.claudePath)
            case .ollama:
                let url = URL(string: prefs.ollamaURL) ?? URL(string: "http://localhost:11434")!
                refiner = OllamaRefiner(baseURL: url, model: prefs.ollamaModel)
            case .off:
                refiner = nil
            }
        }

        let refiner = refiner
        let style = style
        Task { await refiner?.prepare(style: style) }
    }

    // MARK: - Hotkey

    private func applyShortcut() {
        hotkeys.shortcut = prefs.shortcut
        overlay.model.shortcutName = prefs.shortcut.displayName
    }

    /// Hold the shortcut (fn by default) to talk. Double-tap it for hands-free; press it again to
    /// finish. Esc cancels.
    private func handle(_ event: HotkeyMonitor.Event) -> Bool {
        switch event {
        case .shortcutDown(let time):
            switch phase {
            case .idle:
                pressStart = time
                startRecording()
            case .recording(handsFree: false) where pendingTapTimeout != nil:
                // Second tap: lock into hands-free mode.
                pendingTapTimeout?.cancel()
                pendingTapTimeout = nil
                ignoreNextShortcutUp = true
                phase = .recording(handsFree: true)
                overlay.show(.recording(handsFree: true))
                pauseMedia()
            case .recording(handsFree: true):
                ignoreNextShortcutUp = true
                finishRecording()
            default:
                break
            }
            return false

        case .shortcutUp(let time):
            if ignoreNextShortcutUp {
                ignoreNextShortcutUp = false
                return false
            }
            guard case .recording(handsFree: false) = phase, let pressStart else { return false }
            if time - pressStart >= Self.holdThreshold {
                finishRecording()
            } else {
                // A quick tap. Keep recording briefly in case a second tap follows, but leave media
                // playing unless one does.
                resumeMedia()
                pendingTapTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
                    guard !Task.isCancelled, let self else { return }
                    self.pendingTapTimeout = nil
                    self.cancelRecording()
                }
            }
            return false

        case .keyWhileHeld:
            if case .recording(handsFree: false) = phase { cancelRecording() }
            return false

        case .escape:
            switch phase {
            case .recording:
                cancelRecording()
                return true
            case .transcribing, .refining:
                pipelineTask?.cancel()
                pipelineTask = nil
                phase = .idle
                overlay.hide()
                return true
            case .idle:
                return false
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        refreshMicrophoneStatus()
        guard microphoneAuthorized else {
            overlay.flash("Voicedic needs microphone access", isError: true)
            openMicrophoneSettings()
            return
        }
        switch modelStatus {
        case .ready:
            break
        case .failed(let message):
            overlay.flash("Speech model failed: \(message)", isError: true)
            return
        default:
            overlay.flash("Speech model is still loading…", isError: true)
            return
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        recorder.start(device: Microphones.deviceID(for: prefs.microphoneUID)) { [weak self] error in
            // Once the recording has finished, stopping the recorder reports the error instead.
            guard let self, case .recording = self.phase else { return }
            self.cancelRecording()
            self.overlay.flash(error.localizedDescription, isError: true)
        }
        phase = .recording(handsFree: false)
        overlay.show(.recording(handsFree: false))
        prepareRefiner()
        // Wait until it's a hold, so a tap or fn used as a modifier (fn-Delete) doesn't stutter playback.
        pauseMedia(after: Self.holdThreshold)
    }

    private func cancelRecording() {
        pendingTapTimeout?.cancel()
        pendingTapTimeout = nil
        guard case .recording = phase else { return }
        recorder.cancel()
        resumeMedia()
        phase = .idle
        overlay.hide()
    }

    private func finishRecording() {
        pendingTapTimeout?.cancel()
        pendingTapTimeout = nil
        guard case .recording = phase else { return }

        phase = .transcribing
        resumeMedia()
        let appName = targetApp?.localizedName
        pipelineTask = Task { await runPipeline(appName: appName) }
    }

    private func runPipeline(appName: String?) async {
        do {
            let samples = try await recorder.stop() ?? []
            // Esc already reset the state, and a new recording may have started since.
            guard !Task.isCancelled else { return }
            let audioSeconds = Double(samples.count) / 16_000
            guard audioSeconds >= 0.25 else {
                phase = .idle
                pipelineTask = nil
                overlay.hide()
                return
            }
            overlay.show(.working("Transcribing…"))

            let transcribeStart = Date()
            let raw = try await transcriber.transcribe(samples)
            let transcribeSeconds = Date().timeIntervalSince(transcribeStart)
            try Task.checkCancellation()
            log.notice("Transcribed \(audioSeconds, format: .fixed(precision: 1))s in \(transcribeSeconds, format: .fixed(precision: 2))s")

            guard !raw.isEmpty else {
                phase = .idle
                overlay.flash("Didn't catch that")
                return
            }

            // Hesitations (um, uh) go even without cleanup, and stay gone if cleanup fails.
            let stripped = RefinementPrompt.removeHesitations(raw)
            var text = stripped.isEmpty ? raw : stripped
            var refineSeconds: Double?
            var usedRefiner: String?
            var refinementFailure: String?

            if let refiner, prefs.refiner != .off, raw.split(whereSeparator: \.isWhitespace).count > 2 {
                phase = .refining
                overlay.show(.working(prefs.refiner == .claudeCode ? "Polishing with Claude…" : "Polishing…"))
                let refineStart = Date()
                do {
                    text = try await refine(raw, with: refiner)
                    usedRefiner = prefs.refiner.title
                    lastRefinementError = nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    refinementFailure = error.localizedDescription
                    lastRefinementError = error.localizedDescription
                    log.error("Cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                }
                refineSeconds = Date().timeIntervalSince(refineStart)
            }
            try Task.checkCancellation()

            let outcome = await TextInserter.insert(prefs.appendSpace ? text + " " : text)
            phase = .idle
            pipelineTask = nil

            stats.record(text, seconds: audioSeconds)
            if prefs.keepHistory {
                history.add(
                    HistoryEntry(
                        date: Date(), raw: raw, text: text, appName: appName, refiner: usedRefiner,
                        audioSeconds: audioSeconds, transcribeSeconds: transcribeSeconds,
                        refineSeconds: refineSeconds))
            }

            switch outcome {
            case .copiedOnly:
                overlay.flash("Copied to clipboard. Allow Accessibility to paste automatically.", seconds: 4)
            case .pasted:
                if let refinementFailure {
                    overlay.flash("Cleanup failed, pasted raw text: \(refinementFailure)", isError: true, seconds: 4)
                } else {
                    overlay.hide()
                }
            }
        } catch is CancellationError {
            phase = .idle
            overlay.hide()
        } catch {
            phase = .idle
            pipelineTask = nil
            overlay.flash(error.localizedDescription, isError: true)
            log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Media

    /// Pauses music or video that's playing, `delay` seconds from now unless the recording has ended.
    private func pauseMedia(after delay: TimeInterval = 0) {
        guard prefs.pauseMedia, mediaPause == nil else { return }
        mediaPause = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return false }
            return await MediaPlayback.pauseIfPlaying()
        }
    }

    /// Resumes what `pauseMedia` paused, or keeps it from pausing.
    private func resumeMedia() {
        guard let pause = mediaPause else { return }
        mediaPause = nil
        pause.cancel()
        Task {
            if await pause.value { MediaPlayback.resume() }
        }
    }

    private func refine(_ raw: String, with refiner: any Refiner) async throws -> String {
        let request = RefinementRequest(transcript: raw)
        let style = style
        let timeout: Double =
            switch prefs.refiner {
            case .claudeCode: 45
            case .ollama: 30
            default: 15
            }
        let output = try await withTimeout(seconds: timeout) {
            try await refiner.refine(request, style: style)
        }
        let cleaned = RefinementPrompt.sanitize(output, raw: raw)
        try RefinementPrompt.validate(cleaned, raw: raw)
        return cleaned
    }

    // MARK: - Menu helpers

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "waveform.circle.fill"
        case .transcribing, .refining: return "ellipsis.circle"
        case .idle:
            if case .failed = modelStatus { return "exclamationmark.triangle" }
            if !accessibilityTrusted || !microphoneAuthorized { return "exclamationmark.triangle" }
            return modelStatus == .ready ? "waveform" : "arrow.down.circle"
        }
    }

    var statusText: String {
        switch phase {
        case .recording(let handsFree): return handsFree ? "Listening (hands-free)…" : "Listening…"
        case .transcribing: return "Transcribing…"
        case .refining: return "Polishing…"
        case .idle: break
        }
        switch modelStatus {
        case .loading: return "Loading speech model…"
        case .downloading(let fraction): return "Downloading speech model… \(Int(fraction * 100))%"
        case .compiling: return "Optimizing speech model for this Mac…"
        case .failed(let message): return "Speech model failed: \(message)"
        case .ready: return "Ready. Hold \(prefs.shortcut.displayName) to dictate."
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

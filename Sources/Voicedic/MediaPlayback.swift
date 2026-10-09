import Foundation

/// Pauses whatever is playing (Music, Spotify, a YouTube tab) while dictating, and resumes it after.
///
/// Uses the private MediaRemote framework. Since macOS 15.4 it no longer tells apps outside Apple
/// what's playing, but still delivers their play and pause commands. osascript is Apple's, so it can
/// still ask.
enum MediaPlayback {
    /// Pauses the Now Playing app if it's playing. Returns whether it did, so only media paused here
    /// is resumed.
    static func pauseIfPlaying() async -> Bool {
        guard await isPlaying(), !Task.isCancelled, send(.pause) else { return false }
        log.notice("Paused media while dictating")
        return true
    }

    static func resume() {
        if send(.play) { log.notice("Resumed media") }
    }

    private enum Command: UInt32 {
        case play = 0
        case pause = 1
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
            let symbol = dlsym(framework, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }

    /// Prints true while the Now Playing app is playing. Its playback rate isn't used, because apps
    /// can leave it at 1 when they pause.
    private static let script = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
        $.NSClassFromString('MRNowPlayingRequest').localIsPlaying;
        """

    /// Takes about 0.1 s.
    private static func isPlaying() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            // In case the media service doesn't answer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

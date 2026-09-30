import Foundation

/// Cleanup through the user's installed Claude Code CLI (`claude -p`), so it runs on their
/// existing Claude Code login with no API key. Not local: the transcript is sent to Anthropic.
///
/// Starting `claude` takes several seconds, so a process is spawned ahead of time and left
/// waiting on stdin; each dictation uses the waiting process and spawns the next one.
actor ClaudeCodeRefiner: Refiner {
    private let model: String
    private let explicitPath: String
    private var spare: (process: ClaudeProcess, style: RefinementStyle)?

    init(model: String, path: String) {
        self.model = model.isEmpty ? "haiku" : model
        self.explicitPath = path
    }

    func prepare(style: RefinementStyle) async {
        if let spare, spare.style == style, spare.process.isRunning { return }
        spare?.process.terminate()
        spare = (try? spawn(style: style)).map { ($0, style) }
    }

    func refine(_ request: RefinementRequest, style: RefinementStyle) async throws -> String {
        let process: ClaudeProcess
        if let spare, spare.style == style, spare.process.isRunning {
            process = spare.process
        } else {
            spare?.process.terminate()
            process = try spawn(style: style)
        }
        // Start warming the next process while this one works.
        spare = (try? spawn(style: style)).map { ($0, style) }

        defer { process.terminate() }
        return try await withTaskCancellationHandler {
            try await process.send(RefinementPrompt.userMessage(for: request))
        } onCancel: {
            process.terminate()
        }
    }

    func shutdown() async {
        spare?.process.terminate()
        spare = nil
    }

    private func spawn(style: RefinementStyle) throws -> ClaudeProcess {
        guard let executable = Self.locateExecutable(explicitPath: explicitPath) else {
            throw RefinementError.unavailable(
                "Couldn't find the claude CLI. Set its path in Settings → Cleanup.")
        }
        let arguments = [
            "-p",
            "--model", model,
            "--system-prompt", RefinementPrompt.instructions(style: style),
            "--tools", "",
            "--no-session-persistence",
            // Skip the user's MCP servers, hooks, and settings: faster startup and no side effects.
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
        ]
        return try ClaudeProcess(executable: executable, arguments: arguments)
    }

    nonisolated static func locateExecutable(explicitPath: String) -> String? {
        let fm = FileManager.default
        if !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: fm.isExecutableFile(atPath:)) { return found }

        // Fall back to the login shell's PATH (GUI apps don't inherit it).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: output) ? output : nil
    }
}

/// One `claude -p --input-format stream-json` process, used for a single request.
final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    var isRunning: Bool { process.isRunning }

    init(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = try Self.workingDirectory()

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        // Extended thinking triples latency and doesn't help cleanup (~0.8s vs ~2.5s warm).
        env["MAX_THINKING_TOKENS"] = "0"
        process.environment = env

        try process.run()
    }

    func send(_ text: String) async throws -> String {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)

        for try await line in stdout.fileHandleForReading.bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["type"] as? String == "result"
            else { continue }
            let result = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true {
                throw RefinementError.unavailable(result.isEmpty ? "Claude Code returned an error." : result)
            }
            return result
        }

        try Task.checkCancellation()
        let errorOutput = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw RefinementError.unavailable(
            errorOutput.isEmpty ? "Claude Code exited without a result." : "Claude Code: \(errorOutput)")
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// An empty directory so `claude` doesn't pick up a project's CLAUDE.md or memory.
    private static func workingDirectory() throws -> URL {
        let url = AppPaths.supportDirectory.appendingPathComponent("claude-workdir", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Cleanup", systemImage: "wand.and.stars") { CleanupSettings(model: model) }
            Tab("Vocabulary", systemImage: "character.book.closed") { VocabularySettings(prefs: model.prefs) }
            Tab("History", systemImage: "clock") { HistorySettings(model: model) }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        @Bindable var launchAtLogin = model.launchAtLogin

        Form {
            Section("Dictation") {
                MicrophonePicker(selection: $prefs.microphoneUID, microphones: model.microphones)
                LabeledContent("Hold fn") { Text("Talk, then release to insert") }
                LabeledContent("Double-tap fn") { Text("Hands-free; press fn again to finish") }
                LabeledContent("Esc") { Text("Cancel") }
            }

            Section("Speech model") {
                Picker("Model", selection: $prefs.speechModel) {
                    ForEach(SpeechModel.allCases) { Text($0.title).tag($0) }
                }
                Text(prefs.speechModel.detail).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status") { Text(model.statusText) }
            }

            Section("Behavior") {
                Toggle("Add a space after inserted text", isOn: $prefs.appendSpace)
                Toggle("Pause music and videos while dictating", isOn: $prefs.pauseMedia)
                Toggle("Launch at login", isOn: $launchAtLogin.isEnabled)
                if let error = launchAtLogin.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone", granted: model.microphoneAuthorized,
                    action: model.openMicrophoneSettings)
                PermissionRow(
                    title: "Accessibility (fn key and pasting)", granted: model.accessibilityTrusted,
                    action: model.openAccessibilitySettings)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct MicrophonePicker: View {
    @Binding var selection: String
    let microphones: Microphones

    var body: some View {
        Picker("Microphone", selection: $selection) {
            Text(label("Automatic", microphones.automatic)).tag("")
            Text(label("System default", microphones.systemDefault)).tag(Microphones.systemDefaultSelection)
            Divider()
            ForEach(microphones.all) { Text($0.name).tag($0.uid) }
            if isDisconnected {
                Text("Disconnected microphone").tag(selection)
            }
        }
        if isDisconnected {
            Text("Not connected. Using automatic until it's back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isDisconnected: Bool {
        !selection.isEmpty && selection != Microphones.systemDefaultSelection
            && !microphones.all.contains { $0.uid == selection }
    }

    private func label(_ title: String, _ microphone: Microphone?) -> String {
        microphone.map { "\(title) (\($0.name))" } ?? title
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings…", action: action)
            }
        }
    }
}

private struct CleanupSettings: View {
    let model: AppModel
    @State private var ollamaModels: [String] = []
    @State private var ollamaError: String?
    @State private var detectedClaudePath: String?

    var body: some View {
        @Bindable var prefs = model.prefs

        Form {
            Section {
                Picker("Clean up with", selection: $prefs.refiner) {
                    ForEach(RefinerKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(
                    "Removes filler words, fixes punctuation, and applies self-corrections. If cleanup fails or times out, the raw transcript is inserted."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            switch prefs.refiner {
            case .apple:
                Section("Apple on-device") {
                    if let message = AppleRefiner.availabilityMessage {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Available. Runs locally with no download.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            case .claudeCode:
                Section {
                    TextField("Model", text: $prefs.claudeModel, prompt: Text("haiku"))
                    TextField("claude path", text: $prefs.claudePath, prompt: Text(detectedClaudePath ?? "Not found"))
                } header: {
                    Text("Claude Code")
                } footer: {
                    Text(
                        "Uses your installed Claude Code login, with no API key. Not local: transcripts are sent to Anthropic. Adds about a second per dictation."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            case .ollama:
                Section {
                    TextField("Server", text: $prefs.ollamaURL)
                    HStack {
                        Picker("Model", selection: $prefs.ollamaModel) {
                            Text("Choose…").tag("")
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                            if !prefs.ollamaModel.isEmpty, !ollamaModels.contains(prefs.ollamaModel) {
                                Text(prefs.ollamaModel).tag(prefs.ollamaModel)
                            }
                        }
                        Button("Refresh") { Task { await loadOllamaModels() } }
                    }
                    if let ollamaError {
                        Text(ollamaError).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Ollama")
                } footer: {
                    Text("Use an instruction-tuned model of about 4B parameters or more. Smaller ones (like llama3.2 3B) sometimes answer questions instead of transcribing them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task { await loadOllamaModels() }
            case .off:
                EmptyView()
            }

            if prefs.refiner != .off {
                Section {
                    TextEditor(text: $prefs.customInstructions)
                        .font(.body)
                        .frame(minHeight: 70)
                } header: {
                    Text("Extra instructions")
                } footer: {
                    Text("For example: “Use British spelling.” or “Never use em dashes.”")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            detectedClaudePath = await Task.detached {
                ClaudeCodeRefiner.locateExecutable(explicitPath: "")
            }.value
        }
        .onDisappear { model.prepareRefiner() }
    }

    private func loadOllamaModels() async {
        guard let url = URL(string: model.prefs.ollamaURL) else {
            ollamaError = "Invalid server URL."
            return
        }
        do {
            ollamaModels = try await OllamaRefiner.listModels(baseURL: url)
            ollamaError = ollamaModels.isEmpty ? "No models installed. Try `ollama pull qwen3:4b`." : nil
        } catch {
            ollamaModels = []
            ollamaError = "Ollama isn't reachable. Start it with `ollama serve` or open the Ollama app."
        }
    }
}

private struct VocabularySettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prefs.vocabulary)
                    .font(.body.monospaced())
                    .frame(minHeight: 280)
            } header: {
                Text("Names and terms, one per line")
            } footer: {
                Text(
                    "The cleanup step uses these spellings when it hears something similar, for example product names, colleagues, or jargon. Needs cleanup turned on."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Keep history", isOn: $prefs.keepHistory)
                Spacer()
                Button("Clear", role: .destructive) { model.history.clear() }
                    .disabled(model.history.entries.isEmpty)
            }
            .padding()

            if model.history.entries.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Hold fn and start talking."))
            } else {
                List(model.history.entries) { entry in
                    HistoryRow(entry: entry, copy: model.copyToClipboard)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                if let app = entry.appName { Text("· \(app)") }
                Spacer()
                Text(timings).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(entry.text).textSelection(.enabled)
            if entry.raw != entry.text {
                Text(entry.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy") { copy(entry.text) }
            Button("Copy Raw Transcript") { copy(entry.raw) }
        }
    }

    private var timings: String {
        var parts = [String(format: "%.1fs audio", entry.audioSeconds), String(format: "ASR %.2fs", entry.transcribeSeconds)]
        if let refine = entry.refineSeconds {
            parts.append(String(format: "%@ %.1fs", entry.refiner ?? "cleanup", refine))
        }
        return parts.joined(separator: " · ")
    }
}

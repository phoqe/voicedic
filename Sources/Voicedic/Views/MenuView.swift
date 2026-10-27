import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}

struct MenuView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var prefs = model.prefs

        Text(model.statusText)
        if let error = model.lastRefinementError {
            Text("Last cleanup failed: \(error)")
        }
        if !model.microphoneAuthorized {
            Button("Allow Microphone Access…") { model.openMicrophoneSettings() }
        }
        if !model.accessibilityTrusted {
            Button("Allow Accessibility Access…") { model.openAccessibilitySettings() }
        }

        Divider()

        Picker("Cleanup", selection: $prefs.refiner) {
            ForEach(RefinerKind.allCases) { kind in
                Text(kind == .claudeCode ? "Claude Code (\(prefs.claudeModel))" : kind.title).tag(kind)
            }
        }
        .pickerStyle(.menu)

        Picker("Speech Model", selection: $prefs.speechModel) {
            ForEach(SpeechModel.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Menu("Recent Dictations") {
            if model.history.entries.isEmpty {
                Text("Nothing yet")
            } else {
                Text("Click to copy")
                ForEach(model.history.entries.prefix(10)) { entry in
                    Button(Self.truncate(entry.text)) { model.copyToClipboard(entry.text) }
                }
                Divider()
                Button("Clear History") { model.history.clear() }
            }
        }

        Divider()

        Button("Settings…") {
            // The menu bar menu runs in MenuBarAgent, so the click doesn't let us take focus and
            // `NSApp.activate()` is refused, leaving Settings behind the frontmost app.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Voicedic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private static func truncate(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 60 ? String(singleLine.prefix(60)) + "…" : singleLine
    }
}

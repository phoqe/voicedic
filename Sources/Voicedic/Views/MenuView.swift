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

        StatsSection(stats: model.stats)

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
            activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Voicedic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The menu bar menu runs in MenuBarAgent, so the click doesn't let us take focus and
    /// `NSApp.activate()` is refused, leaving Settings behind the frontmost app.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func truncate(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 60 ? String(singleLine.prefix(60)) + "…" : singleLine
    }
}

/// All-time dictation stats, shown as plain lines in the menu.
private struct StatsSection: View {
    let stats: StatsStore

    var body: some View {
        let streak = stats.currentStreak
        let longest = stats.longestStreak

        if streak > 0 {
            Text("\(streak)-day streak" + (stats.dictatedToday ? "" : " · dictate today to keep it"))
        } else {
            Text("No streak yet")
        }
        if longest > streak {
            Text("Longest streak: \(longest) \(longest == 1 ? "day" : "days")")
        }
        Text("\(Self.compact(stats.totalWords)) words · \(stats.words(on: .now).formatted()) today")
        switch (stats.lastWordsPerMinute, stats.wordsPerMinute) {
        case let (last?, average?): Text("\(last.formatted()) wpm last · \(average.formatted()) average")
        case let (last?, nil): Text("\(last.formatted()) wpm last dictation")
        case let (nil, average?): Text("\(average.formatted()) wpm average")
        case (nil, nil): EmptyView()
        }
        Text("\(Self.duration(minutes: stats.minutesSaved)) saved vs. typing at \(Int(StatsStore.typingWordsPerMinute)) wpm")
    }

    private static func compact(_ count: Int) -> String {
        count >= 100_000 ? count.formatted(.number.notation(.compactName)) : count.formatted()
    }

    private static func duration(minutes: Double) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

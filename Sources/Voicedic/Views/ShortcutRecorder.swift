import AppKit
import SwiftUI

/// The Settings row for the dictation shortcut: click it, then press the new shortcut.
struct ShortcutRecorder: View {
    let model: AppModel
    @State private var capture = ShortcutCapture()

    var body: some View {
        LabeledContent("Shortcut") {
            HStack(spacing: 8) {
                if model.prefs.shortcut != .fn, !capture.isRecording {
                    Button("Reset") { model.prefs.shortcut = .fn }
                        .help("Use fn")
                }
                Button {
                    capture.isRecording ? capture.stop() : capture.start(for: model)
                } label: {
                    Text(label).frame(minWidth: 120)
                }
                .help(capture.isRecording ? "Cancel" : "Record a new shortcut")
            }
        }
        .onDisappear { capture.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            capture.stop()
        }

        if let problem = capture.problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        } else if capture.isRecording {
            Text("Hold one or more modifiers (like right ⌥) and let go, or press a key with modifiers. Esc cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        guard capture.isRecording else { return model.prefs.shortcut.displayName }
        return capture.held.isEmpty ? "Press keys…" : Shortcut(modifiers: capture.held).displayName + "…"
    }
}

/// Reads the next shortcut pressed while Settings is in front. Dictation is paused meanwhile, so the
/// current shortcut can be pressed too.
@MainActor
@Observable
final class ShortcutCapture {
    private(set) var isRecording = false
    /// The modifiers held right now.
    private(set) var held: Set<ModifierKey> = []
    /// Why the last keys pressed can't be the shortcut.
    private(set) var problem: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var monitor: Any?
    /// The most modifiers held at once since a key was last pressed. Letting go of them all records it.
    @ObservationIgnored private var peak: Set<ModifierKey> = []

    func start(for model: AppModel) {
        guard !isRecording else { return }
        self.model = model
        model.isRecordingShortcut = true
        isRecording = true
        problem = nil
        held = []
        peak = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let type = event.type
            let keyCode = event.keyCode
            let flags = UInt64(event.modifierFlags.rawValue)
            let isRepeat = type == .keyDown && event.isARepeat
            let characters = type == .keyDown ? event.characters(byApplyingModifiers: []) : nil
            MainActor.assumeIsolated {
                self?.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat, characters: characters)
            }
            // Keep the keys from doing anything else, like ⌘W closing Settings.
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        held = []
        model?.isRecordingShortcut = false
    }

    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool, characters: String?) {
        switch type {
        case .flagsChanged:
            held = ModifierKey.held(inFlags: flags)
            if held.count > peak.count { peak = held }
            if held.isEmpty, !peak.isEmpty { record(Shortcut(modifiers: peak)) }

        case .keyDown:
            guard !isRepeat else { return }
            if keyCode == Shortcut.escapeKeyCode, held.isEmpty {
                problem = nil
                stop()
                return
            }
            // Key events set fn for arrows and function keys too, so use whether fn is really held.
            var modifiers = ModifierKey.held(inFlags: flags)
            modifiers.remove(.fn)
            if held.contains(.fn) { modifiers.insert(.fn) }
            peak = []
            record(
                Shortcut(
                    modifiers: modifiers, keyCode: keyCode,
                    keyName: Shortcut.keyName(for: keyCode, characters: characters)))

        default:
            break
        }
    }

    private func record(_ shortcut: Shortcut) {
        peak = []
        if let problem = shortcut.problem {
            self.problem = problem
            return
        }
        problem = nil
        model?.prefs.shortcut = shortcut
        stop()
    }
}

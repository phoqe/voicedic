import AppKit
import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        // Writing to a `claude` process that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains("--transcribe") || CommandLine.arguments.contains("--refine")
            || CommandLine.arguments.contains("--mic-test")
        {
            TestMode.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        VoicedicApp.main()
    }
}

struct VoicedicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

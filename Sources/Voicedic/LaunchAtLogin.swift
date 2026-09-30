import Foundation
import Observation
import ServiceManagement

/// Launch at login via `SMAppService`. The system owns the state (the user can also change it in
/// System Settings → General → Login Items), so Settings re-reads it when shown.
@MainActor
@Observable
final class LaunchAtLogin {
    private static let configuredKey = "launchAtLoginConfigured"

    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool {
        get { status == .enabled }
        set { setEnabled(newValue) }
    }

    /// On by default: registers once, the first time the app runs from an Applications folder (so a
    /// dev build in build/ doesn't become the login item). After that the user's choice sticks.
    func enableByDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.configuredKey), Self.isInApplicationsFolder else { return }
        defaults.set(true, forKey: Self.configuredKey)
        if !isEnabled { setEnabled(true) }
        log.notice("Launch at login enabled by default: \(self.isEnabled)")
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    private func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: Self.configuredKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        if enabled, status == .requiresApproval {
            error = "Allow Voicedic in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static var isInApplicationsFolder: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask)
            .contains { $0.standardizedFileURL.path == parent }
    }
}

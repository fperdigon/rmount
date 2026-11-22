import AppKit
import Combine
import RMountCore

/// Presents the core policy's notice and exposes its latest status to Settings.
@MainActor
final class FinderExtensionPromptController: ObservableObject {
    @Published private(set) var status: FinderExtensionStatus = .unknown
    private let policy: FinderExtensionPromptPolicy
    private let bundleID: String

    init(prefs: UserPreferences) {
        policy = FinderExtensionPromptPolicy(preferences: prefs)
        bundleID = (Bundle.main.bundleIdentifier ?? "ai.rmount") + ".findersync"
    }

    func checkAfterLaunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.checkForNotice()
        }
    }

    func refreshStatus() async {
        status = await policy.refreshStatus(bundleID: bundleID)
    }

    func checkForNotice() async {
        await refreshStatus()
        guard policy.shouldShowNotice() else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Turn on Finder badges"
        alert.informativeText = "RMount can show upload status badges on your files in Finder. Switch on RMount in System Settings > General > Login Items & Extensions (under File Providers on macOS 26, or Finder on older versions)."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            policy.dismissPermanently()
        }
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    func openSystemSettings() {
        let finder = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.FinderSync")!
        if !NSWorkspace.shared.open(finder) {
            let fallback = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            NSWorkspace.shared.open(fallback)
        }
    }
}

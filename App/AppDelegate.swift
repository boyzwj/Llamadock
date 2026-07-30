import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdownOwnedServer: (() async -> Void)?
    private var isShuttingDown = false

    func setDockIconVisible(_ isVisible: Bool) {
        let policy: NSApplication.ActivationPolicy = isVisible
            ? .regular
            : .accessory
        guard NSApp.activationPolicy() != policy else {
            return
        }
        NSApp.setActivationPolicy(policy)
        if isVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let shutdownOwnedServer else {
            return .terminateNow
        }
        guard !isShuttingDown else {
            return .terminateLater
        }

        isShuttingDown = true
        Task {
            await shutdownOwnedServer()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

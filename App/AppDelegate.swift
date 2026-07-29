import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdownOwnedServer: (() async -> Void)?
    private var isShuttingDown = false

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

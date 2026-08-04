import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdownOwnedServer: (() async -> Void)?
    private var singleInstanceLockDescriptor: Int32 = -1
    private var isShuttingDown = false
    private var wasMainWindowRequested = false
    private var mainWindowController: NSWindowController?

    func applicationWillFinishLaunching(
        _ notification: Notification
    ) {
        guard acquireSingleInstanceLock() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        setAccessoryActivationPolicy()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.wasMainWindowRequested else {
                return
            }
            self.hideUnrequestedWindows()
        }
    }

    func presentMainWindow<Content: View>(_ rootView: Content) {
        prepareToPresentMainWindow()

        if
            let controller = mainWindowController,
            let window = controller.window
        {
            if let hostingController =
                window.contentViewController
                    as? NSHostingController<AnyView>
            {
                hostingController.rootView = AnyView(rootView)
            }
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_080,
                height: 720
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "LlamaDock"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.contentMinSize = NSSize(width: 860, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: AnyView(rootView)
        )
        window.setFrameAutosaveName("LlamaDockMainWindow")
        window.center()

        let controller = NSWindowController(window: window)
        mainWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func prepareToPresentMainWindow() {
        wasMainWindowRequested = true
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard wasMainWindowRequested else {
            hideUnrequestedWindows()
            return false
        }
        guard !flag else {
            return true
        }
        prepareToPresentMainWindow()
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
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

    func applicationWillTerminate(
        _ notification: Notification
    ) {
        NotificationCenter.default.removeObserver(self)
        releaseSingleInstanceLock()
    }

    @objc
    private func windowDidBecomeMain(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            isAppWindow(window)
        else {
            return
        }

        guard wasMainWindowRequested else {
            window.orderOut(nil)
            setAccessoryActivationPolicy()
            return
        }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidUpdate(
        _ notification: Notification
    ) {
        guard !wasMainWindowRequested else {
            return
        }
        hideUnrequestedWindows()
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            isAppWindow(closingWindow)
        else {
            return
        }

        DispatchQueue.main.async { [weak self, weak closingWindow] in
            guard let self else {
                return
            }
            let hasVisibleWindow = NSApp.windows.contains { window in
                window !== closingWindow
                    && window.isVisible
                    && self.isAppWindow(window)
            }
            if !hasVisibleWindow {
                self.setAccessoryActivationPolicy()
            }
        }
    }

    private var mainWindow: NSWindow? {
        mainWindowController?.window
    }

    private func acquireSingleInstanceLock() -> Bool {
        let descriptor = open(
            "/tmp/io.github.boyzwj.LlamaDock.lock",
            O_CREAT | O_RDONLY | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard descriptor >= 0 else {
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        singleInstanceLockDescriptor = descriptor
        return true
    }

    private func releaseSingleInstanceLock() {
        guard singleInstanceLockDescriptor >= 0 else {
            return
        }
        flock(singleInstanceLockDescriptor, LOCK_UN)
        close(singleInstanceLockDescriptor)
        singleInstanceLockDescriptor = -1
    }

    private func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { application in
                application.processIdentifier != currentProcessIdentifier
            }
        existingInstance?.activate(
            options: [.activateAllWindows]
        )
    }

    private func hideUnrequestedWindows() {
        for window in NSApp.windows
        where window.isVisible && isAppWindow(window) {
            window.orderOut(nil)
        }
        setAccessoryActivationPolicy()
    }

    private func setAccessoryActivationPolicy() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.isExcludedFromWindowsMenu
    }
}

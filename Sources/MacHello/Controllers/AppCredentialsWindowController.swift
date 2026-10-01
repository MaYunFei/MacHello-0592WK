import AppKit
import SwiftUI
import MacHelloCore

public final class AppCredentialsWindowController: NSObject, NSWindowDelegate {
    public static let shared = AppCredentialsWindowController()

    private var window: NSWindow?

    public func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let credentialsView = AppCredentialsView(
            onDismiss: { [weak self] in
                self?.closeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: credentialsView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = loc("App-Specific Credentials (Bitwarden etc.)", "应用专属密码管理 (Bitwarden 等)")
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentViewController = hostingController
        newWindow.delegate = self

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func closeWindow() {
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

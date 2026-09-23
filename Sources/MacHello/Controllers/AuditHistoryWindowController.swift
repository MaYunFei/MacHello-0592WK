import AppKit
import SwiftUI
import MacHelloCore

public final class AuditHistoryWindowController: NSObject, NSWindowDelegate {
    public static let shared = AuditHistoryWindowController()

    private var window: NSWindow?

    public func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = AuditHistoryView(
            onDismiss: { [weak self] in
                self?.closeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: historyView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "MacHello 人脸解锁与通行抓拍历史"
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

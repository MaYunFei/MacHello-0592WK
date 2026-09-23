import AppKit
import SwiftUI

public final class GestureSettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = GestureSettingsWindowController()

    private var window: NSWindow?

    public func showWindow() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = GestureSettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.center()
        newWindow.title = "隔空手势与按键映射设置"
        newWindow.contentViewController = hostingController
        newWindow.delegate = self
        newWindow.isReleasedWhenClosed = false

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func closeWindow() {
        window?.orderOut(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // window closed
    }
}

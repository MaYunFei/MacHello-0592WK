import AppKit
import SwiftUI
import MacHelloCore

public final class DiagnosticWindowController: NSObject, NSWindowDelegate {
    public static let shared = DiagnosticWindowController()

    private var window: NSWindow?

    public func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let diagnosticView = HardwareDiagnosticView(
            onDismiss: { [weak self] in
                self?.closeWindow()
            },
            onStartEnrollment: { [weak self] in
                self?.closeWindow()
                EnrollmentWindowController.shared.showWindow()
            }
        )

        let hostingController = NSHostingController(rootView: diagnosticView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "MacHello 硬件自检与设备确认"
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
        IRController.shared.resetToRGB()
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
        IRController.shared.resetToRGB()
    }
}

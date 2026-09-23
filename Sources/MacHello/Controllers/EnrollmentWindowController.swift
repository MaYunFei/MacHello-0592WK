import AppKit
import SwiftUI
import MacHelloCore

public final class EnrollmentWindowController: NSObject, NSWindowDelegate {
    public static let shared = EnrollmentWindowController()

    private var window: NSWindow?

    public func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let enrollmentView = FaceEnrollmentView(onDismiss: { [weak self] in
            self?.closeWindow()
        })

        let hostingController = NSHostingController(rootView: enrollmentView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "MacHello 面容 ID 录入"
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentViewController = hostingController
        newWindow.delegate = self

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func closeWindow() {
        FaceEnrollmentService.shared.stopEnrollment()
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        FaceEnrollmentService.shared.stopEnrollment()
        window = nil
    }
}

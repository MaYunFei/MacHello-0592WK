import AppKit
import SwiftUI
import Carbon
import MacHelloCore

public final class HotkeyRecorderWindowController: NSObject, NSWindowDelegate {
    public static let shared = HotkeyRecorderWindowController()

    private var window: NSWindow?
    private var localMonitor: Any?

    public func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let recorderView = HotkeyRecorderView(
            onDismiss: { [weak self] in
                self?.closeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: recorderView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = loc("Configure Auto-Fill Hotkey", "设置刷脸填密快捷键")
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentViewController = hostingController
        newWindow.delegate = self

        // 监听局部按键以录制自定义快捷键
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // Esc 单独按下：退出录制窗口
            if event.keyCode == 53 && flags.isEmpty {
                self?.closeWindow()
                return nil
            }

            var carbonMods: UInt32 = 0
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

            // 只要按下了包含修饰键的有效组合
            if carbonMods != 0 {
                MacHelloService.shared.setHotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
                AudioFeedbackHelper.shared.playSuccess()
                return nil
            }

            return event
        }

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func closeWindow() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }
        window?.close()
        window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMonitor = nil
        }
        window = nil
    }
}

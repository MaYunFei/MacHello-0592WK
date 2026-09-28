import Foundation
import AppKit
import ApplicationServices

public final class AccessibilityHelper {
    public static let shared = AccessibilityHelper()

    private init() {}

    /// 检查应用是否已获得 macOS 辅助功能 (Accessibility) 信任
    public var isTrusted: Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 弹出系统辅助功能权限请求提示
    public func promptForPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统偏好设置中的「辅助功能」授权面板
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 底层模拟按键序列输出（支持宽字符与多语言，兼容 macOS 15 Sequoia 严格时戳规范）
    public func simulateKeystrokes(_ string: String, pressEnter: Bool = true) {
        let src = CGEventSource(stateID: .hidSystemState)
        let chunkSize = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex

        for offset in stride(from: 0, to: uniCharCount, by: chunkSize) {
            let len = min(chunkSize, uniCharCount - offset)
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }

            let ts1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true) {
                pressEvent.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
                pressEvent.timestamp = ts1
                pressEvent.post(tap: .cghidEventTap)
            }

            usleep(5000)
            let ts2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let releaseEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false) {
                releaseEvent.timestamp = ts2
                releaseEvent.post(tap: .cghidEventTap)
            }
            buffer.deallocate()
            usleep(20000) // 20ms
        }

        if pressEnter {
            usleep(50000) // 50ms 确保输入框内容已完全落地

            // macOS 兼容性：同时发送 Return (36 / 0x24) 和 Enter (52 / 0x34)
            for key in [36, 52] as [CGKeyCode] {
                let tsDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if let retDown = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
                    retDown.timestamp = tsDown
                    retDown.post(tap: .cghidEventTap)
                }
                usleep(15000)
                let tsUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if let retUp = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
                    retUp.timestamp = tsUp
                    retUp.post(tap: .cghidEventTap)
                }
                usleep(15000)
            }
        }
    }

    /// 模拟唤醒锁屏登录面板：
    /// 在 macOS Sonoma/Sequoia 下，严禁发送 Esc（会导致密码框缩回大时钟）。
    /// 发送 Shift 唤醒键，并执行清除旧输入操作，确保密码框聚焦且完全干净。
    public func wakeLoginPrompt() {
        let src = CGEventSource(stateID: .hidSystemState)

        // 1. 发送 Shift 键激活锁屏界面 (0x38)
        let tsShiftDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 0x38, keyDown: true) {
            shiftDown.timestamp = tsShiftDown
            shiftDown.post(tap: .cghidEventTap)
        }
        usleep(15000)
        let tsShiftUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 0x38, keyDown: false) {
            shiftUp.timestamp = tsShiftUp
            shiftUp.post(tap: .cghidEventTap)
        }

        usleep(50000)

        // 2. 发送全选 (Cmd + A) 并清空旧输入
        let tsCmdDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true) {
            cmdDown.timestamp = tsCmdDown
            cmdDown.post(tap: .cghidEventTap)
        }
        if let aDown = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true) {
            aDown.flags = .maskCommand
            aDown.timestamp = tsCmdDown
            aDown.post(tap: .cghidEventTap)
        }
        usleep(15000)
        let tsUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let aUp = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false) {
            aUp.timestamp = tsUp
            aUp.post(tap: .cghidEventTap)
        }
        if let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false) {
            cmdUp.timestamp = tsUp
            cmdUp.post(tap: .cghidEventTap)
        }

        usleep(20000)

        // 3. 发送 Delete 键 (0x33) 清除选中的可能遗留字符
        let tsDelDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let delDown = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true) {
            delDown.timestamp = tsDelDown
            delDown.post(tap: .cghidEventTap)
        }
        usleep(15000)
        let tsDelUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let delUp = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false) {
            delUp.timestamp = tsDelUp
            delUp.post(tap: .cghidEventTap)
        }
    }

    /// 激活并聚焦 SecurityAgent 密码弹窗
    /// 解决状态栏 LSUIElement 应用点击测试或后台触发时，SecurityAgent 未获前台焦点导致安全拦截与键盘事件丢失的问题
    @discardableResult
    public func focusSecurityAgentPrompt(timeout: TimeInterval = 0.6) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let secApp = runningApps.first(where: {
            $0.bundleIdentifier == "com.apple.SecurityAgent" || $0.localizedName == "SecurityAgent"
        }) else {
            return false
        }

        let appElement = AXUIElementCreateApplication(secApp.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var windowsElem: AnyObject?
            let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsElem)
            if err == .success, let windows = windowsElem as? [AXUIElement], !windows.isEmpty {
                // 1. 激活 SecurityAgent 置于最前
                if #available(macOS 14.0, *) {
                    secApp.activate()
                } else {
                    secApp.activate(options: .activateIgnoringOtherApps)
                }

                // 2. 递归查找密码输入框 AXSecureTextField，清空旧输入并置入焦点
                func findAndFocusSecureField(_ el: AXUIElement) -> Bool {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
                    if (subrole as? String) == "AXSecureTextField" {
                        _ = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, "" as CFTypeRef)
                        _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        return true
                    }
                    var children: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
                    if let childrenList = children as? [AXUIElement] {
                        for child in childrenList {
                            if findAndFocusSecureField(child) {
                                return true
                            }
                        }
                    }
                    return false
                }

                for w in windows {
                    if findAndFocusSecureField(w) {
                        return true
                    }
                }
                return true
            }
            usleep(50000) // 50ms 轮询等待窗口上屏渲染完成
        }
        return false
    }
}

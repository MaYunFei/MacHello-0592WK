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

    /// 底层模拟按键序列输出（支持宽字符与多语言，兼容 BLEUnlock/macOS 锁屏规范）
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

            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)

            let releaseEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)
            releaseEvent?.post(tap: .cghidEventTap)
            buffer.deallocate()
            usleep(15000) // 15ms
        }

        if pressEnter {
            usleep(35000) // 35ms 确保输入框内容已完全落地

            // 发送标准主键盘 Return 确认键 (Virtual Key: 36 / 0x24)
            let retDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
            retDown?.post(tap: .cghidEventTap)
            usleep(15000)
            let retUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
            retUp?.post(tap: .cghidEventTap)
        }
    }

    /// 模拟唤醒键（Esc），唤出可能隐藏的锁屏密码输入框，同时清空可能遗留的输入
    public func wakeLoginPrompt() {
        let src = CGEventSource(stateID: .hidSystemState)
        // Esc 键按下与抬起 (0x35)
        let escDown = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)
        escDown?.post(tap: .cghidEventTap)
        usleep(15000)
        let escUp = CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)
        escUp?.post(tap: .cghidEventTap)
    }
}

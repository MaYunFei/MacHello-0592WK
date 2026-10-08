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

    /// 底层模拟按键序列输出（支持宽字符与多语言，兼容 BLEUnlock 与 macOS 15 Sequoia 锁屏规范）
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
                pressEvent.flags = [] // 剥离修饰键，避免快捷键残留修饰位导致误触发系统组合键
                pressEvent.post(tap: .cghidEventTap)
            }

            usleep(5000)
            let ts2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let releaseEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false) {
                releaseEvent.timestamp = ts2
                releaseEvent.flags = []
                releaseEvent.post(tap: .cghidEventTap)
            }
            buffer.deallocate()
            usleep(20000) // 20ms 间隔
        }

        if pressEnter {
            usleep(50000) // 50ms 确保输入框内容已完全落地

            // macOS 锁屏兼容性：同时发送 Return (36 / 0x24) 和 Enter (52 / 0x34)
            for key in [36, 52] as [CGKeyCode] {
                let tsDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if let retDown = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
                    retDown.timestamp = tsDown
                    retDown.flags = []
                    retDown.post(tap: .cghidEventTap)
                }
                usleep(15000)
                let tsUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if let retUp = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
                    retUp.timestamp = tsUp
                    retUp.flags = []
                    retUp.post(tap: .cghidEventTap)
                }
                usleep(15000)
            }
        }
    }

    /// 模拟唤醒锁屏登录面板：
    /// 在 macOS Sonoma/Sequoia 下，发送 Shift 唤醒键，并执行清除旧输入操作，确保密码框聚焦且完全干净。
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

        usleep(40000)

        // 2. 清空可能残留的旧输入：连续发送 5 次 Delete (0x33)，彻底清空输入框，避免误敲入多余字符
        for _ in 0..<5 {
            let tsDelDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let delDown = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true) {
                delDown.timestamp = tsDelDown
                delDown.post(tap: .cghidEventTap)
            }
            usleep(8000)
            let tsDelUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let delUp = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false) {
                delUp.timestamp = tsDelUp
                delUp.post(tap: .cghidEventTap)
            }
            usleep(8000)
        }
    }

    // MARK: - 系统级安全认证弹窗识别与特权注入 (SecurityAgent & LocalAuthentication)

    /// 判断指定 Bundle ID 或进程名称是否属于 macOS 系统安全认证代理 (SecurityAgent 或 LocalAuthentication coreautha / RemoteService)
    public static func isSystemAuthIdentifier(bundleId: String?, processName: String?) -> Bool {
        let bid = (bundleId ?? "").lowercased()
        let name = (processName ?? "").lowercased()

        if bid == "com.apple.securityagent" || name == "securityagent" {
            return true
        }
        if bid == "com.apple.localauthentication.uiagent" || name == "coreautha" {
            return true
        }
        if bid.contains("localauthenticationremoteservice") || name.contains("localauthenticationremoteservice") {
            return true
        }
        return false
    }

    /// 判断指定应用是否为 macOS 系统安全认证代理 (SecurityAgent 或 LocalAuthentication coreautha / RemoteService)
    public static func isSystemAuthApp(_ app: NSRunningApplication) -> Bool {
        return isSystemAuthIdentifier(bundleId: app.bundleIdentifier, processName: app.localizedName)
    }

    /// 获取当前处于前台或活跃运行中的系统安全认证进程
    public func findSystemAuthApp() -> NSRunningApplication? {
        // 1. 优先检查当前处于前台的应用
        if let front = NSWorkspace.shared.frontmostApplication, Self.isSystemAuthApp(front) {
            return front
        }
        // 2. 其次从运行列表中查找活跃的系统认证服务
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.first(where: { Self.isSystemAuthApp($0) })
    }

    /// 激活并聚焦系统安全认证弹窗（SecurityAgent 或 LocalAuthentication coreautha）
    /// 解决状态栏 LSUIElement 应用点击测试或后台触发时，系统弹窗未获前台焦点导致安全拦截与键盘事件丢失的问题
    @discardableResult
    public func focusSystemAuthPrompt(timeout: TimeInterval = 0.8) -> Bool {
        guard let secApp = findSystemAuthApp() else {
            return false
        }

        let appElement = AXUIElementCreateApplication(secApp.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)

        // 递归查找密码输入框 AXSecureTextField，清空旧输入并置入焦点
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

        while Date() < deadline {
            if #available(macOS 14.0, *) {
                secApp.activate()
            } else {
                secApp.activate(options: .activateIgnoringOtherApps)
            }

            // 系统特权弹窗可能直接挂在 AXMainWindow / AXFocusedWindow 上，AXWindows 数组可能为空
            var candidates: [AXUIElement] = []
            var mainWin: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin) == .success,
               let mw = mainWin {
                candidates.append(mw as! AXUIElement)
            }
            var focusedWin: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
               let fw = focusedWin {
                candidates.append(fw as! AXUIElement)
            }
            var windowsElem: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsElem) == .success,
               let wins = windowsElem as? [AXUIElement] {
                candidates.append(contentsOf: wins)
            }

            for w in candidates {
                if findAndFocusSecureField(w) {
                    return true
                }
            }

            usleep(50000) // 50ms 轮询等待窗口上屏渲染完成
        }
        return false
    }

    /// 兼容接口：激活并聚焦 SecurityAgent 密码弹窗
    @discardableResult
    public func focusSecurityAgentPrompt(timeout: TimeInterval = 0.8) -> Bool {
        return focusSystemAuthPrompt(timeout: timeout)
    }

    /// 核心提权：直接通过 Accessibility API 向系统安全密码框（SecurityAgent 或 LocalAuthentication）写入密码并触发确认
    /// 解决 macOS 14/15/27 启用 Secure Event Input 导致底层 CGEvent 键盘模拟事件被 WindowServer 静默拦截丢弃的问题
    @discardableResult
    public func fillAndConfirmSystemAuthPrompt(password: String, autoConfirm: Bool = true, timeout: TimeInterval = 1.0) -> Bool {
        guard let secApp = findSystemAuthApp() else {
            return false
        }

        let appElement = AXUIElementCreateApplication(secApp.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if #available(macOS 14.0, *) {
                secApp.activate()
            } else {
                secApp.activate(options: .activateIgnoringOtherApps)
            }

            // 汇总所有可能的根窗口（AXMainWindow、AXFocusedWindow、AXWindows）
            var candidates: [AXUIElement] = []
            var mainWin: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin) == .success,
               let mw = mainWin {
                candidates.append(mw as! AXUIElement)
            }
            var focusedWin: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
               let fw = focusedWin {
                candidates.append(fw as! AXUIElement)
            }
            var windowsElem: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsElem) == .success,
               let wins = windowsElem as? [AXUIElement] {
                candidates.append(contentsOf: wins)
            }

            for root in candidates {
                var secureField: AXUIElement?
                var buttons: [(element: AXUIElement, isCancel: Bool, isConfirm: Bool, title: String)] = []

                func traverse(_ el: AXUIElement) {
                    var subrole: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
                    if (subrole as? String) == "AXSecureTextField" {
                        secureField = el
                    }

                    var role: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                    if (role as? String) == "AXButton" {
                        var desc: AnyObject?
                        AXUIElementCopyAttributeValue(el, "AXAttributedDescription" as CFString, &desc)
                        var title: AnyObject?
                        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)

                        let descStr: String
                        if let d = desc as? NSAttributedString {
                            descStr = d.string
                        } else if let s = desc as? String {
                            descStr = s
                        } else {
                            descStr = ""
                        }
                        let titleStr = (title as? String) ?? ""
                        let combined = "\(descStr) \(titleStr)".lowercased()

                        let isCancel = combined.contains("不允许") ||
                                       combined.contains("取消") ||
                                       combined.contains("拒绝") ||
                                       combined.contains("cancel") ||
                                       combined.contains("don") ||
                                       combined.contains("deny")

                        let isConfirm = combined.contains("好") ||
                                        combined.contains("确定") ||
                                        combined.contains("允许") ||
                                        combined.contains("继续") ||
                                        combined.contains("ok") ||
                                        combined.contains("allow") ||
                                        combined.contains("continue") ||
                                        combined.contains("modify")

                        buttons.append((el, isCancel, isConfirm, combined))
                    }

                    var children: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
                    if let childrenList = children as? [AXUIElement] {
                        for child in childrenList {
                            traverse(child)
                        }
                    }
                }

                traverse(root)

                if let sf = secureField {
                    // 1. 通过 Accessibility API 直接设置密码进 AXSecureTextField
                    let setErr = AXUIElementSetAttributeValue(sf, kAXValueAttribute as CFString, password as CFTypeRef)
                    if setErr == .success {
                        usleep(40000) // 40ms 确保文本完全生效

                        guard autoConfirm else {
                            // 安全模式：仅填入密码并确保输入框处于激活聚焦状态，留待机主确认后手动敲回车或点击确认
                            _ = AXUIElementSetAttributeValue(sf, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                            return true
                        }

                        // 极速模式：自动触发确认
                        // 2. 优先通过 AXPress 动作触发确认按钮（好/允许访问/OK/确定）
                        if let confirmBtn = buttons.first(where: { $0.isConfirm && !$0.isCancel }) ?? buttons.first(where: { !$0.isCancel }) {
                            let pErr = AXUIElementPerformAction(confirmBtn.element, kAXPressAction as CFString)
                            if pErr == .success {
                                return true
                            }
                        }

                        // 3. 兜底尝试向输入框发送 AXConfirm
                        _ = AXUIElementPerformAction(sf, "AXConfirm" as CFString)
                        usleep(20000)

                        // 4. 兜底模拟回车按键
                        simulateReturnKey()
                        return true
                    }
                }
            }

            usleep(50000) // 50ms 轮询等待
        }
        return false
    }

    /// 兼容接口：向 SecurityAgent 安全密码框写入密码并触发确认
    @discardableResult
    public func fillAndConfirmSecurityAgent(password: String, autoConfirm: Bool = true, timeout: TimeInterval = 1.0) -> Bool {
        return fillAndConfirmSystemAuthPrompt(password: password, autoConfirm: autoConfirm, timeout: timeout)
    }

    /// 发送单次标准主键盘 Return 键
    public func simulateReturnKey() {
        let src = CGEventSource(stateID: .hidSystemState)
        let returnKey: CGKeyCode = 36
        let tsDown = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let retDown = CGEvent(keyboardEventSource: src, virtualKey: returnKey, keyDown: true) {
            retDown.timestamp = tsDown
            retDown.flags = []
            retDown.post(tap: .cghidEventTap)
        }
        usleep(15000)
        let tsUp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let retUp = CGEvent(keyboardEventSource: src, virtualKey: returnKey, keyDown: false) {
            retUp.timestamp = tsUp
            retUp.flags = []
            retUp.post(tap: .cghidEventTap)
        }
    }

    /// 模拟原生 Command + V 粘贴动作
    public func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // 'V'
        let cmdKeyCode: CGKeyCode = 55 // Command

        let ts1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdKeyCode, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.timestamp = ts1
            cmdDown.post(tap: .cghidEventTap)
        }
        usleep(12000)

        let ts2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.timestamp = ts2
            vDown.post(tap: .cghidEventTap)
        }
        usleep(15000)

        let ts3 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.timestamp = ts3
            vUp.post(tap: .cghidEventTap)
        }
        usleep(12000)

        let ts4 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdKeyCode, keyDown: false) {
            cmdUp.flags = []
            cmdUp.timestamp = ts4
            cmdUp.post(tap: .cghidEventTap)
        }
    }

    /// 通过瞬时隐私剪贴板与 ⌘V 粘贴注入密码（1Password / Raycast 工业级标准实现，兼容所有普通/网页/客户端输入框）
    public func pastePassword(_ password: String, autoConfirm: Bool = false) {
        let pb = NSPasteboard.general
        let oldChangeCount = pb.changeCount

        // 备份原有剪贴板文本
        let previousString = pb.string(forType: .string)

        pb.clearContents()

        // 写入瞬时无痕密码标记（防止 Raycast/Paste/Maccy 等历史剪贴板工具记录泄露）
        let item = NSPasteboardItem()
        item.setString(password, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])

        // 稍作微小延迟确保剪贴板数据就绪
        usleep(40000)

        // 触发原生 Command + V 粘贴
        simulatePaste()

        if autoConfirm {
            usleep(50000)
            simulateReturnKey()
        }

        // 800ms 后自动擦除剪贴板中的密码残留，恢复机主此前的剪贴板内容
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            if pb.changeCount == oldChangeCount + 1 {
                pb.clearContents()
                if let prev = previousString, !prev.isEmpty {
                    pb.setString(prev, forType: .string)
                }
            }
        }
    }

    /// 自动将密码填入当前聚焦的输入框或前台安全输入框
    @discardableResult
    public func fillActivePasswordField(password: String, autoConfirm: Bool = false) -> Bool {
        // 1. 优先尝试系统级特权/安全弹窗通道（SecurityAgent 或 LocalAuthentication coreautha / RemoteService）
        if fillAndConfirmSystemAuthPrompt(password: password, autoConfirm: autoConfirm, timeout: 0.4) {
            return true
        }

        // 2. 尝试向前台当前激活窗口的 AXSecureTextField 原生写入（解决各类以 Sheet / Modal 嵌入的密码框）
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedElem: AnyObject?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedElem) == .success,
               let el = focusedElem {
                let targetEl = el as! AXUIElement
                var subrole: AnyObject?
                AXUIElementCopyAttributeValue(targetEl, kAXSubroleAttribute as CFString, &subrole)
                if (subrole as? String) == "AXSecureTextField" {
                    let setErr = AXUIElementSetAttributeValue(targetEl, kAXValueAttribute as CFString, password as CFTypeRef)
                    if setErr == .success {
                        if autoConfirm {
                            usleep(20000)
                            _ = AXUIElementPerformAction(targetEl, "AXConfirm" as CFString)
                            simulateReturnKey()
                        }
                        return true
                    }
                }
            }
        }

        // 3. 针对普通应用、网页浏览器（Safari/Chrome）、第三方桌面软件的常规输入框：
        // 采用瞬时隐私剪贴板 + ⌘V 原生注入，100% 适用于任何有光标闪烁的输入框，无需目标应用特殊权限
        pastePassword(password, autoConfirm: autoConfirm)
        return true
    }

    // MARK: - 前台活跃应用与锁定状态探查

    /// 获取当前处于最前台激活的应用 Bundle ID
    public func frontmostAppBundleIdentifier() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 获取当前处于最前台激活的应用名称
    public func frontmostAppName() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.localizedName ?? app?.bundleIdentifier
    }

    /// 检查指定前台应用当前是否处于锁定状态（或包含未完成输入的密码输入框 AXSecureTextField）
    public func isFrontmostAppLockedOrHasSecureField(bundleId: String) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier?.lowercased() == bundleId.lowercased() else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // 递归检查窗口中是否存在 AXSecureTextField
        func containsSecureField(_ el: AXUIElement, depth: Int = 0) -> Bool {
            guard depth < 6 else { return false }

            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == "AXSecureTextField" {
                return true
            }

            var role: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXTextField" {
                // 部分 Web/Electron 应用中密码框的 title / description 包含 password 或 pin
                var title: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
                var desc: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
                let text = "\((title as? String) ?? "") \((desc as? String) ?? "")".lowercased()
                if text.contains("password") || text.contains("pin") || text.contains("密码") || text.contains("unlock") {
                    return true
                }
            }

            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            if let childrenList = children as? [AXUIElement] {
                for child in childrenList {
                    if containsSecureField(child, depth: depth + 1) {
                        return true
                    }
                }
            }
            return false
        }

        var focusedWin: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
           let fw = focusedWin {
            if containsSecureField(fw as! AXUIElement) {
                return true
            }
        }

        var mainWin: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin) == .success,
           let mw = mainWin {
            if containsSecureField(mw as! AXUIElement) {
                return true
            }
        }

        return false
    }
}

import Foundation
import Combine
import AppKit
import AVFoundation
import CIOKitHelper
import ServiceManagement

public class MacHelloService: ObservableObject, DisplayPowerObserver {
    public static let shared = MacHelloService()

    @Published public var isDeviceConnected: Bool = false
    @Published public var isIRActive: Bool = false
    @Published public var isEnrolled: Bool = false
    @Published public var enrolledSamplesCount: Int = 0

    // 人体感应（走开息屏 / 来人亮屏）状态
    @Published public var isAutoDisplayEnabled: Bool = false
    @Published public var requireOwnerVerification: Bool = true
    @Published public var isSmartIdlePowerSavingEnabled: Bool = true
    @Published public var respectMediaPlayback: Bool = true
    @Published public var isMediaPreventingSleep: Bool = false
    @Published public var activeMediaAppName: String? = nil
    @Published public var absenceTimeout: TimeInterval = 15.0
    @Published public var isDisplayAsleep: Bool = false
    @Published public var isPersonPresent: Bool = false
    @Published public var isOwnerVerified: Bool = false
    @Published public var isPAMInstalled: Bool = false
    @Published public var isLaunchAtLoginEnabled: Bool = false

    // 全场景免密授权与钥匙串
    @Published public var isAppAuthEnabled: Bool = true
    @Published public var isLockScreenUnlockEnabled: Bool = true
    @Published public var isAudioFeedbackEnabled: Bool = true
    @Published public var hasStoredPassword: Bool = false
    @Published public var isAccessibilityTrusted: Bool = false
    @Published public var isPromptTestRunning: Bool = false
    @Published public var isAdminPromptAutoConfirm: Bool = false
    @Published public var isGlobalHotkeyFillEnabled: Bool = true
    @Published public var currentHotkeyDisplay: String = "⌘\\"
    @Published public var currentHotkeyKeyCode: UInt32 = GlobalHotkeyManager.defaultKeyCode
    @Published public var currentHotkeyModifiers: UInt32 = GlobalHotkeyManager.defaultModifiers

    // 局域网 Linux 服务端模式
    @Published public var isNetworkModeEnabled: Bool = false
    @Published public var linuxServerURL: String = ""
    @Published public var isLinuxConnected: Bool = false
    @Published public var isLinuxServerReachable: Bool = false
    @Published public var isLinuxHardwareConnected: Bool = false
    @Published public var linuxLatencyMs: Int = 0

    // 摄像头安装朝向 (倒置 180° 安装)
    @Published public var isCameraInverted: Bool = false

    private let irController = IRController.shared
    private let cameraService = CameraCaptureService.shared
    private let autoDisplayService = PresenceAutoDisplayService.shared
    private let displayManager = DisplayPowerManager.shared
    private let linuxClient = LinuxPresenceClient.shared

    public init() {
        displayManager.addObserver(self)
        self.isAutoDisplayEnabled = autoDisplayService.isEnabled
        self.requireOwnerVerification = autoDisplayService.requireOwnerVerification
        self.isSmartIdlePowerSavingEnabled = autoDisplayService.isSmartIdlePowerSavingEnabled
        self.respectMediaPlayback = autoDisplayService.respectMediaPlayback
        self.activeMediaAppName = MediaActivityDetector.shared.activeMediaAppName
        self.isMediaPreventingSleep = (self.activeMediaAppName != nil)
        self.absenceTimeout = autoDisplayService.absenceTimeout
        self.isDisplayAsleep = displayManager.isDisplayAsleep
        self.isAdminPromptAutoConfirm = AutoAuthManager.shared.isAdminPromptAutoConfirm
        self.isNetworkModeEnabled = autoDisplayService.isNetworkModeEnabled
        self.linuxServerURL = linuxClient.serverURLString
        self.isLinuxConnected = linuxClient.isConnected
        self.isLinuxServerReachable = linuxClient.isServerReachable
        self.isLinuxHardwareConnected = linuxClient.isHardwareConnected
        self.linuxLatencyMs = linuxClient.serverLatencyMs
        self.isDeviceConnected = self.isNetworkModeEnabled ? linuxClient.isConnected : irController.isConnected
        self.isCameraInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")
        self.cameraService.isCameraInverted = self.isCameraInverted

        // 全局快捷键刷脸填密
        self.isGlobalHotkeyFillEnabled = GlobalHotkeyManager.shared.isEnabled
        self.currentHotkeyDisplay = GlobalHotkeyManager.shared.currentDisplay
        self.currentHotkeyKeyCode = GlobalHotkeyManager.shared.currentKeyCode
        self.currentHotkeyModifiers = GlobalHotkeyManager.shared.currentModifiers
        GlobalHotkeyManager.shared.onHotKeyTriggered = { [weak self] in
            self?.triggerManualPasswordFill()
        }
        GlobalHotkeyManager.shared.start()

        // 彻底同步底层驱动的数据源状态 (Samba 模式与本机 USB 直插模式解耦)
        self.cameraService.isNetworkMode = self.isNetworkModeEnabled
        self.cameraService.networkServerURL = self.linuxServerURL
        self.irController.isNetworkMode = self.isNetworkModeEnabled
        self.irController.onNetworkSetMode = { [weak self] isIR in
            self?.linuxClient.setIRMode(isIR: isIR)
        }

        linuxClient.onStatusChanged = { [weak self] isConnected, isPresent, isOwner in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLinuxConnected = isConnected
                self.isLinuxServerReachable = self.linuxClient.isServerReachable
                self.isLinuxHardwareConnected = self.linuxClient.isHardwareConnected
                self.isDeviceConnected = self.isNetworkModeEnabled ? isConnected : self.irController.isConnected
                self.linuxLatencyMs = self.linuxClient.serverLatencyMs
                self.objectWillChange.send()
            }
        }

        autoDisplayService.onStateUpdated = { [weak self] isEnabled, isPresent, isOwner, isDisplayAsleep in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var hasChange = false
                if self.isAutoDisplayEnabled != isEnabled { self.isAutoDisplayEnabled = isEnabled; hasChange = true }
                if self.isPersonPresent != isPresent { self.isPersonPresent = isPresent; hasChange = true }
                if self.isOwnerVerified != isOwner { self.isOwnerVerified = isOwner; hasChange = true }
                if self.isDisplayAsleep != isDisplayAsleep { self.isDisplayAsleep = isDisplayAsleep; hasChange = true }
                if hasChange {
                    self.objectWillChange.send()
                }
            }
        }

        // 启动时自动检查并清理已被卸载应用的孤儿凭据 (被动卸载自动清理)
        _ = AppCredentialManager.shared.cleanOrphanedAppCredentials()

        // 监听系统级摄像头设备热插拔（即插即用）
        NotificationCenter.default.addObserver(
            forName: LanguageManager.languageDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCameraDeviceChange),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCameraDeviceChange),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )

        // 定期（每 1 秒）自动检测硬件热插拔、系统辅助功能与钥匙串状态，即插即用无感更新
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // 1. 摄像头热插拔心跳检测
            let connected = self.irController.isConnected
            if self.isDeviceConnected != connected {
                DispatchQueue.main.async {
                    self.isDeviceConnected = connected
                    if connected {
                        print("[MacHello] 📷 检测到摄像头热插入，自动激活硬件！")
                        self.irController.resetToRGB()
                    } else {
                        print("[MacHello] ⚠️ 摄像头已拔出")
                    }
                    self.objectWillChange.send()
                }
            }

            // 2. 辅助功能授权实时刷新
            let trusted = AccessibilityHelper.shared.isTrusted
            if self.isAccessibilityTrusted != trusted {
                DispatchQueue.main.async {
                    self.isAccessibilityTrusted = trusted
                }
            }

            // 3. 钥匙串密码状态实时刷新
            let hasPw = KeychainHelper.shared.hasPassword()
            if self.hasStoredPassword != hasPw {
                DispatchQueue.main.async {
                    self.hasStoredPassword = hasPw
                }
            }

            // 4. 视频观影/在线会议免打扰媒体状态实时刷新
            let mediaApp = MediaActivityDetector.shared.activeMediaAppName
            let isMediaPreventing = (mediaApp != nil)
            if self.isMediaPreventingSleep != isMediaPreventing || self.activeMediaAppName != mediaApp {
                DispatchQueue.main.async {
                    self.isMediaPreventingSleep = isMediaPreventing
                    self.activeMediaAppName = mediaApp
                    self.objectWillChange.send()
                }
            }
        }

        refreshStatus()
    }

    @objc private func handleCameraDeviceChange(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            let connected = self.irController.isConnected
            if self.isDeviceConnected != connected {
                self.isDeviceConnected = connected
                if connected {
                    print("[MacHello] 📷 收到系统摄像头热插拔通知：Dell 0592WK 已连接！")
                    self.irController.resetToRGB()
                } else {
                    print("[MacHello] ⚠️ 收到系统摄像头热插拔通知：设备已拔出")
                }
                self.objectWillChange.send()
            }
        }
    }

    public func refreshStatus() {
        self.isNetworkModeEnabled = autoDisplayService.isNetworkModeEnabled
        self.linuxServerURL = linuxClient.serverURLString
        if self.isNetworkModeEnabled {
            linuxClient.measureLatency()
            self.isLinuxConnected = linuxClient.isConnected
            self.isLinuxServerReachable = linuxClient.isServerReachable
            self.isLinuxHardwareConnected = linuxClient.isHardwareConnected
            self.isDeviceConnected = linuxClient.isConnected
        } else {
            self.isDeviceConnected = irController.isConnected
        }
        self.isIRActive = (irController.currentMode == .ir)
        let profile = FaceDatabase.shared.load()
        self.isEnrolled = !(profile?.samples.isEmpty ?? true)
        self.enrolledSamplesCount = profile?.samples.count ?? 0
        self.isPAMInstalled = PAMManager.shared.isInstalled
        self.isLaunchAtLoginEnabled = checkLaunchAtLoginStatus()
        self.isAutoDisplayEnabled = autoDisplayService.isEnabled
        self.requireOwnerVerification = autoDisplayService.requireOwnerVerification
        self.isSmartIdlePowerSavingEnabled = autoDisplayService.isSmartIdlePowerSavingEnabled
        self.respectMediaPlayback = autoDisplayService.respectMediaPlayback
        self.activeMediaAppName = MediaActivityDetector.shared.activeMediaAppName
        self.isMediaPreventingSleep = (self.activeMediaAppName != nil)
        self.absenceTimeout = autoDisplayService.absenceTimeout
        self.linuxLatencyMs = linuxClient.serverLatencyMs
        self.isCameraInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")

        self.isAppAuthEnabled = AutoAuthManager.shared.isAppAuthEnabled
        self.isLockScreenUnlockEnabled = AutoAuthManager.shared.isLockScreenUnlockEnabled
        self.isAudioFeedbackEnabled = AutoAuthManager.shared.isAudioFeedbackEnabled
        self.hasStoredPassword = KeychainHelper.shared.hasPassword()
        self.isAccessibilityTrusted = AccessibilityHelper.shared.isTrusted
    }

    public func toggleNetworkMode() {
        let newState = !isNetworkModeEnabled
        autoDisplayService.isNetworkModeEnabled = newState
        self.isNetworkModeEnabled = newState
        self.cameraService.isNetworkMode = newState
        self.irController.isNetworkMode = newState
        if newState {
            linuxClient.start()
        } else {
            linuxClient.stop()
        }
    }

    public func toggleCameraInverted() {
        let newVal = !isCameraInverted
        self.isCameraInverted = newVal
        self.cameraService.isCameraInverted = newVal
        UserDefaults.standard.set(newVal, forKey: "com.machello.isCameraInverted")
        self.objectWillChange.send()
    }

    public func setLinuxServerURL(_ url: String) {
        linuxClient.setServerURL(url)
        self.linuxServerURL = linuxClient.serverURLString
        self.cameraService.networkServerURL = linuxClient.serverURLString
    }

    public func promptForLinuxServerURL() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = loc("Configure Linux Gateway Service", "配置局域网 Linux 感应服务")
            alert.informativeText = loc(
                "Enter the address of your MacHello Linux gateway (e.g., http://192.168.66.5:8765):",
                "请输入局域网中运行 MacHello Linux 服务的地址（例如 http://192.168.66.5:8765）："
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: loc("Save & Connect", "保存并连接"))
            alert.addButton(withTitle: loc("Cancel", "取消"))

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.stringValue = self.linuxServerURL
            alert.accessoryView = input

            if alert.runModal() == .alertFirstButtonReturn {
                let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    self.setLinuxServerURL(url)
                }
            }
        }
    }

    public func toggleAutoDisplay() {
        let newState = !isAutoDisplayEnabled
        autoDisplayService.isEnabled = newState
        self.isAutoDisplayEnabled = newState
    }

    public func toggleSmartIdlePowerSaving() {
        let newState = !isSmartIdlePowerSavingEnabled
        autoDisplayService.isSmartIdlePowerSavingEnabled = newState
        self.isSmartIdlePowerSavingEnabled = newState
    }

    public func toggleRespectMediaPlayback() {
        let newState = !respectMediaPlayback
        autoDisplayService.respectMediaPlayback = newState
        self.respectMediaPlayback = newState
        self.objectWillChange.send()
    }

    /// 视频观影/在线会议免打扰菜单项文案（实时指示小绿点及来源 App）
    public var mediaPlaybackMenuTitle: String {
        let currentApp = MediaActivityDetector.shared.activeMediaAppName
        let isPreventing = (currentApp != nil)

        if !respectMediaPlayback {
            return "   " + loc("Media / Meeting Do-Not-Disturb (Disabled)", "视频观影/在线会议免打扰 (已关闭)")
        }

        if isPreventing {
            if let name = currentApp, !name.isEmpty {
                return "✓ " + loc("Media / Meeting DND 🟢 Active (\(name))", "视频观影/在线会议免打扰 🟢 运行中 (\(name))")
            } else {
                return "✓ " + loc("Media / Meeting DND 🟢 Active", "视频观影/在线会议免打扰 🟢 运行中")
            }
        } else {
            return "✓ " + loc("Media / Meeting DND (⚪ Standby)", "视频观影/在线会议免打扰 (⚪ 待命中)")
        }
    }

    public func toggleRequireOwnerVerification() {
        let newState = !requireOwnerVerification
        autoDisplayService.requireOwnerVerification = newState
        self.requireOwnerVerification = newState
    }

    public func togglePAMInstallation() {
        if isPAMInstalled {
            PAMManager.shared.runUninstallInTerminal { [weak self] in
                DispatchQueue.main.async {
                    self?.isPAMInstalled = PAMManager.shared.isInstalled
                    self?.objectWillChange.send()
                }
            }
        } else {
            PAMManager.shared.runInstallInTerminal { [weak self] in
                DispatchQueue.main.async {
                    self?.isPAMInstalled = PAMManager.shared.isInstalled
                    self?.objectWillChange.send()
                }
            }
        }
    }

    private func showSimpleAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: loc("OK", "好的"))
            alert.runModal()
        }
    }

    private func checkLaunchAtLoginStatus() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    public func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    self.isLaunchAtLoginEnabled = false
                } else {
                    try SMAppService.mainApp.register()
                    self.isLaunchAtLoginEnabled = true
                }
            } catch {
                print("Failed to toggle launch at login:", error)
            }
        }
    }

    public func setAbsenceTimeout(_ seconds: TimeInterval) {
        autoDisplayService.absenceTimeout = seconds
        self.absenceTimeout = seconds
    }

    public func toggleIRTest() {
        if isNetworkModeEnabled && isLinuxConnected {
            linuxClient.toggleIR { [weak self] irActive in
                self?.isIRActive = irActive
                self?.objectWillChange.send()
            }
            return
        }
        guard isDeviceConnected else { return }
        let success = irController.toggle()
        if success {
            self.isIRActive = (irController.currentMode == .ir)
        }
    }

    public func clearFaceData() {
        FaceDatabase.shared.clear()
        refreshStatus()
    }

    // MARK: - 全场景免密与钥匙串控制

    public func toggleAppAuth() {
        let newState = !isAppAuthEnabled
        AutoAuthManager.shared.isAppAuthEnabled = newState
        self.isAppAuthEnabled = newState
    }

    public func toggleLockScreenUnlock() {
        let newState = !isLockScreenUnlockEnabled
        AutoAuthManager.shared.isLockScreenUnlockEnabled = newState
        self.isLockScreenUnlockEnabled = newState
    }

    public func toggleAudioFeedback() {
        let newState = !isAudioFeedbackEnabled
        AutoAuthManager.shared.isAudioFeedbackEnabled = newState
        self.isAudioFeedbackEnabled = newState
    }

    public func toggleAdminPromptAutoConfirm() {
        let newState = !isAdminPromptAutoConfirm
        AutoAuthManager.shared.isAdminPromptAutoConfirm = newState
        self.isAdminPromptAutoConfirm = newState
    }

    public func toggleGlobalHotkeyFill() {
        let newState = !isGlobalHotkeyFillEnabled
        GlobalHotkeyManager.shared.isEnabled = newState
        self.isGlobalHotkeyFillEnabled = newState
    }

    public func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        GlobalHotkeyManager.shared.setHotkey(keyCode: keyCode, modifiers: modifiers)
        self.currentHotkeyDisplay = GlobalHotkeyManager.shared.currentDisplay
        self.currentHotkeyKeyCode = keyCode
        self.currentHotkeyModifiers = modifiers
    }

    public func resetHotkeyToDefault() {
        GlobalHotkeyManager.shared.resetToDefault()
        self.currentHotkeyDisplay = GlobalHotkeyManager.shared.currentDisplay
        self.currentHotkeyKeyCode = GlobalHotkeyManager.shared.currentKeyCode
        self.currentHotkeyModifiers = GlobalHotkeyManager.shared.currentModifiers
    }

    /// 全局快捷键触发 Face ID 刷脸并自动填入当前密码框
    public func triggerManualPasswordFill() {
        guard isDeviceConnected || isNetworkModeEnabled else {
            SystemNotifier.shared.postNotification(
                title: "MacHello",
                body: "摄像头未连接或网络服务离线，无法进行人脸核验",
                force: true
            )
            return
        }

        guard FaceDatabase.shared.isEnrolled else {
            SystemNotifier.shared.postNotification(
                title: "MacHello",
                body: "尚未录入机主面容，请先在菜单中设置面容 ID",
                force: true
            )
            return
        }

        guard hasStoredPassword else {
            SystemNotifier.shared.postNotification(
                title: "MacHello",
                body: "钥匙串未保存密码，请先在菜单中设置解锁密码",
                force: true
            )
            return
        }

        guard isAccessibilityTrusted else {
            SystemNotifier.shared.postNotification(
                title: "MacHello",
                body: "缺少辅助功能权限，无法模拟填密，请前往系统设置授权",
                force: true
            )
            return
        }

        AutoAuthManager.shared.triggerFaceAuthForPrompt(reason: .manualFill)
    }

    /// 单独试听 Face ID 认证成功提示音
    public func playTestAudio() {
        AudioFeedbackHelper.shared.playSuccess()
    }

    public func promptToStorePassword() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = loc("Set System Unlock Password", "设置系统免密解锁密码")
            alert.informativeText = loc(
                "Your password is encrypted and securely saved in the native macOS Keychain. It is simulated via accessibility ONLY when your face matches the 850nm IR biometrics.",
                "该密码将被加密保存在 macOS 原生安全钥匙串 (Keychain) 中。仅在 850nm 红外相机精准比对机主本人面容成功后，才会由底层辅助功能模拟输入解锁。"
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: loc("Save Password", "保存密码"))
            alert.addButton(withTitle: loc("Cancel", "取消"))

            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.placeholderString = loc("Enter current account login / admin password", "请输入当前账户的登录/管理员密码")
            alert.accessoryView = input

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let pw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pw.isEmpty {
                    KeychainHelper.shared.savePassword(pw)
                    self.refreshStatus()

                    // 保存后立即进行一次前台主动验证，引导系统立即弹出钥匙串授权框，防止后续后台静默拦截
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.verifyKeychainAccess()
                    }
                }
            }
        }
    }

    /// 主动在前台验证并授权 macOS 系统钥匙串读取权限
    public func verifyKeychainAccess() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let result = KeychainHelper.shared.verifyKeychainAccess()
            let alert = NSAlert()
            if result.success {
                alert.messageText = loc("Keychain Access Authorized ✓", "钥匙串访问授权有效 ✓")
                alert.informativeText = loc(
                    "MacHello has successfully read and decrypted the stored password (\(result.passwordLength) characters) from the system Keychain.\n\nFace ID auto-fill is ready to use!",
                    "MacHello 已成功从系统安全钥匙串中读取并解密机主密码 (长度: \(result.passwordLength) 位)。\n\n现在您可以随时使用全局快捷键在任意光标输入框中自动填入密码！"
                )
                alert.alertStyle = .informational
            } else {
                alert.messageText = loc("Keychain Authorization Needed", "需要钥匙串访问授权")
                alert.informativeText = loc(
                    "Failed to read password from Keychain:\n\(result.message)\n\nIf macOS prompts with a keychain dialog, please enter your Mac password and click 'Always Allow'.",
                    "未能读取钥匙串密码：\n\(result.message)\n\n如果屏幕上出现了系统钥匙串授权对话框，请输入当前 Mac 登录密码并务必点击「总是允许」。"
                )
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: loc("OK", "好"))
            alert.runModal()
            self.refreshStatus()
        }
    }

    public func deleteStoredPassword() {
        KeychainHelper.shared.deletePassword()
        refreshStatus()
    }

    /// 请求执行彻底卸载与数据抹除流程 (方案 A: 应用内一键抹除)
    public func requestCompleteUninstall() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = loc("Uninstall MacHello & Erase All Data?", "彻底卸载 MacHello 并抹除所有数据？")
            alert.informativeText = loc(
                "Warning: This operation will permanently erase:\n" +
                "1. All face biometric vectors (~/.machello/faces.json)\n" +
                "2. All capture & diagnostic snapshots (~/.machello/history/)\n" +
                "3. Mac login password & third-party app credentials in Keychain\n" +
                "4. Terminal Sudo PAM elevation configuration\n" +
                "5. Login item auto-start & application preferences\n\n" +
                "This action cannot be undone. Are you sure you want to proceed?",
                "⚠️ 警告：此操作将永久彻底抹除以下所有数据与系统配置：\n" +
                "1. 机主人脸生物特征向量库 (~/.machello/faces.json)\n" +
                "2. 通行抓拍历史照片与硬件诊断缓存 (~/.machello/history/)\n" +
                "3. 系统钥匙串中的 Mac 登录密码及所有第三方应用专属凭据 (Bitwarden 等)\n" +
                "4. 终端 Sudo PAM 免密提权系统配置\n" +
                "5. 开机登录自启动项与所有偏好设置\n\n" +
                "此操作不可逆，抹除后将在访达中为您定位 MacHello.app 以便移入废纸篓。是否确认彻底抹除？"
            )
            alert.alertStyle = .critical
            alert.addButton(withTitle: loc("Erase All Data & Uninstall", "彻底抹除并准备卸载"))
            alert.addButton(withTitle: loc("Cancel", "取消"))

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                UninstallManager.shared.executeCompleteWipeAndPrepareUninstall { _ in
                    let finishedAlert = NSAlert()
                    finishedAlert.messageText = loc("Data Safely Erased", "所有数据已彻底安全抹除 ✓")
                    finishedAlert.informativeText = loc(
                        "All biometric models, keychain credentials, and configurations have been permanently wiped.\n\nMacHello.app has been revealed in Finder. You can now drag it to Trash to finish uninstallation.",
                        "所有面容数据、钥匙串密码与系统配置均已彻底物理抹除。\n\nMacHello.app 已在访达中高亮选中，现在您可以将其直接拖入废纸篓完成卸载。"
                    )
                    finishedAlert.alertStyle = .informational
                    finishedAlert.addButton(withTitle: loc("Quit Application", "退出程序"))
                    finishedAlert.runModal()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    public func openAccessibilitySettings() {
        AccessibilityHelper.shared.openAccessibilitySettings()
    }

    public func triggerAdminPromptTest() {
        guard !isPromptTestRunning else { return }

        // 1. 严格检查各前置条件并给出针对性的明确提示与引导
        guard isAppAuthEnabled else {
            showSimpleAlert(
                title: loc("Admin Auto-Auth Disabled", "管理员自动认证未开启"),
                message: loc("Please turn on 'Admin Prompt Face ID Auto-Auth' in the menu first.", "请先在菜单中开启「应用管理员弹窗 Face ID 自动认证」开关。")
            )
            return
        }

        guard isDeviceConnected || isNetworkModeEnabled else {
            showSimpleAlert(
                title: loc("Camera Disconnected", "摄像头未连接"),
                message: loc("Infrared camera hardware is disconnected or offline. Please check connection.", "红外摄像头硬件未连接或处于离线状态，请检查设备连接后再试。")
            )
            return
        }

        guard FaceDatabase.shared.isEnrolled else {
            showSimpleAlert(
                title: loc("Face ID Not Set Up", "尚未设置面容 ID"),
                message: loc("Please enroll your face in 'Set Up Face ID' before running this test.", "尚未录入面容数据，请先点击菜单中的「设置面容 ID」完成录入。")
            )
            return
        }

        guard hasStoredPassword else {
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = loc("Password Not Set in Keychain", "尚未保存解锁密码")
                alert.informativeText = loc("Face ID elevation requires your account password stored securely in Keychain. Would you like to set it now?", "Face ID 自动提权需要在钥匙串中安全保存当前账户的登录/管理员密码。是否立即设置？")
                alert.alertStyle = .informational
                alert.addButton(withTitle: loc("Set Password Now", "立即设置密码"))
                alert.addButton(withTitle: loc("Cancel", "取消"))
                if alert.runModal() == .alertFirstButtonReturn {
                    self?.promptToStorePassword()
                }
            }
            return
        }

        guard isAccessibilityTrusted else {
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = loc("Accessibility Permission Required", "需要辅助功能权限")
                alert.informativeText = loc("MacHello requires Accessibility permission to automatically focus and type your password. Click OK to open System Settings.", "MacHello 需要辅助功能权限以自动定位并键入密码。点击「打开系统设置」前往授权。")
                alert.alertStyle = .warning
                alert.addButton(withTitle: loc("Open System Settings", "打开系统设置"))
                alert.addButton(withTitle: loc("Cancel", "取消"))
                if alert.runModal() == .alertFirstButtonReturn {
                    self?.openAccessibilitySettings()
                }
            }
            return
        }

        // 2. 所有前置条件满足，标记运行状态并异步启动测试
        isPromptTestRunning = true

        // 双保险：在弹窗唤起后主动通知 AutoAuthManager 准备核验，避免部分 macOS 系统省略激活通知
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            AutoAuthManager.shared.triggerFaceAuthForPrompt(reason: .adminPrompt)
        }

        DispatchQueue.global().async {
            defer {
                DispatchQueue.main.async {
                    self.isPromptTestRunning = false
                }
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"echo 恭喜！MacHello Face ID 自动认证成功\" with administrator privileges"]
            let pipe = Pipe()
            p.standardOutput = pipe

            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !out.isEmpty {
                        SystemNotifier.shared.postNotification(
                            title: "MacHello Face ID",
                            subtitle: loc("Admin Elevation Succeeded", "管理员提权认证成功"),
                            body: out
                        )
                    }
                }
            } catch {
                print("[MacHello] 启动管理员提权测试进程失败: \(error)")
            }
        }
    }

    public func displayPowerStateDidChange(isDisplayAsleep: Bool) {
        DispatchQueue.main.async {
            if self.isDisplayAsleep != isDisplayAsleep {
                self.isDisplayAsleep = isDisplayAsleep
            }
        }
    }
}

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
        self.isNetworkModeEnabled = autoDisplayService.isNetworkModeEnabled
        self.linuxServerURL = linuxClient.serverURLString
        self.isLinuxConnected = linuxClient.isConnected
        self.isLinuxServerReachable = linuxClient.isServerReachable
        self.isLinuxHardwareConnected = linuxClient.isHardwareConnected
        self.linuxLatencyMs = linuxClient.serverLatencyMs
        self.isDeviceConnected = self.isNetworkModeEnabled ? linuxClient.isConnected : irController.isConnected
        self.isCameraInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")
        self.cameraService.isCameraInverted = self.isCameraInverted

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

        // 监听系统级摄像头设备热插拔（即插即用）
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
            alert.messageText = "配置局域网 Linux 感应服务"
            alert.informativeText = "请输入局域网中运行 MacHello Linux 服务的地址（例如 http://192.168.66.5:8765）："
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存并连接")
            alert.addButton(withTitle: "取消")

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
            return "   视频观影/在线会议免打扰 (已关闭)"
        }

        if isPreventing {
            if let name = currentApp, !name.isEmpty {
                return "✓ 视频观影/在线会议免打扰 🟢 运行中 (\(name))"
            } else {
                return "✓ 视频观影/在线会议免打扰 🟢 运行中"
            }
        } else {
            return "✓ 视频观影/在线会议免打扰 (⚪ 待命中)"
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
            alert.addButton(withTitle: "好的")
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

    /// 单独试听 Face ID 认证成功提示音
    public func playTestAudio() {
        AudioFeedbackHelper.shared.playSuccess()
    }

    public func promptToStorePassword() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "设置系统免密解锁密码"
            alert.informativeText = "该密码将被加密保存在 macOS 原生安全钥匙串 (Keychain) 中。仅在 850nm 红外相机精准比对机主本人面容成功后，才会由底层辅助功能模拟输入解锁。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "保存密码")
            alert.addButton(withTitle: "取消")

            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            input.placeholderString = "请输入当前账户的登录/管理员密码"
            alert.accessoryView = input

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let pw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pw.isEmpty {
                    KeychainHelper.shared.savePassword(pw)
                    self.refreshStatus()
                }
            }
        }
    }

    public func deleteStoredPassword() {
        KeychainHelper.shared.deletePassword()
        refreshStatus()
    }

    public func openAccessibilitySettings() {
        AccessibilityHelper.shared.openAccessibilitySettings()
    }

    public func triggerAdminPromptTest() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"echo 恭喜！MacHello Face ID 自动认证成功\" with administrator privileges"]
            try? p.run()
            p.waitUntilExit()
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

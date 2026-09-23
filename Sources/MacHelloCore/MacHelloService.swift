import Foundation
import Combine
import AppKit
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

    private let irController = IRController.shared
    private let cameraService = CameraCaptureService.shared
    private let autoDisplayService = PresenceAutoDisplayService.shared
    private let displayManager = DisplayPowerManager.shared

    public init() {
        displayManager.addObserver(self)
        self.isAutoDisplayEnabled = autoDisplayService.isEnabled
        self.requireOwnerVerification = autoDisplayService.requireOwnerVerification
        self.isSmartIdlePowerSavingEnabled = autoDisplayService.isSmartIdlePowerSavingEnabled
        self.respectMediaPlayback = autoDisplayService.respectMediaPlayback
        self.absenceTimeout = autoDisplayService.absenceTimeout
        self.isDisplayAsleep = displayManager.isDisplayAsleep

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

        // 定期（每 1 秒）自动检测系统辅助功能与钥匙串状态，用户一旦在系统设置中勾选立刻无感秒变绿勾
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = AccessibilityHelper.shared.isTrusted
            if self.isAccessibilityTrusted != trusted {
                DispatchQueue.main.async {
                    self.isAccessibilityTrusted = trusted
                }
            }
            let hasPw = KeychainHelper.shared.hasPassword()
            if self.hasStoredPassword != hasPw {
                DispatchQueue.main.async {
                    self.hasStoredPassword = hasPw
                }
            }
        }

        refreshStatus()
    }

    public func refreshStatus() {
        self.isDeviceConnected = irController.isConnected
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
        self.absenceTimeout = autoDisplayService.absenceTimeout

        self.isAppAuthEnabled = AutoAuthManager.shared.isAppAuthEnabled
        self.isLockScreenUnlockEnabled = AutoAuthManager.shared.isLockScreenUnlockEnabled
        self.isAudioFeedbackEnabled = AutoAuthManager.shared.isAudioFeedbackEnabled
        self.hasStoredPassword = KeychainHelper.shared.hasPassword()
        self.isAccessibilityTrusted = AccessibilityHelper.shared.isTrusted
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

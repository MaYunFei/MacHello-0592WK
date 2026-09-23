import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CIOKitHelper

public enum AuthReason {
    case adminPrompt
    case lockScreen
}

public final class AutoAuthManager: NSObject, CameraCaptureDelegate {
    public static let shared = AutoAuthManager()

    private let defaultsKeyAppAuth = "com.machello.isAppAuthEnabled"
    private let defaultsKeyLockScreenUnlock = "com.machello.isLockScreenUnlockEnabled"
    private let defaultsKeyAudioFeedback = "com.machello.isAudioFeedbackEnabled"

    public var isAppAuthEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyAppAuth) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyAppAuth)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyAppAuth)
        }
    }

    public var isLockScreenUnlockEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyLockScreenUnlock) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyLockScreenUnlock)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyLockScreenUnlock)
        }
    }

    public var isAudioFeedbackEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyAudioFeedback) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyAudioFeedback)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyAudioFeedback)
        }
    }

    private let keychain = KeychainHelper.shared
    private let accessibility = AccessibilityHelper.shared
    private let audio = AudioFeedbackHelper.shared
    private let cameraService = CameraCaptureService.shared
    private let irController = IRController.shared
    private let faceDb = FaceDatabase.shared
    private let extractor = FaceFeatureExtractor.shared

    private let authQueue = DispatchQueue(label: "com.machello.autoauth.queue")
    private var isAuthenticating = false
    private var currentReason: AuthReason = .adminPrompt
    private var authFrameCount = 0
    private var lastAuthSuccessTime: Date = .distantPast

    private override init() {
        super.init()
        setupObservers()
    }

    // MARK: - 监听 SecurityAgent 管理员提权弹窗与系统锁屏事件

    private func setupObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // 监听系统锁屏事件 (Cmd + Ctrl + Q 或屏幕超时锁定)
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        checkAndTriggerSecurityAgent(from: notification)
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        checkAndTriggerSecurityAgent(from: notification)
    }

    @objc private func handleScreenLocked() {
        guard isLockScreenUnlockEnabled else { return }
        guard keychain.hasPassword() else { return }

        // 防抖：2秒内不重复触发
        let now = Date()
        guard now.timeIntervalSince(lastAuthSuccessTime) > 2.0 else { return }

        print("[AutoAuth] 检测到系统进入锁屏状态，准备触发 Face ID 解锁...")
        // 等待锁屏 UI 动画渲染就绪 (约 250ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.triggerFaceAuthForPrompt(reason: .lockScreen)
        }
    }

    private func checkAndTriggerSecurityAgent(from notification: Notification) {
        guard isAppAuthEnabled else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        let bid = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        if bid == "com.apple.SecurityAgent" || name == "SecurityAgent" {
            // 防抖：2秒内不重复触发
            let now = Date()
            guard now.timeIntervalSince(lastAuthSuccessTime) > 2.0 else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.triggerFaceAuthForPrompt(reason: .adminPrompt)
            }
        }
    }

    /// 触发 Face ID 红外刷脸与自动填入 (支持管理员弹窗与锁屏解锁)
    public func triggerFaceAuthForPrompt(reason: AuthReason = .adminPrompt) {
        authQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isAuthenticating else { return }
            guard self.keychain.hasPassword() else {
                print("[AutoAuth] 钥匙串中未保存密码，跳过自动填入")
                return
            }
            guard self.faceDb.isEnrolled else {
                print("[AutoAuth] 尚未录入面容，跳过自动填入")
                return
            }

            self.isAuthenticating = true
            self.currentReason = reason
            self.authFrameCount = 0
            print("[AutoAuth] 触发 Face ID (\(reason == .lockScreen ? "锁屏解锁" : "管理员弹窗"))，启动 850nm 红外夜视人脸核验...")

            // 1. 点亮 850nm 红外并启动 640x480 YUY2 红外流
            _ = self.irController.setMode(.ir)
            self.cameraService.delegate = self
            do {
                try self.cameraService.start(mode: .ir)
            } catch {
                print("[AutoAuth] 启动红外相机失败: \(error)")
                self.irController.resetToRGB()
                self.isAuthenticating = false
                return
            }

            // 2. 设置 3.5 秒安全硬超时
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self = self else { return }
                self.authQueue.async {
                    if self.isAuthenticating {
                        print("[AutoAuth] 红外核验超时未比对成功，自动复位")
                        self.stopAuth()
                    }
                }
            }
        }
    }

    /// 针对锁屏唤醒自动解锁桌面
    public func unlockScreenIfNeeded() {
        guard isLockScreenUnlockEnabled else { return }
        guard keychain.hasPassword() else { return }
        guard isScreenLocked() else { return }

        // 避免 2 秒内重复执行
        let now = Date()
        guard now.timeIntervalSince(lastAuthSuccessTime) > 2.0 else { return }
        lastAuthSuccessTime = now

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard self.isScreenLocked() else { return }
            guard let password = self.keychain.fetchPassword() else { return }

            print("[AutoAuth] 机主已核验，正在模拟唤醒并输入密码自动解锁进桌面...")
            self.accessibility.wakeLoginPrompt()
            usleep(150000) // 150ms 等待输入框完全获得焦点与动画就绪
            self.accessibility.simulateKeystrokes(password, pressEnter: true)
            if self.isAudioFeedbackEnabled {
                self.audio.playSuccess()
            }
        }
    }

    /// 检查当前 macOS 屏幕是否正处于锁定状态
    public func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
                return locked
            }
            if let lockedInt = dict["CGSSessionScreenIsLocked"] as? Int {
                return lockedInt == 1
            }
        }
        return false
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isAuthenticating else { return }

        authFrameCount += 1
        // 避开最初 3 帧让夜视自动曝光增益 (AGC) 稍作稳定即可立即比对
        if isIR && authFrameCount < 4 {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let faces = extractor.extract(from: pixelBuffer)
        for face in faces {
            let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
            if match.matched {
                print("[AutoAuth] ✓ 机主红外人脸核验成功 (相似度: \(String(format: "%.2f", match.highestScore)))")
                onAuthSucceeded()
                return
            }
        }
    }

    private func onAuthSucceeded() {
        let reason = currentReason
        isAuthenticating = false
        lastAuthSuccessTime = Date()

        // 停止相机并安全复位硬件
        stopAuth()

        // 播放提示音
        if isAudioFeedbackEnabled {
            audio.playSuccess()
        }

        // 从钥匙串读取解密密码并模拟输入
        guard let password = keychain.fetchPassword() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            if reason == .lockScreen {
                print("[AutoAuth] ✓ 锁屏机主核验成功，模拟唤醒并键入密码解锁进桌面...")
                self.accessibility.wakeLoginPrompt()
                usleep(300000) // 300ms 等待锁屏 Esc 响应并聚焦密码输入框
                self.accessibility.simulateKeystrokes(password, pressEnter: true)
            } else {
                print("[AutoAuth] ✓ 管理员弹窗机主核验成功，自动键入密码提权...")
                self.accessibility.simulateKeystrokes(password, pressEnter: true)
            }
        }
    }

    private func stopAuth() {
        isAuthenticating = false
        cameraService.stop()
        irController.resetToRGB()
    }
}

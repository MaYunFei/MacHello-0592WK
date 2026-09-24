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

    /// 诊断测试独占标记
    public var isDiagnosticRunning: Bool = false {
        didSet {
            if isDiagnosticRunning {
                stopAuth()
            }
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

        center.addObserver(
            self,
            selector: #selector(handleScreensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
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

    @objc private func handleScreensDidWake() {
        guard isLockScreenUnlockEnabled else { return }
        guard keychain.hasPassword() else { return }
        guard isScreenLocked() else { return }

        let now = Date()
        guard now.timeIntervalSince(lastAuthSuccessTime) > 2.0 else { return }

        print("[AutoAuth] 屏幕唤醒且处于锁定状态，触发 Face ID 自动解锁...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.triggerFaceAuthForPrompt(reason: .lockScreen)
        }
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

        print("[AutoAuth] 检测到系统进入锁屏状态，等待系统锁屏动效落地 (1.2s)...")
        // 关键：macOS 锁屏切换动画耗时约 800ms~1000ms，期间 loginwindow 不接收按键事件
        // 等待 1.2 秒动效彻底落定后，再开启红外核验，避免按键事件丢失！
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            if self.isScreenLocked() {
                self.triggerFaceAuthForPrompt(reason: .lockScreen)
            }
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
            guard self.irController.isConnected else {
                print("[AutoAuth] 摄像头已拔出或未连接，跳过自动核验")
                return
            }
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
            guard self.isScreenLocked() else {
                print("[AutoAuth] ⚠️ 屏幕已解锁或未处于锁定界面，严禁键入密码！")
                return
            }
            guard let password = self.keychain.fetchPassword() else { return }

            print("[AutoAuth] 机主已核验，正在模拟唤醒并输入密码自动解锁进桌面...")
            self.accessibility.wakeLoginPrompt()
            usleep(250000)

            // 发送按键前进行最后的原子安全校验
            guard self.isScreenLocked() else {
                print("[AutoAuth] ⚠️ 激活输入框后屏幕已非锁屏状态，取消密码按键模拟！")
                return
            }

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

    private var lastLitPixelBuffer: CVPixelBuffer?
    private var pendingMatch: (score: Float, box: CGRect)?

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isAuthenticating else { return }

        authFrameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 微软 Windows Hello 规范：偶数帧为 850nm 满血补光帧，奇数帧为环境光无补光帧
        if isIR {
            if cameraService.isNetworkMode {
                // 局域网模式：直接基于远程红外流进行机主特征核验与抓拍留存
                let faces = extractor.extract(from: pixelBuffer)
                for face in faces {
                    let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                    if match.matched {
                        let reasonStr = (currentReason == .lockScreen) ? "lockscreen" : "admin_prompt"
                        print("[AutoAuth] ✓ 局域网红外人脸核验成功 (相似度: \(String(format: "%.2f", match.highestScore)))")
                        AuthAuditLogger.shared.recordAuth(
                            pixelBuffer: pixelBuffer,
                            reason: reasonStr,
                            score: match.highestScore,
                            success: true
                        )
                        onAuthSucceeded()
                        return
                    }
                }
            } else {
                // 本机模式：15Hz 脉冲频闪活体检测与环境光差分
                if authFrameCount % 2 == 0 && authFrameCount >= 2 {
                    // 1. 偶数帧（补光帧）：提取人脸特征并执行特征向量匹配
                    let faces = extractor.extract(from: pixelBuffer)
                    for face in faces {
                        let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                        if match.matched {
                            self.lastLitPixelBuffer = pixelBuffer
                            self.pendingMatch = (match.highestScore, face.boundingBox)
                            break
                        }
                    }
                } else if let lit = lastLitPixelBuffer, let pending = pendingMatch {
                    // 2. 紧随其后的奇数帧（环境帧）：仅用 33ms 差分比对，执行 15Hz 脉冲频闪活体检测（拦截手机/屏幕/打印照片攻击）
                    let liveness = AmbientSubtractionProcessor.shared.verifyLiveness(
                        lit: lit,
                        ambient: pixelBuffer,
                        faceBoundingBox: pending.box
                    )

                    if liveness.isLive {
                        let reasonStr = (currentReason == .lockScreen) ? "lockscreen" : "admin_prompt"
                        print("[AutoAuth] ✓ 机主红外人脸核验成功 (相似度: \(String(format: "%.2f", pending.score)), 频闪活体调制深度: \(String(format: "%.1f%%", liveness.strobeDelta * 100)))")
                        AuthAuditLogger.shared.recordAuth(
                            pixelBuffer: lit,
                            reason: reasonStr,
                            score: pending.score,
                            success: true
                        )
                        lastLitPixelBuffer = nil
                        pendingMatch = nil
                        onAuthSucceeded()
                        return
                    } else {
                        print("[AutoAuth] ⚠️ 活体防伪拦截：无 850nm 频闪脉冲响应 (Delta: \(String(format: "%.3f", liveness.strobeDelta)))，拒绝虚假屏幕/照片攻击！")
                        lastLitPixelBuffer = nil
                        pendingMatch = nil
                    }
                }
            }
        } else {
            // RGB 模式回退 / 局域网全彩流
            let faces = extractor.extract(from: pixelBuffer)
            for face in faces {
                let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                if match.matched {
                    let reasonStr = (currentReason == .lockScreen) ? "lockscreen" : "admin_prompt"
                    print("[AutoAuth] ✓ 机主全彩人脸核验成功 (相似度: \(String(format: "%.2f", match.highestScore)))")
                    AuthAuditLogger.shared.recordAuth(
                        pixelBuffer: pixelBuffer,
                        reason: reasonStr,
                        score: match.highestScore,
                        success: true
                    )
                    onAuthSucceeded()
                    return
                }
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

        // 从钥匙串读取解密密码
        guard let password = keychain.fetchPassword() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            if reason == .lockScreen {
                // 【绝对安全铁律 1】：必须严格核验系统是否确实处于锁屏状态！
                // 如果当前屏幕并未锁定（处于普通桌面应用），绝对严禁发送任何按键！
                guard self.isScreenLocked() else {
                    print("[AutoAuth] ⚠️ 致命安全拦截：屏幕未锁定（处于桌面应用），绝对禁止输入密码！")
                    return
                }

                print("[AutoAuth] ✓ 锁屏机主核验成功，激活输入框并键入密码解锁进桌面...")
                self.accessibility.wakeLoginPrompt()
                usleep(250000) // 250ms 等待输入框清理与就绪

                // 键入前做最后一次原子校验，防止并发解锁
                guard self.isScreenLocked() else {
                    print("[AutoAuth] ⚠️ 致命安全拦截：激活面板后屏幕状态已变更，取消密码输入！")
                    return
                }

                self.accessibility.simulateKeystrokes(password, pressEnter: true)
            } else {
                // 【绝对安全铁律 2】：管理员弹窗模式下，前台应用必须确系 SecurityAgent！
                let frontmost = NSWorkspace.shared.frontmostApplication
                let isSecurityAgent = (frontmost?.bundleIdentifier == "com.apple.SecurityAgent" || frontmost?.localizedName == "SecurityAgent")
                guard isSecurityAgent else {
                    print("[AutoAuth] ⚠️ 致命安全拦截：当前前台窗口不是 SecurityAgent（当前是: \(frontmost?.localizedName ?? "空")），绝对禁止输入密码！")
                    return
                }

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

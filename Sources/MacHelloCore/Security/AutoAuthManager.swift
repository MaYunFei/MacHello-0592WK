import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CIOKitHelper

public enum AuthReason: Equatable {
    case adminPrompt
    case lockScreen
    case manualFill
    case customApp(bundleId: String, appName: String, autoConfirm: Bool)

    public var logReasonString: String {
        switch self {
        case .adminPrompt: return "admin_prompt"
        case .lockScreen: return "lockscreen"
        case .manualFill: return "manual_fill"
        case .customApp(let bid, _, _): return "app_\(bid)"
        }
    }
}

public final class AutoAuthManager: NSObject, CameraCaptureDelegate {
    public static let shared = AutoAuthManager()

    private let defaultsKeyAppAuth = "com.machello.isAppAuthEnabled"
    private let defaultsKeyLockScreenUnlock = "com.machello.isLockScreenUnlockEnabled"
    private let defaultsKeyAudioFeedback = "com.machello.isAudioFeedbackEnabled"
    private let defaultsKeyAdminPromptAutoConfirm = "com.machello.isAdminPromptAutoConfirm"

    public var isAdminPromptAutoConfirm: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyAdminPromptAutoConfirm) == nil {
                return false // 默认安全模式：自动填入密码，由机主手动敲回车确认
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyAdminPromptAutoConfirm)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyAdminPromptAutoConfirm)
        }
    }

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
    public var isAuthActive: Bool { return isAuthenticating }
    private var currentReason: AuthReason = .adminPrompt
    private var authFrameCount = 0
    public private(set) var lastAuthSuccessTime: Date = .distantPast
    private var lastAttemptPixelBuffer: CVPixelBuffer?
    private var highestFailedScore: Float = 0.0
    private var currentSessionUUID: UUID = UUID()
    private var timeoutWorkItem: DispatchWorkItem?

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
        guard now.timeIntervalSince(lastAuthSuccessTime) >= 4.0 else { return }

        print("[AutoAuth] 屏幕唤醒且处于锁定状态，触发 Face ID 自动解锁...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            guard Date().timeIntervalSince(self.lastAuthSuccessTime) >= 4.0 else { return }
            self.triggerFaceAuthForPrompt(reason: .lockScreen)
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

        // 防抖：4秒内不重复触发
        let now = Date()
        guard now.timeIntervalSince(lastAuthSuccessTime) >= 4.0 else { return }

        print("[AutoAuth] 检测到系统进入锁屏状态，等待系统锁屏动效落地 (1.2s)...")
        // 关键：macOS 锁屏切换动画耗时约 800ms~1000ms，期间 loginwindow 不接收按键事件
        // 等待 1.2 秒动效彻底落定后，再开启红外核验，避免按键事件丢失！
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            guard Date().timeIntervalSince(self.lastAuthSuccessTime) >= 4.0 else { return }
            if self.isScreenLocked() {
                self.triggerFaceAuthForPrompt(reason: .lockScreen)
            }
        }
    }

    private func checkAndTriggerSecurityAgent(from notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        let bid = app.bundleIdentifier ?? ""
        let isSystemAuth = AccessibilityHelper.isSystemAuthApp(app)
        if isSystemAuth && isAppAuthEnabled {
            // 防抖：2秒内不重复触发
            let now = Date()
            guard now.timeIntervalSince(lastAuthSuccessTime) > 2.0 else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.triggerFaceAuthForPrompt(reason: .adminPrompt)
            }
            return
        }

        // 检查是否命中已配置「激活时自动刷脸解锁」的第三方专属应用 (例如 Bitwarden)
        if let rule = AppCredentialManager.shared.rule(for: bid), rule.isAutoUnlockEnabled {
            let now = Date()
            guard now.timeIntervalSince(lastAuthSuccessTime) > 3.0 else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self else { return }
                // 仅在前台窗口确系包含未完成输入的密码框或处于锁定状态时才触发，100% 杜绝误触
                if self.accessibility.isFrontmostAppLockedOrHasSecureField(bundleId: rule.bundleId) {
                    self.triggerFaceAuthForPrompt(reason: .customApp(bundleId: rule.bundleId, appName: rule.appName, autoConfirm: rule.autoConfirm))
                }
            }
        }
    }

    /// 触发 Face ID 红外刷脸与自动填入 (支持管理员弹窗与锁屏解锁)
    public func triggerFaceAuthForPrompt(reason: AuthReason = .adminPrompt) {
        authQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isAuthenticating else { return }
            guard !self.isDiagnosticRunning else {
                print("[AutoAuth] 硬件诊断测试正在运行，跳过自动核验")
                return
            }
            guard !FaceEnrollmentService.shared.isEnrolling else {
                print("[AutoAuth] 面容录入向导正在进行，跳过自动核验")
                return
            }
            if reason == .adminPrompt && !self.isAppAuthEnabled {
                print("[AutoAuth] 应用管理员弹窗自动认证已禁用，跳过自动核验")
                return
            }
            if reason == .lockScreen {
                guard self.isLockScreenUnlockEnabled else {
                    print("[AutoAuth] 锁屏自动解锁已禁用，跳过自动核验")
                    return
                }
                guard self.isScreenLocked() else {
                    NSLog("[AutoAuth] 屏幕当前未处于锁定状态，跳过锁屏解锁")
                    return
                }
                let elapsed = Date().timeIntervalSince(self.lastAuthSuccessTime)
                guard elapsed >= 4.0 else {
                    NSLog("[AutoAuth] 距离上次认证成功仅 %.1fs (< 4.0s)，防抖跳过锁屏核验", elapsed)
                    return
                }
            }

            // 智能上下文分流：若是快捷键触发，优先探查前台是否为已配置专属密码的应用 (如 Bitwarden)
            var targetReason = reason
            if reason == .manualFill,
               let frontBid = self.accessibility.frontmostAppBundleIdentifier(),
               let rule = AppCredentialManager.shared.rule(for: frontBid),
               self.keychain.hasAppPassword(bundleId: rule.bundleId) {
                targetReason = .customApp(bundleId: rule.bundleId, appName: rule.appName, autoConfirm: rule.autoConfirm)
                NSLog("[AutoAuth] 识别到当前前台应用为专属应用: %@ (%@)，切换为专属凭据模式", rule.appName, rule.bundleId)
            }

            let isCameraConnected = self.cameraService.isNetworkMode ? LinuxPresenceClient.shared.isConnected : self.irController.isConnected
            guard isCameraConnected else {
                NSLog("[AutoAuth] 摄像头硬件离线或网络服务未就绪，跳过自动核验")
                if reason == .manualFill {
                    SystemNotifier.shared.postNotification(
                        title: "MacHello",
                        body: "摄像头硬件离线或网络服务未就绪，无法核验",
                        force: true
                    )
                }
                return
            }

            // 检查对应钥匙串密码是否存在
            let hasRequiredPassword: Bool
            switch targetReason {
            case .customApp(let bid, _, _):
                hasRequiredPassword = self.keychain.hasAppPassword(bundleId: bid)
            default:
                hasRequiredPassword = self.keychain.hasPassword()
            }

            guard hasRequiredPassword else {
                NSLog("[AutoAuth] 钥匙串中未保存对应密码，跳过自动填入")
                if reason == .manualFill {
                    let name = self.accessibility.frontmostAppName() ?? "该应用"
                    SystemNotifier.shared.postNotification(
                        title: "MacHello",
                        body: "钥匙串未保存 \(name) 密码，请先在菜单中设置",
                        force: true
                    )
                }
                return
            }
            guard self.faceDb.isEnrolled else {
                NSLog("[AutoAuth] 尚未录入面容，跳过自动填入")
                if reason == .manualFill {
                    SystemNotifier.shared.postNotification(
                        title: "MacHello",
                        body: "尚未录入面容，请先在菜单中录入面容 ID",
                        force: true
                    )
                }
                return
            }

            let sessionID = UUID()
            self.currentSessionUUID = sessionID
            self.isAuthenticating = true
            self.currentReason = targetReason
            self.authFrameCount = 0
            self.lastAttemptPixelBuffer = nil
            self.highestFailedScore = 0.0

            let reasonDesc: String
            switch targetReason {
            case .lockScreen: reasonDesc = "锁屏解锁"
            case .manualFill: reasonDesc = "快捷键填密"
            case .adminPrompt: reasonDesc = "管理员弹窗"
            case .customApp(_, let appName, _): reasonDesc = "\(appName) 专属解锁"
            }
            NSLog("[AutoAuth] 触发 Face ID (%@) [Session: %@]，启动 850nm 红外夜视人脸核验...", reasonDesc, String(sessionID.uuidString.prefix(8)))

            if reason == .manualFill {
                SystemNotifier.shared.postNotification(
                    title: "MacHello",
                    body: "正在启动红外相机进行 Face ID 面容比对...",
                    force: true
                )
            }

            // 1. 点亮 850nm 红外并启动 640x480 YUY2 红外流
            if !self.cameraService.isNetworkMode {
                _ = self.irController.setMode(.ir)
            }
            self.cameraService.delegate = self
            do {
                try self.cameraService.start(mode: .ir)
            } catch {
                NSLog("[AutoAuth] 启动红外相机失败: %@", error.localizedDescription)
                if !self.cameraService.isNetworkMode {
                    self.irController.resetToRGB()
                }
                self.isAuthenticating = false
                return
            }

            // 2. 设置安全硬超时 (局域网网络流预留 6.0 秒供模式切换与网络传输，本机 USB 为 4.0 秒)
            let timeoutSeconds: Double = self.cameraService.isNetworkMode ? 6.0 : 4.0
            self.timeoutWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.authQueue.async {
                    guard self.isAuthenticating, self.currentSessionUUID == sessionID else { return }
                    NSLog("[AutoAuth] 红外核验超时未比对成功，自动复位 (最高分: %.3f, 收到帧数: %d)", self.highestFailedScore, self.authFrameCount)
                    if self.currentReason == .manualFill {
                        if self.isAudioFeedbackEnabled {
                            AudioFeedbackHelper.shared.playFailure()
                        }
                        let pct = Int(self.highestFailedScore * 100)
                        let msg = pct > 0 ? "⚠️ 面容比对未通过 (最高相似度: \(pct)%)" : "⚠️ 面容比对超时 (未检测到人脸)"
                        SystemNotifier.shared.postNotification(
                            title: "MacHello",
                            body: msg,
                            force: true
                        )
                    }
                    let reasonStr = self.currentReason.logReasonString
                    if let failedBuffer = self.lastAttemptPixelBuffer {
                        AuthAuditLogger.shared.recordAuth(
                            pixelBuffer: failedBuffer,
                            reason: reasonStr,
                            score: self.highestFailedScore,
                            success: false
                        )
                    } else if self.cameraService.isNetworkMode && self.authFrameCount > 0 {
                        self.captureNetworkSnapshotForAudit(reason: reasonStr, score: self.highestFailedScore, success: false)
                    }
                    self.stopAuth()
                }
            }
            self.timeoutWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
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
        lastAttemptPixelBuffer = pixelBuffer

        // 微软 Windows Hello 规范：偶数帧为 850nm 满血补光帧，奇数帧为环境光无补光帧
        if isIR || cameraService.isNetworkMode {
            if cameraService.isNetworkMode {
                // 局域网模式：直接基于远程红外流进行机主特征核验与抓拍留存
                let faces = extractor.extract(from: pixelBuffer)
                for face in faces {
                    let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                    highestFailedScore = max(highestFailedScore, match.highestScore)
                    if match.matched {
                        let reasonStr = self.currentReason.logReasonString
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
                        highestFailedScore = max(highestFailedScore, match.highestScore)
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
                        let reasonStr = self.currentReason.logReasonString
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
                        NSLog("[AutoAuth] ⚠️ 活体防伪拦截：无 850nm 频闪脉冲响应 (Delta: %.3f)，拒绝虚假屏幕/照片攻击！", liveness.strobeDelta)
                        let reasonStr = "\(self.currentReason.logReasonString)_liveness"
                        AuthAuditLogger.shared.recordAuth(
                            pixelBuffer: lit,
                            reason: reasonStr,
                            score: pending.score,
                            success: false
                        )
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
                highestFailedScore = max(highestFailedScore, match.highestScore)
                if match.matched {
                    let reasonStr = self.currentReason.logReasonString
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
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        currentSessionUUID = UUID()
        isAuthenticating = false
        lastAttemptPixelBuffer = nil
        lastAuthSuccessTime = Date()

        // 停止相机并安全复位硬件
        stopAuth()

        // 根据认证场景决定读取 Mac 系统登录密码还是第三方应用专属密码
        let passwordOpt: String?
        switch reason {
        case .customApp(let bid, _, _):
            passwordOpt = self.keychain.fetchAppPassword(bundleId: bid)
        default:
            passwordOpt = self.keychain.fetchPassword()
        }

        guard let password = passwordOpt else {
            NSLog("[AutoAuth] ❌ 人脸比对核验成功，但无法从钥匙串解密对应密码！")
            if isAudioFeedbackEnabled {
                AudioFeedbackHelper.shared.playFailure()
            }
            SystemNotifier.shared.postNotification(
                title: "MacHello",
                body: "❌ 钥匙串解密失败！请检查钥匙串授权或重新保存密码",
                force: true
            )
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "MacHello 钥匙串访问未授权"
                alert.informativeText = "人脸核验成功，但无法从系统钥匙串读取密码。\n\n请点击 MacHello 菜单栏中的「🔑 验证 / 授权钥匙串访问权限」进行一次性授权。"
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            return
        }

        // 成功读取到机主密码后，再播放成功提示音！
        if isAudioFeedbackEnabled {
            audio.playSuccess()
        }

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
            } else if case .customApp(_, let appName, let autoConfirm) = reason {
                NSLog("[AutoAuth] ✓ 专属应用 (%@) 刷脸核验成功，自动填入密码 (自动回车: %d)...", appName, autoConfirm)
                self.accessibility.fillActivePasswordField(password: password, autoConfirm: autoConfirm)
                SystemNotifier.shared.postNotification(
                    title: "MacHello",
                    body: "✓ Face ID 认证成功，\(appName) 密码已填入！",
                    force: true
                )
            } else if reason == .manualFill {
                // 全局快捷键刷脸填密模式：填充密码框（不自动按回车，安全受控）
                NSLog("[AutoAuth] ✓ 全局快捷键刷脸核验成功，自动填入当前密码框...")
                self.accessibility.fillActivePasswordField(password: password, autoConfirm: false)
                SystemNotifier.shared.postNotification(
                    title: "MacHello",
                    body: "✓ Face ID 认证成功，密码已填入！",
                    force: true
                )
            } else {
                // 【绝对安全铁律 2】：系统安全/管理员弹窗模式下，确系安全认证提权框处于活跃状态！
                // 解决：macOS 14/15/27 启用 Secure Event Input 导致底层 CGEvent 键盘模拟事件被 WindowServer 静默拦截丢弃的问题。
                // 优先通过系统授权的 Accessibility API 直接填入密码（全面适配 SecurityAgent 与 LocalAuthentication coreautha / RemoteService）：
                let autoConfirm = self.isAdminPromptAutoConfirm
                NSLog("[AutoAuth] ✓ 系统安全弹窗机主核验成功，填入密码 (确认模式: %@)...", autoConfirm ? "极速直接确认" : "需手动按回车确认")
                let filled = self.accessibility.fillAndConfirmSystemAuthPrompt(password: password, autoConfirm: autoConfirm)
                if !filled {
                    // 若 AX 直接写入未完成，回退到原有焦点激活与键盘事件模拟机制
                    NSLog("[AutoAuth] ⚠️ AX 直接写入未完成，回退到焦点激活与键盘事件模拟...")
                    let isSecPromptReady = self.accessibility.focusSystemAuthPrompt()
                    usleep(80000)

                    let frontmost = NSWorkspace.shared.frontmostApplication
                    let isSystemAuth = frontmost.map { AccessibilityHelper.isSystemAuthApp($0) } ?? false
                    if isSystemAuth || isSecPromptReady {
                        self.accessibility.simulateKeystrokes(password, pressEnter: autoConfirm)
                        SystemNotifier.shared.postNotification(
                            title: "MacHello",
                            body: "✓ 系统安全弹窗 Face ID 认证成功，密码已填入！",
                            force: true
                        )
                    } else {
                        NSLog("[AutoAuth] ⚠️ 致命安全拦截：当前屏幕未找到活跃的系统安全提权弹窗，取消操作")
                    }
                } else {
                    SystemNotifier.shared.postNotification(
                        title: "MacHello",
                        body: "✓ 系统安全弹窗 Face ID 认证成功，密码已填入！",
                        force: true
                    )
                }
            }
        }
    }

    private func stopAuth() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        currentSessionUUID = UUID()
        isAuthenticating = false
        lastAttemptPixelBuffer = nil
        cameraService.stop()
        if !cameraService.isNetworkMode {
            irController.resetToRGB()
        }
    }

    private func captureNetworkSnapshotForAudit(reason: String, score: Float, success: Bool) {
        let serverURL = cameraService.networkServerURL
        guard let url = URL(string: "\(serverURL)/api/snapshot") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data {
                AuthAuditLogger.shared.recordAuth(data: data, reason: reason, score: score, success: success)
            }
        }.resume()
    }
}

import Foundation
import CoreMedia
import AppKit

public final class PresenceAutoDisplayService: NSObject, CameraCaptureDelegate, PresenceDetectorDelegate {
    public static let shared = PresenceAutoDisplayService()

    private let captureService = CameraCaptureService.shared
    private let irController = IRController.shared
    private let presenceDetector = PresenceDetector.shared
    private let displayManager = DisplayPowerManager.shared
    private let extractor = FaceFeatureExtractor.shared
    private let faceDb = FaceDatabase.shared
    private let idleMonitor = InputIdleMonitor.shared
    private let mediaDetector = MediaActivityDetector.shared

    private let defaultsKeyEnabled = "com.machello.autoDisplayEnabled"
    private let defaultsKeyTimeout = "com.machello.absenceTimeout"
    private let defaultsKeyOwnerOnly = "com.machello.requireOwnerVerification"
    private let defaultsKeySmartIdle = "com.machello.smartIdlePowerSaving"
    private let defaultsKeyRespectMedia = "com.machello.respectMediaPlayback"

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKeyEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyEnabled)
            handleEnabledChanged(newValue)
        }
    }

    public var absenceTimeout: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: defaultsKeyTimeout)
            return val > 0 ? val : 15.0 // 默认 15 秒
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyTimeout)
        }
    }

    /// 是否开启机主身份专属鉴权（仅限录入的机主靠近才亮屏，防陌生人防窥）
    public var requireOwnerVerification: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyOwnerOnly) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyOwnerOnly)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyOwnerOnly)
        }
    }

    /// 智能键鼠感知与低功耗模式（打字/鼠标操作时彻底关闭摄像头，指示灯灭，0% CPU）
    public var isSmartIdlePowerSavingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeySmartIdle) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeySmartIdle)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeySmartIdle)
        }
    }

    /// 视频/会议播放感知（观看 YouTube、B站、电影或开会时自动免打扰，不息屏不闪灯）
    public var respectMediaPlayback: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyRespectMedia) == nil {
                return true // 默认开启
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyRespectMedia)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyRespectMedia)
        }
    }

    public private(set) var isOwnerVerified: Bool = false
    public private(set) var isPersonPresent: Bool = false

    private var lastSeenOwnerTime: Date = Date()
    private var lastProbeSuccessTime: Date = .distantPast
    private var absenceTimer: Timer?
    private var lastProcessedFrameTime: Date = .distantPast
    private let frameProcessingInterval: TimeInterval = 0.25 // 约 4 FPS 采样

    // 息屏脉冲巡检计数
    private var pulseCycleCounter: Int = 0

    public var onStateUpdated: ((_ isEnabled: Bool, _ isPresent: Bool, _ isOwner: Bool, _ isDisplayAsleep: Bool) -> Void)?

    /// 诊断测试独占标记：硬件自检运行时全权让出摄像头
    public var isDiagnosticRunning: Bool = false {
        didSet {
            if isDiagnosticRunning {
                captureService.stop()
            }
        }
    }

    private override init() {
        super.init()
        presenceDetector.delegate = self
        if isEnabled {
            startMonitoring()
        }
    }

    private func handleEnabledChanged(_ enabled: Bool) {
        if enabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
        emitStateChange()
    }

    private func emitStateChange() {
        onStateUpdated?(isEnabled, isPersonPresent, isOwnerVerified, displayManager.isDisplayAsleep)
    }

    public func startMonitoring() {
        guard !FaceEnrollmentService.shared.isEnrolling else { return }

        lastSeenOwnerTime = Date()
        lastProbeSuccessTime = Date()
        presenceDetector.autoNotify = false

        if !isSmartIdlePowerSavingEnabled || idleMonitor.idleSeconds >= 3.0 {
            if !captureService.isRunning {
                try? captureService.start(mode: .rgb)
            }
            captureService.delegate = self
        }

        startAbsenceCheckTimer()
    }

    public func stopMonitoring() {
        stopAbsenceCheckTimer()
        if !FaceEnrollmentService.shared.isEnrolling {
            captureService.stop()
        }
    }

    private func startAbsenceCheckTimer() {
        stopAbsenceCheckTimer()
        absenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAbsenceStatus()
        }
    }

    private func stopAbsenceCheckTimer() {
        absenceTimer?.invalidate()
        absenceTimer = nil
    }

    private func checkAbsenceStatus() {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling, !isDiagnosticRunning else { return }

        // 硬件连接断开保护 (Fail-Safe Guard)：
        // 若摄像头已被用户物理拔出或未就绪，绝不强行熄屏！
        // 自动安全挂起，将屏幕显示保持点亮状态，交由 macOS 原生电源管理托管
        guard irController.isConnected else {
            lastSeenOwnerTime = Date()
            lastProbeSuccessTime = Date()
            if captureService.isRunning {
                captureService.stop()
            }
            return
        }

        // 情况一：屏幕当前处于点亮工作状态
        if !displayManager.isDisplayAsleep {
            pulseCycleCounter = 0

            // 1. 媒体播放 / 在线会议感知：若正在观看视频（YouTube/B站/电影）或开会
            if respectMediaPlayback && mediaDetector.isPreventingDisplaySleep {
                lastSeenOwnerTime = Date()
                lastProbeSuccessTime = Date()
                let changed = (!isPersonPresent || !isOwnerVerified)
                isPersonPresent = true
                isOwnerVerified = true

                // 观影期间绝不闪灯打扰，彻底关闭相机，0% CPU
                if captureService.isRunning {
                    captureService.stop()
                }
                if changed {
                    emitStateChange()
                }
                return
            }

            if isSmartIdlePowerSavingEnabled {
                let idle = idleMonitor.idleSeconds
                let probeInterval = max(5.0, absenceTimeout - 4.0)

                // 2. 如果用户正在操作键盘鼠标
                if idle < 3.0 {
                    lastSeenOwnerTime = Date()
                    lastProbeSuccessTime = Date()
                    let changed = (!isPersonPresent || !isOwnerVerified)
                    isPersonPresent = true
                    isOwnerVerified = true

                    // 用户正在打字，断开摄像头，指示灯灭，CPU 归零
                    if captureService.isRunning {
                        captureService.stop()
                    }
                    if changed {
                        emitStateChange()
                    }
                    return
                }

                // 3. 如果不久前刚刚通过摄像头确认过用户还在（在过去 probeInterval 秒内已探查过）
                let timeSinceLastProbe = Date().timeIntervalSince(lastProbeSuccessTime)
                if timeSinceLastProbe < probeInterval {
                    if captureService.isRunning {
                        captureService.stop()
                    }
                    return
                }

                // 4. 停手超时：启动摄像头进行瞬时探查（人在即灭）
                if !captureService.isRunning {
                    try? captureService.start(mode: .rgb)
                    captureService.delegate = self
                }

                // 5. 检查是否达到离席超时上限
                let elapsed = Date().timeIntervalSince(lastSeenOwnerTime)
                if elapsed >= absenceTimeout {
                    // 确认无人，立即息屏
                    displayManager.sleepDisplay()
                    if captureService.isRunning {
                        captureService.stop()
                    }
                    emitStateChange()
                }
            } else {
                // 常规持续视觉模式
                if !captureService.isRunning {
                    try? captureService.start(mode: .rgb)
                    captureService.delegate = self
                }
                let isOwnerSitting = requireOwnerVerification && faceDb.isEnrolled ? isOwnerVerified : isPersonPresent
                if !isOwnerSitting {
                    let elapsed = Date().timeIntervalSince(lastSeenOwnerTime)
                    if elapsed >= absenceTimeout {
                        displayManager.sleepDisplay()
                        emitStateChange()
                    }
                }
            }
        } else {
            // 情况二：屏幕处于息屏黑屏状态
            if isSmartIdlePowerSavingEnabled {
                // 间歇低频脉冲巡检：每 3 秒启动红外夜视相机探测 1 秒，无人则关停，指示灯大部分时间熄灭
                pulseCycleCounter = (pulseCycleCounter + 1) % 3
                if pulseCycleCounter == 0 {
                    if !captureService.isRunning {
                        _ = irController.setMode(.ir)
                        try? captureService.start(mode: .ir)
                        captureService.delegate = self
                    }
                } else if pulseCycleCounter == 1 {
                    // 维持检测中
                } else {
                    // 暂无人员靠近，关停相机并复位硬件以熄灭红外发射器与指示灯
                    if captureService.isRunning {
                        captureService.stop()
                        irController.resetToRGB()
                    }
                }
            } else {
                if !captureService.isRunning {
                    _ = irController.setMode(.ir)
                    try? captureService.start(mode: .ir)
                    captureService.delegate = self
                }
            }
        }
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling, !isDiagnosticRunning else { return }

        let now = Date()
        guard now.timeIntervalSince(lastProcessedFrameTime) >= frameProcessingInterval else { return }
        lastProcessedFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if requireOwnerVerification && faceDb.isEnrolled {
            let faces = extractor.extract(from: pixelBuffer)
            if faces.isEmpty {
                handleNoPerson()
            } else {
                var foundOwner = false
                var highestScore: Float = 0.0

                for face in faces {
                    let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                    if match.matched {
                        foundOwner = true
                        highestScore = max(highestScore, match.highestScore)
                    }
                }

                if foundOwner {
                    handleOwnerPresent(score: highestScore, pixelBuffer: pixelBuffer)
                } else {
                    handleStrangerPresent()
                }
            }
        } else {
            presenceDetector.processSampleBuffer(sampleBuffer)
        }
    }

    private func handleOwnerPresent(score: Float, pixelBuffer: CVPixelBuffer? = nil) {
        let changed = (!isPersonPresent || !isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = true
        lastSeenOwnerTime = Date()
        lastProbeSuccessTime = Date()

        // 1. 如果屏幕已息屏，机主出现立刻点亮屏幕并自动解锁进桌面！
        if displayManager.isDisplayAsleep {
            if let pb = pixelBuffer {
                AuthAuditLogger.shared.recordAuth(
                    pixelBuffer: pb,
                    reason: "wake_display",
                    score: score,
                    success: true
                )
            }
            displayManager.wakeDisplay()
            irController.resetToRGB()
            emitStateChange()
            AutoAuthManager.shared.unlockScreenIfNeeded()
        } else {
            // 如果屏幕当前正处于锁定界面 (例如快捷键 Cmd+Ctrl+Q 锁定)，机主在位立刻自动解锁
            if AutoAuthManager.shared.isScreenLocked() {
                AutoAuthManager.shared.unlockScreenIfNeeded()
            }
            if changed {
                emitStateChange()
            }
        }

        // 2. 如果屏幕亮着且开启了智能节能：既然已经看准了机主在位，探查立刻圆满完成！
        // 瞬间关闭摄像头，指示灯立刻熄灭，绝不一直常亮！
        if !displayManager.isDisplayAsleep && isSmartIdlePowerSavingEnabled {
            if captureService.isRunning {
                captureService.stop()
            }
        }
    }

    private func handleStrangerPresent() {
        let changed = (!isPersonPresent || isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = false

        if changed {
            emitStateChange()
        }
    }

    private func handleNoPerson() {
        let changed = (isPersonPresent || isOwnerVerified)
        isPersonPresent = false
        isOwnerVerified = false

        if changed {
            emitStateChange()
        }
    }

    // MARK: - PresenceDetectorDelegate (通用回退模式)

    public func presenceDetector(_ detector: PresenceDetector, didChangePresence isPresent: Bool, faceCount: Int) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling else { return }
        guard !requireOwnerVerification || !faceDb.isEnrolled else { return }

        let changed = (isPersonPresent != isPresent)
        isPersonPresent = isPresent
        isOwnerVerified = false

        if isPresent {
            lastSeenOwnerTime = Date()
            lastProbeSuccessTime = Date()
            if displayManager.isDisplayAsleep {
                displayManager.wakeDisplay()
                emitStateChange()
            } else if changed {
                emitStateChange()
            }

            if !displayManager.isDisplayAsleep && isSmartIdlePowerSavingEnabled {
                if captureService.isRunning {
                    captureService.stop()
                }
            }
        } else if changed {
            lastSeenOwnerTime = Date()
            emitStateChange()
        }
    }
}

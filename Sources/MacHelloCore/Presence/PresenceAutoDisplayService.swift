import Foundation
import CoreMedia
import AppKit

public final class PresenceAutoDisplayService: NSObject, CameraCaptureDelegate, PresenceDetectorDelegate {
    public static let shared = PresenceAutoDisplayService()

    private let captureService = CameraCaptureService.shared
    private let presenceDetector = PresenceDetector.shared
    private let displayManager = DisplayPowerManager.shared
    private let extractor = FaceFeatureExtractor.shared
    private let faceDb = FaceDatabase.shared
    private let idleMonitor = InputIdleMonitor.shared

    private let defaultsKeyEnabled = "com.machello.autoDisplayEnabled"
    private let defaultsKeyTimeout = "com.machello.absenceTimeout"
    private let defaultsKeyOwnerOnly = "com.machello.requireOwnerVerification"
    private let defaultsKeySmartIdle = "com.machello.smartIdlePowerSaving"

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
                return true // 默认开启
            }
            return UserDefaults.standard.bool(forKey: defaultsKeySmartIdle)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeySmartIdle)
        }
    }

    public private(set) var isOwnerVerified: Bool = false
    public private(set) var isPersonPresent: Bool = false

    private var lastSeenOwnerTime: Date = Date()
    private var absenceTimer: Timer?
    private var lastProcessedFrameTime: Date = .distantPast
    private let frameProcessingInterval: TimeInterval = 0.25 // 约 4 FPS 采样

    // 息屏脉冲巡检计数
    private var pulseCycleCounter: Int = 0

    public var onStateUpdated: ((_ isEnabled: Bool, _ isPresent: Bool, _ isOwner: Bool, _ isDisplayAsleep: Bool) -> Void)?

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
        presenceDetector.autoNotify = false

        // 如果用户正在打字且开启了智能节能，不立刻起相机；否则启动相机
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
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling else { return }

        // 情况一：屏幕当前处于点亮工作状态
        if !displayManager.isDisplayAsleep {
            pulseCycleCounter = 0

            if isSmartIdlePowerSavingEnabled {
                let idle = idleMonitor.idleSeconds
                let probeThreshold = max(3.0, absenceTimeout - 3.0)

                // 1. 用户正在积极操作键盘鼠标（停手时间 < 阈值）
                if idle < probeThreshold {
                    lastSeenOwnerTime = Date()
                    let changed = (!isPersonPresent || !isOwnerVerified)
                    isPersonPresent = true
                    isOwnerVerified = true

                    // 既然机主正在打字操作，果断关闭摄像头！让指示灯 100% 熄灭，CPU 归零！
                    if captureService.isRunning {
                        captureService.stop()
                    }
                    if changed {
                        emitStateChange()
                    }
                    return
                } else {
                    // 2. 停手超时：用户已有一段时间没碰键盘鼠标了
                    // 启动摄像头进行 0.5s~3s 快速观察（判断是离席还是在安静阅读）
                    if !captureService.isRunning {
                        try? captureService.start(mode: .rgb)
                        captureService.delegate = self
                    }

                    // 检查是否已达到离席超时上限
                    let elapsed = Date().timeIntervalSince(lastSeenOwnerTime)
                    if elapsed >= absenceTimeout {
                        // 确认无人，立即关闭显示器息屏
                        displayManager.sleepDisplay()
                        if captureService.isRunning {
                            captureService.stop()
                        }
                        emitStateChange()
                    }
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
                // 间歇低频脉冲巡检：每 3 秒启动相机探测 1 秒，无人则关停，指示灯大部分时间熄灭
                pulseCycleCounter = (pulseCycleCounter + 1) % 3
                if pulseCycleCounter == 0 {
                    if !captureService.isRunning {
                        try? captureService.start(mode: .rgb)
                        captureService.delegate = self
                    }
                } else if pulseCycleCounter == 1 {
                    // 维持检测中
                } else {
                    // 巡检周期结束，暂无人员靠近，关停相机以熄灭指示灯
                    if captureService.isRunning {
                        captureService.stop()
                    }
                }
            } else {
                if !captureService.isRunning {
                    try? captureService.start(mode: .rgb)
                    captureService.delegate = self
                }
            }
        }
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling else { return }

        // 帧率节流 (约 4 FPS)
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
                    handleOwnerPresent(score: highestScore)
                } else {
                    handleStrangerPresent()
                }
            }
        } else {
            presenceDetector.processSampleBuffer(sampleBuffer)
        }
    }

    private func handleOwnerPresent(score: Float) {
        let changed = (!isPersonPresent || !isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = true
        lastSeenOwnerTime = Date()

        // 如果屏幕已息屏，机主出现立刻点亮屏幕！
        if displayManager.isDisplayAsleep {
            displayManager.wakeDisplay()
            emitStateChange()
        } else if changed {
            emitStateChange()
        }

        // 如果开启了智能节能且用户正在工作屏幕前，确认人在位后可关闭相机熄灭灯
        if !displayManager.isDisplayAsleep && isSmartIdlePowerSavingEnabled {
            // 人在位，稍后由 checkAbsenceStatus 维持休眠
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
            if displayManager.isDisplayAsleep {
                displayManager.wakeDisplay()
                emitStateChange()
            } else if changed {
                emitStateChange()
            }
        } else if changed {
            lastSeenOwnerTime = Date()
            emitStateChange()
        }
    }
}

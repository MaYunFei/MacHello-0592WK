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

    private let defaultsKeyEnabled = "com.machello.autoDisplayEnabled"
    private let defaultsKeyTimeout = "com.machello.absenceTimeout"
    private let defaultsKeyOwnerOnly = "com.machello.requireOwnerVerification"

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
            return val > 0 ? val : 15.0 // 默认 15 秒（测试与使用兼顾）
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyTimeout)
        }
    }

    /// 是否开启机主身份专属鉴权（仅限录入的机主靠近才亮屏，防陌生人防窥）
    public var requireOwnerVerification: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyOwnerOnly) == nil {
                return true // 默认开启
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyOwnerOnly)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyOwnerOnly)
        }
    }

    public private(set) var isOwnerVerified: Bool = false
    public private(set) var isPersonPresent: Bool = false

    private var lastSeenOwnerTime: Date = Date()
    private var absenceTimer: Timer?
    private var lastProcessedFrameTime: Date = .distantPast
    private let frameProcessingInterval: TimeInterval = 0.2 // 约 5 FPS 采样，极低 CPU 占用

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

        if !captureService.isRunning {
            try? captureService.start(mode: .rgb)
        }
        captureService.delegate = self

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

        let isOwnerSitting = requireOwnerVerification && faceDb.isEnrolled ? isOwnerVerified : isPersonPresent

        // 如果机主不在位且屏幕当前亮着
        if !isOwnerSitting && !displayManager.isDisplayAsleep {
            let elapsed = Date().timeIntervalSince(lastSeenOwnerTime)
            if elapsed >= absenceTimeout {
                // 走开超时，执行息屏
                displayManager.sleepDisplay()
                emitStateChange()
            }
        }
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling else { return }

        // 帧率节流 (约 5 FPS)
        let now = Date()
        guard now.timeIntervalSince(lastProcessedFrameTime) >= frameProcessingInterval else { return }
        lastProcessedFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 2. 如果屏幕处于点亮状态且开启了隔空手势，进行手势识别处理
        if GestureActionManager.shared.isEnabled && !displayManager.isDisplayAsleep {
            HandGestureDetector.shared.process(pixelBuffer: pixelBuffer)
        }

        // 1. 如果启用了机主鉴权且本地已有录入数据
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
            // 未启用或未录入时：退化为通用人脸检测
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
            // 只有当状态真正发生转变时（例如从无人/陌生人变为机主），才通知 UI 刷新，坚决不每帧刷新！
            emitStateChange()
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

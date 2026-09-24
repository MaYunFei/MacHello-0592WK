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
    private let defaultsKeyNetworkMode = "com.machello.isNetworkModeEnabled"

    private let linuxClient = LinuxPresenceClient.shared

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKeyEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyEnabled)
            handleEnabledChanged(newValue)
        }
    }

    /// 局域网 Linux 服务模式（摄像头插在局域网 Linux 设备上，全天候 24h 智能 HPD 感应，Mac 本机 0 摄像头开销）
    public var isNetworkModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKeyNetworkMode) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyNetworkMode)
            handleNetworkModeChanged(newValue)
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

        // 注册局域网 Linux 服务端事件推送
        linuxClient.onOwnerArrived = { [weak self] in
            self?.handleLinuxOwnerArrived()
        }
        linuxClient.onOwnerDeparted = { [weak self] in
            self?.handleLinuxOwnerDeparted()
        }
        linuxClient.onStrangerDetected = { [weak self] in
            self?.handleLinuxStrangerDetected()
        }

        if isEnabled {
            startMonitoring()
        }
    }

    private func handleNetworkModeChanged(_ enabled: Bool) {
        if enabled {
            captureService.stop()
            linuxClient.start()
        } else {
            linuxClient.stop()
            if isEnabled {
                startMonitoring()
            }
        }
        emitStateChange()
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

        if isNetworkModeEnabled {
            captureService.stop()
            linuxClient.start()
        } else {
            // 本机模式：遵循 BLEUnlock 规范，平时彻底关闭摄像头，0% CPU，状态栏 0 绿点
            captureService.stop()
        }

        startAbsenceCheckTimer()
    }

    public func stopMonitoring() {
        stopAbsenceCheckTimer()
        linuxClient.stop()
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
        // 若摄像头未连接（无论本机还是局域网），绝不强行熄屏！
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

            // 1. 媒体播放 / 在线会议感知：若正在观看视频（YouTube/B站/电影）或开会，免打扰不熄屏
            if respectMediaPlayback && mediaDetector.isPreventingDisplaySleep {
                lastSeenOwnerTime = Date()
                let changed = (!isPersonPresent || !isOwnerVerified)
                isPersonPresent = true
                isOwnerVerified = true

                if captureService.isRunning {
                    captureService.stop()
                }
                if changed {
                    emitStateChange()
                }
                return
            }

            let idle = idleMonitor.idleSeconds

            // 2. 如果用户正在操作键盘鼠标，刷新在位时间
            if idle < 3.0 {
                lastSeenOwnerTime = Date()
                let changed = (!isPersonPresent || !isOwnerVerified)
                isPersonPresent = true
                isOwnerVerified = true

                if captureService.isRunning {
                    captureService.stop()
                }
                if changed {
                    emitStateChange()
                }
                return
            }

            // 3. 用户停手超过 3 秒（例如阅读、思考、或者离开了）：
            // 在局域网模式下，每隔 3 秒请求一次 Linux 摄像头的单帧快照进行在位巡视 (Apple NPU 识别)
            // 此时 Linux 摄像头会闪亮 0.1 秒进行人脸抓拍，指示灯眨一下眼，然后立即熄灭！
            if isNetworkModeEnabled {
                pollNetworkSnapshotForPresenceCheck()
            } else if captureService.isRunning {
                captureService.stop()
            }

            // 4. 检查是否达到无操作离席超时上限
            let elapsed = Date().timeIntervalSince(lastSeenOwnerTime)
            if elapsed >= absenceTimeout {
                print("[Presence] 离开超时 \(Int(elapsed))s >= \(Int(absenceTimeout))s，立即锁定屏幕！")
                displayManager.sleepDisplay()
                isPersonPresent = false
                isOwnerVerified = false
                emitStateChange()
            }
        } else {
            // 情况二：屏幕处于息屏黑屏状态 (锁屏)
            if isNetworkModeEnabled {
                // 锁屏期间：每隔 2 秒请求一次快照，检测机主是否回到座位 (Apple NPU 识别到机主立即自动解锁)
                pollNetworkSnapshotForPresenceCheck()
            } else {
                // 本机直连模式遵循 BLEUnlock，黑屏期间摄像头彻底断电关闭，直到用户按键亮屏触发 Face ID 解锁
                if captureService.isRunning {
                    captureService.stop()
                    irController.resetToRGB()
                }
            }
        }
    }

    private var isPollingSnapshot = false
    private var lastSnapshotPollTime: Date = .distantPast

    private func pollNetworkSnapshotForPresenceCheck() {
        guard !isPollingSnapshot else { return }
        let now = Date()
        let interval: TimeInterval = displayManager.isDisplayAsleep ? 2.0 : 3.0
        guard now.timeIntervalSince(lastSnapshotPollTime) >= interval else { return }
        lastSnapshotPollTime = now
        isPollingSnapshot = true

        let serverURL = LinuxPresenceClient.shared.serverURLString
        guard let url = URL(string: "\(serverURL)/api/snapshot") else {
            isPollingSnapshot = false
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            defer { self?.isPollingSnapshot = false }
            guard let self = self,
                  let data = data,
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return
            }

            // 利用苹果 Vision 框架和 Apple NPU 毫秒级提取面容特征并比对 ~/.machello/faces.json
            let isInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")
            let orientation: CGImagePropertyOrientation = isInverted ? .down : .up
            let faces = self.extractor.extract(from: cgImage, orientation: orientation)
            guard !faces.isEmpty else { return }

            for face in faces {
                let match = self.faceDb.match(embedding: face.embedding, threshold: 0.58)
                if match.matched {
                    print("[Presence] ✓ 局域网摄像头检测到机主！(Apple NPU 识别打分: \(String(format: "%.2f", match.highestScore)))")
                    DispatchQueue.main.async {
                        self.handleOwnerDetectedOverNetwork(score: match.highestScore)
                    }
                    break
                }
            }
        }.resume()
    }

    private func handleOwnerDetectedOverNetwork(score: Float) {
        lastSeenOwnerTime = Date()
        let changed = (!isPersonPresent || !isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = true

        if displayManager.isDisplayAsleep {
            displayManager.wakeDisplay()
            emitStateChange()
            AutoAuthManager.shared.unlockScreenIfNeeded()
        } else if AutoAuthManager.shared.isScreenLocked() {
            AutoAuthManager.shared.unlockScreenIfNeeded()
            emitStateChange()
        } else if changed {
            emitStateChange()
        }
    }

    // MARK: - Linux 局域网服务事件响应

    private func handleLinuxOwnerArrived() {
        guard isEnabled && isNetworkModeEnabled else { return }
        let changed = (!isPersonPresent || !isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = true
        lastSeenOwnerTime = Date()

        // 收到 Linux 局域网服务端检测到机主靠近：如果屏幕休眠，毫秒级点亮并自动解锁进桌面！
        if displayManager.isDisplayAsleep {
            displayManager.wakeDisplay()
            emitStateChange()
            AutoAuthManager.shared.unlockScreenIfNeeded()
        } else {
            if AutoAuthManager.shared.isScreenLocked() {
                AutoAuthManager.shared.unlockScreenIfNeeded()
            }
            if changed {
                emitStateChange()
            }
        }
    }

    private func handleLinuxOwnerDeparted() {
        guard isEnabled && isNetworkModeEnabled else { return }
        isPersonPresent = false
        isOwnerVerified = false
        if !displayManager.isDisplayAsleep {
            displayManager.sleepDisplay()
            emitStateChange()
        }
    }

    private func handleLinuxStrangerDetected() {
        guard isEnabled && isNetworkModeEnabled else { return }
        let changed = (!isPersonPresent || isOwnerVerified)
        isPersonPresent = true
        isOwnerVerified = false
        if changed {
            emitStateChange()
        }
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling, !isDiagnosticRunning else { return }

        let now = Date()
        // 动态自适应节能采样率：
        // 屏幕点亮且已确认机主在席时，降频至 1.0 秒一次（1 FPS），避免无效 Vision 特征提取计算，CPU 占用 < 0.2%；
        // 息屏脉冲探测或机主未认定时，保持 0.25 秒（4 FPS）以确保秒级响应。
        let targetInterval: TimeInterval = (!displayManager.isDisplayAsleep && isPersonPresent && isOwnerVerified) ? 1.0 : frameProcessingInterval
        guard now.timeIntervalSince(lastProcessedFrameTime) >= targetInterval else { return }
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
            pulseCycleCounter = 0
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
                pulseCycleCounter = 0
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

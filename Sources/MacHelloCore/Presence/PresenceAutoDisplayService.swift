import Foundation
import CoreMedia
import AppKit

public final class PresenceAutoDisplayService: NSObject, CameraCaptureDelegate, PresenceDetectorDelegate {
    public static let shared = PresenceAutoDisplayService()

    private let captureService = CameraCaptureService.shared
    private let presenceDetector = PresenceDetector.shared
    private let displayManager = DisplayPowerManager.shared

    private let defaultsKeyEnabled = "com.machello.autoDisplayEnabled"
    private let defaultsKeyTimeout = "com.machello.absenceTimeout"

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

    private var lastSeenPersonTime: Date = Date()
    private var absenceTimer: Timer?
    private var lastProcessedFrameTime: Date = .distantPast
    private let frameProcessingInterval: TimeInterval = 0.2 // 约 5 FPS 采样，极低 CPU 占用

    public var onStateUpdated: ((_ isEnabled: Bool, _ isPresent: Bool, _ isDisplayAsleep: Bool) -> Void)?

    private override init() {
        super.init()
        presenceDetector.delegate = self
        // 初始若开启则恢复监控
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
        onStateUpdated?(enabled, presenceDetector.isPersonPresent, displayManager.isDisplayAsleep)
    }

    public func startMonitoring() {
        guard !FaceEnrollmentService.shared.isEnrolling else { return }

        lastSeenPersonTime = Date()
        presenceDetector.autoNotify = false // 避免每帧弹通知轰炸

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

        // 如果当前无人且屏幕亮着
        if !presenceDetector.isPersonPresent && !displayManager.isDisplayAsleep {
            let elapsed = Date().timeIntervalSince(lastSeenPersonTime)
            if elapsed >= absenceTimeout {
                // 走开息屏
                displayManager.sleepDisplay()
                onStateUpdated?(isEnabled, false, true)
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

        presenceDetector.processSampleBuffer(sampleBuffer)
    }

    // MARK: - PresenceDetectorDelegate

    public func presenceDetector(_ detector: PresenceDetector, didChangePresence isPresent: Bool, faceCount: Int) {
        guard isEnabled, !FaceEnrollmentService.shared.isEnrolling else { return }

        if isPresent {
            lastSeenPersonTime = Date()
            // 来人亮屏
            if displayManager.isDisplayAsleep {
                displayManager.wakeDisplay()
                onStateUpdated?(isEnabled, true, false)
            }
        } else {
            // 人离开视野
            lastSeenPersonTime = Date()
        }

        onStateUpdated?(isEnabled, isPresent, displayManager.isDisplayAsleep)
    }
}

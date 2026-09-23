import Foundation
import MacHelloCore
import CoreMedia
import AVFoundation

final class Authenticator: NSObject, CameraCaptureDelegate {
    private let irController = IRController.shared
    private let cameraService = CameraCaptureService.shared
    private let extractor = FaceFeatureExtractor.shared
    private let faceDb = FaceDatabase.shared

    private let sema = DispatchSemaphore(value: 0)
    private var isAuthenticated = false
    private var isFinished = false
    private var frameCount = 0
    private let lock = NSLock()

    var timeoutSeconds: TimeInterval = 2.5
    var preferIR: Bool = true

    func authenticate() -> Bool {
        guard faceDb.isEnrolled, let profile = faceDb.load() else {
            fputs("[MacHello] 未录入任何人脸特征，请先通过菜单或 MacHelloEnroll 录入\n", stderr)
            return false
        }

        // 1. 权限预检：解决首次在此终端使用时弹窗等待用户点击而导致的“超时”问题
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .notDetermined {
            fputs("[MacHello] 首次在此应用中使用，请在弹出的系统对话框中点击「好」以允许摄像头...\n", stderr)
            fflush(stderr)
            let authSema = DispatchSemaphore(value: 0)
            var accessGranted = false
            AVCaptureDevice.requestAccess(for: .video) { granted in
                accessGranted = granted
                authSema.signal()
            }
            // 给予用户充裕时间（最多 30 秒）点击确认
            _ = authSema.wait(timeout: .now() + 30.0)

            guard accessGranted else {
                fputs("[MacHello] 摄像头权限被拒绝，请在「系统设置 ➔ 隐私与安全性 ➔ 摄像头」中允许。\n", stderr)
                return false
            }
        } else if authStatus == .denied || authStatus == .restricted {
            fputs("[MacHello] 摄像头访问权限被拒绝，请在「系统设置 ➔ 隐私与安全性 ➔ 摄像头」中允许。\n", stderr)
            return false
        }

        // 确保退出时恢复 RGB，保护红外硬件
        defer {
            cleanup()
        }

        let isHardwareConnected = irController.isConnected
        let useIR = preferIR && isHardwareConnected

        fputs("[MacHello] 正在识别人脸...", stderr)
        fflush(stderr)

        do {
            if useIR {
                _ = irController.setMode(.ir)
                try cameraService.start(mode: .ir)
            } else {
                try cameraService.start(mode: .rgb)
            }
        } catch {
            fputs("\n[MacHello] 启动摄像头失败: \(error.localizedDescription)\n", stderr)
            return false
        }

        cameraService.delegate = self

        // 2. 超时定时器（权限已具备，此时正式开始人脸识别计时）
        let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
        if timeoutResult == .timedOut {
            lock.lock()
            isFinished = true
            lock.unlock()
            fputs("\n[MacHello] 人脸识别超时，退回密码验证\n", stderr)
            return false
        }

        if isAuthenticated {
            fputs(" ✓ 验证通过 (机主: \(profile.username))\n", stderr)
            return true
        } else {
            fputs("\n[MacHello] 人脸未匹配，退回密码验证\n", stderr)
            return false
        }
    }

    private func cleanup() {
        cameraService.stop()
        if irController.isConnected {
            irController.resetToRGB()
        }
    }

    // MARK: - CameraCaptureDelegate

    private var lastLitPixelBuffer: CVPixelBuffer?
    private var pendingMatch: (score: Float, box: CGRect)?

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        lock.lock()
        if isFinished || isAuthenticated {
            lock.unlock()
            return
        }
        lock.unlock()

        frameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if isIR {
            if frameCount % 2 == 0 && frameCount >= 2 {
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
                let liveness = AmbientSubtractionProcessor.shared.verifyLiveness(
                    lit: lit,
                    ambient: pixelBuffer,
                    faceBoundingBox: pending.box
                )

                if liveness.isLive {
                    AuthAuditLogger.shared.recordAuth(
                        pixelBuffer: lit,
                        reason: "terminal_sudo",
                        score: pending.score,
                        success: true
                    )
                    lock.lock()
                    isAuthenticated = true
                    isFinished = true
                    lock.unlock()
                    sema.signal()
                    return
                } else {
                    lastLitPixelBuffer = nil
                    pendingMatch = nil
                }
            }
        } else {
            let faces = extractor.extract(from: pixelBuffer)
            for face in faces {
                let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                if match.matched {
                    lock.lock()
                    isAuthenticated = true
                    isFinished = true
                    lock.unlock()
                    sema.signal()
                    return
                }
            }
        }
    }
}

// 解析命令行参数
var timeout: TimeInterval = 2.5
var preferIR = true

// 注册退出信号捕获，保证硬件安全复位
signal(SIGINT) { _ in
    CameraCaptureService.shared.stop()
    IRController.shared.resetToRGB()
    exit(130)
}
signal(SIGTERM) { _ in
    CameraCaptureService.shared.stop()
    IRController.shared.resetToRGB()
    exit(143)
}

var args = CommandLine.arguments.dropFirst()
while !args.isEmpty {
    let arg = args.removeFirst()
    if arg == "--timeout", let valStr = args.first, let val = Double(valStr) {
        timeout = val
        _ = args.removeFirst()
    } else if arg == "--rgb" {
        preferIR = false
    } else if arg == "--ir" {
        preferIR = true
    }
}

let auth = Authenticator()
auth.timeoutSeconds = timeout
auth.preferIR = preferIR

let success = auth.authenticate()
exit(success ? 0 : 1)

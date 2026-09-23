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
    private let lock = NSLock()

    var timeoutSeconds: TimeInterval = 2.5
    var preferIR: Bool = true

    func authenticate() -> Bool {
        guard faceDb.isEnrolled, let profile = faceDb.load() else {
            fputs("[MacHello] 未录入任何人脸特征，请先通过菜单或 MacHelloEnroll 录入\n", stderr)
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

        // 超时定时器
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

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        lock.lock()
        if isFinished || isAuthenticated {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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

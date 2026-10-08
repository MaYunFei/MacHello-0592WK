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
        // 0. 解析当前真实用户家目录与应用偏好设置（解决 sudo 提权下进程属主为 root 导致路径偏移与配置读取失败的问题）
        var homeDir = FileManager.default.homeDirectoryForCurrentUser
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
           let pw = getpwnam(sudoUser) {
            homeDir = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }

        var isNetworkMode = false
        var serverURL = "http://192.168.66.5:8765"

        let plistURL = homeDir.appendingPathComponent("Library/Preferences/com.machello.app.plist")
        if let plistData = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            isNetworkMode = plist["com.machello.isNetworkModeEnabled"] as? Bool ?? false
            if let url = plist["com.machello.linuxServerURL"] as? String, !url.isEmpty {
                serverURL = url
            }
        } else {
            let appDefaults = UserDefaults(suiteName: "com.machello.app") ?? UserDefaults.standard
            isNetworkMode = appDefaults.bool(forKey: "com.machello.isNetworkModeEnabled")
            if let url = appDefaults.string(forKey: "com.machello.linuxServerURL"), !url.isEmpty {
                serverURL = url
            }
        }

        if isNetworkMode {
            cameraService.isNetworkMode = true
            cameraService.networkServerURL = serverURL
        }

        guard faceDb.isEnrolled, let profile = faceDb.load() else {
            fputs("[MacHello] No enrolled face profile found. Please enroll via Menu or MacHelloEnroll.\n", stderr)
            return false
        }

        // 1. 本机摄像头模式下的权限预检（网络模式无需请求本地摄像头授权）
        if !isNetworkMode {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if authStatus == .notDetermined {
                fputs("[MacHello] First time running in this terminal, please allow camera access...\n", stderr)
                fflush(stderr)
                let authSema = DispatchSemaphore(value: 0)
                var accessGranted = false
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    accessGranted = granted
                    authSema.signal()
                }
                _ = authSema.wait(timeout: .now() + 30.0)

                guard accessGranted else {
                    fputs("[MacHello] Camera permission denied. Allow in System Settings -> Privacy & Security -> Camera.\n", stderr)
                    return false
                }
            } else if authStatus == .denied || authStatus == .restricted {
                fputs("[MacHello] Camera access denied. Allow in System Settings -> Privacy & Security -> Camera.\n", stderr)
                return false
            }
        }

        // 确保退出时恢复 RGB，保护红外硬件
        defer {
            cleanup()
        }

        let isHardwareConnected = irController.isConnected
        let useIR = isNetworkMode || (preferIR && isHardwareConnected)

        fputs("[MacHello] Verifying face...", stderr)
        fflush(stderr)

        cameraService.delegate = self

        do {
            if useIR {
                if !isNetworkMode {
                    _ = irController.setMode(.ir)
                }
                try cameraService.start(mode: .ir)
            } else {
                try cameraService.start(mode: .rgb)
            }
        } catch {
            fputs("\n[MacHello] Failed to start camera: \(error.localizedDescription)\n", stderr)
            return false
        }

        // 2. 超时定时器（权限已具备，此时正式开始人脸识别计时）
        let timeoutResult = sema.wait(timeout: .now() + timeoutSeconds)
        if timeoutResult == .timedOut {
            lock.lock()
            isFinished = true
            lock.unlock()
            fputs("\n[MacHello] Face recognition timed out, falling back to password.\n", stderr)
            return false
        }

        if isAuthenticated {
            fputs(" ✓ Verified (User: \(profile.username))\n", stderr)
            return true
        } else {
            fputs("\n[MacHello] Face not recognized, falling back to password.\n", stderr)
            return false
        }
    }

    private func cleanup() {
        cameraService.stop()
        if cameraService.isNetworkMode {
            // 双重安全防线：确保向 Linux 网关发送的熄灯复位请求确实完成，防止 CLI 进程退出导致连接被内核掐断
            let sem = DispatchSemaphore(value: 0)
            LinuxPresenceClient.shared.setIRMode(isIR: false) { _ in
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 1.5)
        } else if irController.isConnected {
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
            if cameraService.isNetworkMode {
                // 局域网模式：直接基于远程红外流进行机主特征核验与抓拍留存
                let faces = extractor.extract(from: pixelBuffer)
                for face in faces {
                    let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                    if match.matched {
                        AuthAuditLogger.shared.recordAuth(
                            pixelBuffer: pixelBuffer,
                            reason: "terminal_sudo",
                            score: match.highestScore,
                            success: true
                        )
                        lock.lock()
                        isAuthenticated = true
                        isFinished = true
                        lock.unlock()
                        sema.signal()
                        return
                    }
                }
            } else {
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
            }
        } else {
            let faces = extractor.extract(from: pixelBuffer)
            for face in faces {
                let match = faceDb.match(embedding: face.embedding, threshold: 0.58)
                if match.matched {
                    AuthAuditLogger.shared.recordAuth(
                        pixelBuffer: pixelBuffer,
                        reason: "terminal_sudo",
                        score: match.highestScore,
                        success: true
                    )
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
    if CameraCaptureService.shared.isNetworkMode {
        let sem = DispatchSemaphore(value: 0)
        LinuxPresenceClient.shared.setIRMode(isIR: false) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 1.0)
    } else {
        IRController.shared.resetToRGB()
    }
    exit(130)
}
signal(SIGTERM) { _ in
    CameraCaptureService.shared.stop()
    if CameraCaptureService.shared.isNetworkMode {
        let sem = DispatchSemaphore(value: 0)
        LinuxPresenceClient.shared.setIRMode(isIR: false) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 1.0)
    } else {
        IRController.shared.resetToRGB()
    }
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

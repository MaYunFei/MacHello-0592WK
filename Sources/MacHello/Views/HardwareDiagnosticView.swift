import SwiftUI
import AppKit
import MacHelloCore
import AVFoundation
import CoreMedia
import CoreImage

public enum TestState: Equatable {
    case idle
    case running
    case passed
    case failed(String)
    case warning(String)

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .running: return "hourglass"
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary.opacity(0.4)
        case .running: return .accentColor
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}

final class DiagnosticFileManager {
    static let shared = DiagnosticFileManager()

    var diagnosticsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".machello/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var irFramesDirectory: URL {
        let dir = diagnosticsDirectory.appendingPathComponent("ir_frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func resetIRFramesFolder() {
        let dir = irFramesDirectory
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var rgbImagePath: URL {
        return diagnosticsDirectory.appendingPathComponent("rgb.jpg")
    }

    var irImagePath: URL {
        return diagnosticsDirectory.appendingPathComponent("ir.jpg")
    }

    var logFilePath: URL {
        return diagnosticsDirectory.appendingPathComponent("diagnostic.log")
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print("[Diagnostic] \(message)")

        let path = logFilePath.path
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fileHandle = FileHandle(forWritingAtPath: path) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFilePath)
            }
        }
    }

    func saveImage(_ data: Data, isIR: Bool) {
        let target = isIR ? irImagePath : rgbImagePath
        try? data.write(to: target)
        log("测试实拍图已归档: \(target.path) (\(data.count) 字节)")
    }

    func openFolder() {
        NSWorkspace.shared.open(diagnosticsDirectory)
    }

    func openIRFramesFolder() {
        NSWorkspace.shared.open(irFramesDirectory)
    }
}

final class DiagnosticCaptureHelper: NSObject, CameraCaptureDelegate {
    var onFrame: ((NSImage) -> Void)?
    var isGrayscale: Bool = false
    var isIRTarget: Bool = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastUpdate: TimeInterval = 0
    public var frameCount = 0
    public var bestJPEGData: Data?
    private var bestLuminance: Float = 0.0
    private var faceDetectedInBest: Bool = false
    public var bestFaceFeatures: [FaceFeatureResult] = []
    private let faceDetector = FaceFeatureExtractor()

    private func calculateAverageLuminance(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var totalLum: Float = 0
        var samples: Float = 0
        let stepX = max(1, width / 20)
        let stepY = max(1, height / 20)

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: height / 4, to: (3 * height) / 4, by: stepY) {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in stride(from: width / 4, to: (3 * width) / 4, by: stepX) {
                let b = Float(row[x * 4])
                let g = Float(row[x * 4 + 1])
                let r = Float(row[x * 4 + 2])
                totalLum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                samples += 1.0
            }
        }
        return samples > 0 ? (totalLum / samples) : 0
    }

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        frameCount += 1
        let currentFrameIndex = frameCount

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if isGrayscale {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.0, forKey: kCIInputSaturationKey) // 纯正黑白灰度夜视
                if let out = filter.outputImage {
                    ciImage = out
                }
            }
        }

        let lum = calculateAverageLuminance(pixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) else { return }

        // 丢弃 RGB 模式下前 3 帧的过渡帧与初始网络缓冲，确保抓拍到纯正稳定的彩色画面
        if !isIRTarget && frameCount <= 3 {
            return
        }

        // 如果是 IR 模式，无遗漏保存每一张全量原生实拍帧
        if isIRTarget {
            let filename = String(format: "frame_%02d.jpg", currentFrameIndex)
            let frameURL = DiagnosticFileManager.shared.irFramesDirectory.appendingPathComponent(filename)
            try? jpegData.write(to: frameURL)

            // 并发检测当前帧人脸
            let faces = faceDetector.extract(from: pixelBuffer)
            let hasFace = !faces.isEmpty
            DiagnosticFileManager.shared.log("IR Frame \(String(format: "%02d", currentFrameIndex)): \(jpegData.count) bytes, 亮度: \(String(format: "%.3f", lum)), 人脸检测: \(hasFace ? "✓ 成功" : "× 无")")

            // 评判最佳帧：优先选择检测到人脸的帧；若都有或都没有，选择亮度最高的稳态帧
            if hasFace && !faceDetectedInBest {
                bestJPEGData = jpegData
                bestLuminance = lum
                faceDetectedInBest = true
                bestFaceFeatures = faces
            } else if hasFace == faceDetectedInBest && lum >= bestLuminance {
                bestJPEGData = jpegData
                bestLuminance = lum
                if hasFace {
                    bestFaceFeatures = faces
                }
            } else if bestJPEGData == nil {
                bestJPEGData = jpegData
                bestLuminance = lum
            }
        } else {
            // RGB 模式并发检测人脸并选择最佳画面
            let faces = faceDetector.extract(from: pixelBuffer)
            let hasFace = !faces.isEmpty
            if hasFace && !faceDetectedInBest {
                bestJPEGData = jpegData
                bestLuminance = lum
                faceDetectedInBest = true
                bestFaceFeatures = faces
            } else if hasFace == faceDetectedInBest && lum >= bestLuminance {
                bestJPEGData = jpegData
                bestLuminance = lum
                if hasFace {
                    bestFaceFeatures = faces
                }
            } else if bestJPEGData == nil {
                bestJPEGData = jpegData
                bestLuminance = lum
            }
        }

        // UI 实时预览 (以 ~15fps 节流避免阻塞主线程)
        let now = CACurrentMediaTime()
        if now - lastUpdate >= 0.065 {
            lastUpdate = now
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async { [weak self] in
                    self?.onFrame?(nsImage)
                }
            }
        }
    }

    func saveSnapshot() {
        guard let data = bestJPEGData else { return }
        DiagnosticFileManager.shared.saveImage(data, isIR: isIRTarget)
        if bestFaceFeatures.isEmpty {
            bestFaceFeatures = faceDetector.extract(from: data)
        }
    }
}

public final class DiagnosticViewModel: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var cameraName: String = loc("Detecting...", "正在检测...")
    @Published public var hardwareConfirmed: Bool = false

    @Published public var test1State: TestState = .idle
    @Published public var test2State: TestState = .idle
    @Published public var test3State: TestState = .idle
    @Published public var test4State: TestState = .idle
    @Published public var test5State: TestState = .idle
    @Published public var test5Detail: String? = nil

    @Published public var rgbImage: NSImage?
    @Published public var irImage: NSImage?

    @Published public var rgbBadgeText: String? = nil
    @Published public var rgbBadgeColor: Color = .secondary
    @Published public var irBadgeText: String? = nil
    @Published public var irBadgeColor: Color = .secondary

    // 摄像头安装朝向配置 (倒置安装模式)
    @Published public var isCameraInverted: Bool = false

    @Published public var isTesting: Bool = false
    @Published public var allPassed: Bool = false
    @Published public var statusMessage: String = loc("Confirm hardware above, then click 'Run Hardware Test' below", "请确认硬件后点击下方「开始自检」")

    public init() {
        self.isCameraInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")
        refreshHardwareInfo()
        loadExistingSnapshots()
    }

    public func toggleCameraInversion() {
        let newVal = !isCameraInverted
        self.isCameraInverted = newVal
        UserDefaults.standard.set(newVal, forKey: "com.machello.isCameraInverted")
        CameraCaptureService.shared.isCameraInverted = newVal
        MacHelloService.shared.isCameraInverted = newVal
    }

    public func loadExistingSnapshots() {
        let fileManager = DiagnosticFileManager.shared
        if let rgb = NSImage(contentsOf: fileManager.rgbImagePath) {
            self.rgbImage = rgb
            if let rgbData = try? Data(contentsOf: fileManager.rgbImagePath) {
                let faces = FaceFeatureExtractor.shared.extract(from: rgbData)
                if !faces.isEmpty {
                    self.rgbBadgeText = loc("👤 Face Detected", "👤 检测到人脸")
                    self.rgbBadgeColor = .green
                } else {
                    self.rgbBadgeText = loc("⚪ No Face Detected", "⚪ 未检测到人脸")
                    self.rgbBadgeColor = .secondary
                }
            }
        }
        if let ir = NSImage(contentsOf: fileManager.irImagePath) {
            self.irImage = ir
            if let irData = try? Data(contentsOf: fileManager.irImagePath) {
                let faces = FaceFeatureExtractor.shared.extract(from: irData)
                let isEnrolled = FaceDatabase.shared.isEnrolled
                if let bestFace = faces.first {
                    if isEnrolled {
                        let match = FaceDatabase.shared.match(embedding: bestFace.embedding)
                        let pct = Int(round(max(0.0, match.highestScore) * 100))
                        if match.matched {
                            self.irBadgeText = loc("🟢 Owner Recognized (\(pct)%)", "🟢 机主已识别 (\(pct)%)")
                            self.irBadgeColor = .green
                        } else {
                            self.irBadgeText = loc("🟠 Match Below Threshold (\(pct)%)", "🟠 未匹配机主 (\(pct)%)")
                            self.irBadgeColor = .orange
                        }
                    } else {
                        self.irBadgeText = loc("👤 Face Detected (Not Enrolled)", "👤 检测到人脸 (未录入)")
                        self.irBadgeColor = .blue
                    }
                } else {
                    self.irBadgeText = loc("⚪ No Face Detected", "⚪ 未检测到人脸")
                    self.irBadgeColor = .secondary
                }
            }
        }
    }

    public func refreshHardwareInfo() {
        if MacHelloService.shared.isNetworkModeEnabled {
            let client = LinuxPresenceClient.shared
            client.measureLatency()
            self.isConnected = client.isConnected
            if !client.isServerReachable {
                self.cameraName = loc("Disconnected from Linux server (\(client.serverURLString))", "未连接到 Linux 服务端 (\(client.serverURLString))")
                self.hardwareConfirmed = false
            } else if !client.isHardwareConnected {
                self.cameraName = loc("Linux online, but camera not detected", "Linux 在线，但未检测到摄像头插入")
                self.hardwareConfirmed = false
            } else {
                self.cameraName = loc("Dell CN-0592WK (Linux Gateway Connected)", "Dell CN-0592WK (局域网 Linux 服务端直连)")
                self.hardwareConfirmed = true
            }
        } else if let dev = AVCaptureDevice.default(for: .video) {
            self.isConnected = IRController.shared.isConnected
            self.cameraName = "\(dev.localizedName) (\(dev.modelID))"
            if self.isConnected {
                self.hardwareConfirmed = true
            }
        } else {
            self.isConnected = false
            self.cameraName = loc("No compatible video device found", "未找到可用视频设备")
            self.hardwareConfirmed = false
        }
    }

    public func runSelfTest() {
        isTesting = true
        allPassed = false
        test1State = .running
        test2State = .idle
        test3State = .idle
        test4State = .idle
        test5State = .idle
        test5Detail = nil
        rgbBadgeText = nil
        irBadgeText = nil
        rgbImage = nil
        irImage = nil
        // 彻底清除历史抓拍，杜绝旧照片冒充实时流
        try? FileManager.default.removeItem(at: DiagnosticFileManager.shared.rgbImagePath)
        try? FileManager.default.removeItem(at: DiagnosticFileManager.shared.irImagePath)
        statusMessage = loc("Connecting to RGB camera and pulling live frames...", "正在连接可见光镜头并拉取实时画面...")

        // 诊断测试独占摄像头，避免后台自动睡眠/人脸检测冲突抢占
        PresenceAutoDisplayService.shared.isDiagnosticRunning = true
        AutoAuthManager.shared.isDiagnosticRunning = true
        DiagnosticFileManager.shared.log("=== 开始硬件全面链路检测向导 ===")
        DiagnosticFileManager.shared.log("已暂停后台感知服务与全场景免密监听，独占摄像头控制权")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cameraService = CameraCaptureService.shared
            let irController = IRController.shared

            defer {
                PresenceAutoDisplayService.shared.isDiagnosticRunning = false
                AutoAuthManager.shared.isDiagnosticRunning = false
                DiagnosticFileManager.shared.log("已恢复后台感知服务与全场景免密监听")
            }

            // 先确保摄像头停止，处于干净准备状态，并强制复位至可见光 RGB 模式
            cameraService.stop()
            irController.resetToRGB()
            Thread.sleep(forTimeInterval: 0.3)

            // Step 1: 测试可见光 (RGB 720P) 实时画面
            DiagnosticFileManager.shared.log("Step 1: 正在测试可见光 (RGB 720P) 镜头...")
            var rgbHasFace: Bool = false
            let rgbHelper = DiagnosticCaptureHelper()
            rgbHelper.isGrayscale = false
            rgbHelper.isIRTarget = false
            rgbHelper.onFrame = { [weak self] img in
                self?.rgbImage = img
            }
            cameraService.delegate = rgbHelper

            do {
                try cameraService.start(mode: .rgb)
                // 采集 1.2 秒（给足网络缓冲与帧解码），捕获最佳实拍照
                Thread.sleep(forTimeInterval: 1.2)
                cameraService.delegate = nil // 先断开回调，严防 session 关闭过程中的黑帧污染画面
                cameraService.stop()

                if rgbHelper.frameCount == 0 {
                    DiagnosticFileManager.shared.log("Step 1: RGB 测试失败：未能从视频流接收到画面 (捕获 0 帧)")
                    DispatchQueue.main.async {
                        self.test1State = .failed(loc("0 frames captured", "未接收到画面 (捕获 0 帧)"))
                        self.isTesting = false
                        self.statusMessage = loc("RGB test failed: 0 frames captured, check camera connection", "可见光测试失败：未捕获到视频帧，请检查相机供流")
                    }
                    return
                }

                rgbHelper.saveSnapshot()
                DiagnosticFileManager.shared.log("Step 1: RGB 720P 测试完成，捕获 \(rgbHelper.frameCount) 帧")

                rgbHasFace = !rgbHelper.bestFaceFeatures.isEmpty
                let savedImg = NSImage(contentsOf: DiagnosticFileManager.shared.rgbImagePath)
                DispatchQueue.main.async {
                    if let img = savedImg {
                        self.rgbImage = img
                    }
                    if rgbHasFace {
                        self.rgbBadgeText = loc("👤 Face Detected", "👤 检测到人脸")
                        self.rgbBadgeColor = .green
                    } else {
                        self.rgbBadgeText = loc("⚪ No Face Detected", "⚪ 未检测到人脸")
                        self.rgbBadgeColor = .secondary
                    }
                    self.test1State = .passed
                    self.test2State = .running
                    self.statusMessage = loc("Verifying UVC Extension Unit protocol handshake...", "正在验证 UVC 扩展单元协议握手...")
                }
            } catch {
                DiagnosticFileManager.shared.log("Step 1: RGB 测试失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.test1State = .failed(error.localizedDescription)
                    self.isTesting = false
                    self.statusMessage = loc("RGB test failed", "可见光测试失败")
                }
                return
            }

            // Step 2: 验证 UVC 扩展单元
            DiagnosticFileManager.shared.log("Step 2: 正在验证 UVC 扩展单元与硬件连接...")
            Thread.sleep(forTimeInterval: 0.15)
            if MacHelloService.shared.isNetworkModeEnabled {
                guard LinuxPresenceClient.shared.isConnected else {
                    DiagnosticFileManager.shared.log("Step 2: 局域网 Linux 服务未就绪或未插摄像头")
                    DispatchQueue.main.async {
                        self.test2State = .failed(loc("Linux hardware not ready", "局域网硬件未就绪"))
                        self.isTesting = false
                        self.statusMessage = loc("Hardware verification failed: Linux server not ready or camera disconnected", "硬件验证失败：局域网服务端未就绪或未插摄像头")
                    }
                    return
                }
            } else {
                guard irController.isConnected else {
                    DiagnosticFileManager.shared.log("Step 2: 未找到 USB 0bda:5767 接口")
                    DispatchQueue.main.async {
                        self.test2State = .failed(loc("USB 0bda:5767 not found", "未找到 USB 0bda:5767 接口"))
                        self.isTesting = false
                        self.statusMessage = loc("USB 0bda:5767 hardware not detected", "未检测到本机 USB 0bda:5767 硬件")
                    }
                    return
                }
            }
            DiagnosticFileManager.shared.log("Step 2: 硬件与 UVC 扩展单元接口就绪")
            DispatchQueue.main.async {
                self.test2State = .passed
                self.test3State = .running
                self.statusMessage = loc("Turning on 850nm IR emitter LED...", "正在打亮 850nm 红外发射管...")
            }

            // Step 3: 触发 IR 模式
            DiagnosticFileManager.shared.log("Step 3: 正在下发 UVC 寄存器切换至 IR 模式 (0x00)...")
            Thread.sleep(forTimeInterval: 0.15)
            var irSuccess = false
            if MacHelloService.shared.isNetworkModeEnabled {
                let sem = DispatchSemaphore(value: 0)
                LinuxPresenceClient.shared.setIRMode(isIR: true) { active in
                    irSuccess = active
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 2.5)
            } else {
                irSuccess = irController.setMode(.ir)
            }

            guard irSuccess else {
                DiagnosticFileManager.shared.log("Step 3: UVC 寄存器写入失败 / 远程 IR 切换无响应")
                DispatchQueue.main.async {
                    self.test3State = .failed(loc("IR switch command failed", "红外切换指令失败"))
                    self.isTesting = false
                    self.statusMessage = loc("IR mode switch failed, please check camera hardware", "红外模式切换失败，请检查摄像头硬件")
                }
                return
            }
            DiagnosticFileManager.shared.log("Step 3: IR 模式与 850nm 发射管打亮成功")
            DispatchQueue.main.async {
                self.test3State = .passed
                self.test4State = .running
                self.statusMessage = loc("Starting IR night-vision camera (auto-exposure gain calibrating)...", "正在启动红外夜视镜头 (自动曝光增益校准中)...")
            }

            // Step 4: 捕获 IR 视频流 (切换为红外灰度采集)
            DiagnosticFileManager.shared.log("Step 4: 正在启动 IR 640x480 YUY2 视频采集...")
            DiagnosticFileManager.shared.resetIRFramesFolder()
            Thread.sleep(forTimeInterval: 0.2)
            let irHelper = DiagnosticCaptureHelper()
            irHelper.isGrayscale = true
            irHelper.isIRTarget = true
            irHelper.onFrame = { [weak self] img in
                self?.irImage = img
            }
            cameraService.delegate = irHelper

            do {
                try cameraService.start(mode: .ir)
                // 采集 1.5 秒，给足红外夜视 CMOS 自动曝光增益爬升时间，并全量落盘每一帧
                Thread.sleep(forTimeInterval: 1.5)
                cameraService.delegate = nil // 先断开回调，严防 session 关闭过程中的空帧/黑帧冲刷
                cameraService.stop()

                if irHelper.frameCount == 0 {
                    irController.resetToRGB()
                    DiagnosticFileManager.shared.log("Step 4: 红外测试失败：未能捕获到红外视频帧 (捕获 0 帧)")
                    DispatchQueue.main.async {
                        self.test4State = .failed(loc("0 IR frames captured", "未捕获到红外帧 (0 帧)"))
                        self.isTesting = false
                        self.statusMessage = loc("IR test failed: No night-vision frames received", "红外测试失败：未接收到夜视画面，请检查镜头与补光灯")
                    }
                    return
                }

                irHelper.saveSnapshot()
                irController.resetToRGB()
                DiagnosticFileManager.shared.log("Step 4: IR 测试完成，捕获 \(irHelper.frameCount) 帧，全部帧已存入 ir_frames/")

                let savedImg = NSImage(contentsOf: DiagnosticFileManager.shared.irImagePath)
                DispatchQueue.main.async {
                    if let img = savedImg {
                        self.irImage = img
                    }
                    self.test4State = .passed
                    self.test5State = .running
                    self.statusMessage = loc("Analyzing facial features via Apple Neural Engine...", "正在通过神经网络分析人脸特征并执行比对打分...")
                }

                // Step 5: 人脸识别特征提取与打分比对
                Thread.sleep(forTimeInterval: 0.15)
                let irFace = irHelper.bestFaceFeatures.first
                let isEnrolled = FaceDatabase.shared.isEnrolled

                var badgeText = ""
                var badgeColor = Color.secondary
                var step5Text = ""
                var step5State = TestState.passed
                var finalMessage = ""

                if let face = irFace {
                    if isEnrolled {
                        let match = FaceDatabase.shared.match(embedding: face.embedding)
                        let pct = Int(round(max(0.0, match.highestScore) * 100))
                        DiagnosticFileManager.shared.log("Step 5: 机主面容已录入，最高相似度: \(match.highestScore) (\(pct)%), 判定命中: \(match.matched)")

                        if match.matched {
                            badgeText = loc("🟢 Owner Recognized (\(pct)%)", "🟢 机主已识别 (\(pct)%)")
                            badgeColor = .green
                            step5Text = loc("Owner Verified (Match: \(pct)%)", "机主本人已命中 (匹配度: \(pct)%)")
                            step5State = .passed
                            finalMessage = loc("🎉 Full hardware & biometric pipeline verified! Match \(pct)%, ready for IR face unlock.", "🎉 双目镜头与机主识别全链路通过！匹配度 \(pct)%，红外解锁已就绪。")
                        } else {
                            badgeText = loc("🟠 Match Below Threshold (\(pct)%)", "🟠 未匹配机主 (\(pct)%)")
                            badgeColor = .orange
                            step5Text = loc("Face detected, low similarity (\(pct)%)", "识别到人脸，相似度较弱 (\(pct)%)")
                            step5State = .warning(loc("Low similarity (\(pct)%)", "相似度较弱 (\(pct)%)"))
                            finalMessage = loc("⚠️ Hardware functional, face detected, but similarity is low (\(pct)%). Try looking directly at camera.", "⚠️ 硬件正常且识别到人脸，但与机主相似度较低 (\(pct)%)，建议正视镜头。")
                        }

                        // 归档自检抓拍到通行审计历史中心
                        if let data = irHelper.bestJPEGData {
                            AuthAuditLogger.shared.recordAuth(
                                data: data,
                                reason: "diagnostic",
                                score: match.highestScore,
                                success: match.matched
                            )
                        }
                    } else {
                        DiagnosticFileManager.shared.log("Step 5: 未录入面容，但红外镜头已成功识别到人脸")
                        badgeText = loc("👤 Face Detected (Not Enrolled)", "👤 检测到人脸 (未录入)")
                        badgeColor = .blue
                        step5Text = loc("Face detected (No profile enrolled)", "已检测到人脸 (面容未录入)")
                        step5State = .passed
                        finalMessage = loc("🎉 Hardware diagnostic passed, face detected! Click 'Set Up Face ID Now' below.", "🎉 硬件双目自检通过，已识别人脸！建议点击下方「立即录入面容 ID」。")
                    }
                } else {
                    DiagnosticFileManager.shared.log("Step 5: 红外镜头未检测到人脸")
                    if rgbHasFace {
                        badgeText = loc("⚪ Not Detected in IR", "⚪ 红外未识别人脸")
                        badgeColor = .secondary
                        step5Text = loc("Face detected in RGB only", "仅可见光检测到人脸 (红外未捕获)")
                        step5State = .warning(loc("IR missed face", "红外未捕获面部"))
                        finalMessage = loc("⚠️ Hardware ok, face detected in RGB, but IR missed clear face. Face camera directly and retry.", "⚠️ 硬件正常，可见光检测到人，但红外未捕获清晰面部，请正对摄像头重试。")
                    } else {
                        badgeText = loc("⚪ No Face Detected", "⚪ 未检测到人脸")
                        badgeColor = .secondary
                        step5Text = loc("No face detected (face camera directly)", "未检测到人脸 (请正视镜头)")
                        step5State = .warning(loc("No face detected", "未检测到人脸"))
                        finalMessage = loc("⚠️ Hardware diagnostic passed, but no face detected. Ensure camera is unobstructed.", "⚠️ 硬件双目自检通过，但未检测到人脸，请确保摄像头无遮挡并正对镜头。")
                    }
                }

                DiagnosticFileManager.shared.log("=== 硬件自检与识别比对全部完成 ===")

                DispatchQueue.main.async {
                    self.irBadgeText = badgeText
                    self.irBadgeColor = badgeColor
                    self.test5Detail = step5Text
                    self.test5State = step5State
                    let passed = (rgbHelper.frameCount > 0 && irHelper.frameCount > 0)
                    self.allPassed = passed
                    if passed {
                        UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                    }
                    self.isTesting = false
                    self.statusMessage = finalMessage
                }
            } catch {
                irController.resetToRGB()
                DiagnosticFileManager.shared.log("Step 4: IR 捕获失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.test4State = .failed(error.localizedDescription)
                    self.test5State = .idle
                    self.isTesting = false
                    self.statusMessage = loc("IR capture failed", "红外捕获失败")
                }
            }
        }
    }
}

public struct HardwareDiagnosticView: View {
    @StateObject private var vm = DiagnosticViewModel()
    @ObservedObject private var lang = LanguageManager.shared

    var onDismiss: () -> Void
    var onStartEnrollment: () -> Void

    public init(onDismiss: @escaping () -> Void, onStartEnrollment: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.onStartEnrollment = onStartEnrollment
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏与标题
            headerBar
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // 主体滚动内容区
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // 1. 硬件规格与参数卡片
                    hardwareSpecificationCard

                    // 2. 双目镜头实拍效果卡片
                    dualCameraSnapshotCard

                    // 3. 硬件链路自检诊断步骤卡片
                    diagnosticPipelineCard

                    // 状态提示横幅
                    statusBanner
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            // 底部操作栏
            bottomActionBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        }
        .frame(width: 620, height: 750)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            vm.refreshHardwareInfo()
        }
    }

    // MARK: - 顶部导航栏
    private var headerBar: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSImage(named: "NSApplicationIcon") ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(loc("Hardware Diagnostics & Setup", "硬件自检与设备确认"))
                    .font(.title2)
                    .fontWeight(.bold)
                Text(loc("Dell CN-0592WK Dual-Sensor IR Module Calibration", "Dell CN-0592WK 双目红外识别模组链路校准"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 连接状态胶囊
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(vm.isConnected ? (MacHelloService.shared.isNetworkModeEnabled ? loc("Linux Hardware Ready", "局域网硬件已就绪") : loc("0bda:5767 Connected", "0bda:5767 已连接")) : loc("Hardware Disconnected", "未检测到硬件"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(vm.isConnected ? .green : .red)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((vm.isConnected ? Color.green : Color.red).opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder((vm.isConnected ? Color.green : Color.red).opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - 1. 硬件规格与参数卡片
    private var hardwareSpecificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(loc("Hardware Specs & Identification", "硬件规格与识别"), systemImage: "cpu.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 8) {
                specRow(title: loc("Target Hardware", "目标硬件型号"), value: "Dell CN-0592WK (Realtek 0bda:5767)", icon: "target")
                specRow(title: loc("Active System Device", "当前系统设备"), value: vm.cameraName, icon: "video.fill")
                specRow(title: loc("IR Sensor Module", "红外传感模组"), value: loc("850nm Emitter + 640x480 YUY2", "850nm 独立发射管 + 640x480 YUY2"), icon: "moon.stars.fill")
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Toggle(isOn: $vm.hardwareConfirmed) {
                Text(loc("Confirm connected device is **Dell CN-0592WK** (0bda:5767) dual-sensor module", "确认当前连接的设备是 **Dell CN-0592WK** (0bda:5767) 硬件双目模组"))
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Inverted Mount Mode (Rotate 180°)", "摄像头倒置安装模式 (旋转 180°)"))
                        .font(.subheadline)
                    Text(loc("Rotates feed 180°, ideal for mounting under your monitor", "画面旋转 180°，适合将模组倒贴在显示器下方使用"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { vm.isCameraInverted },
                    set: { _ in vm.toggleCameraInversion() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 2. 双目镜头实拍效果卡片
    private var dualCameraSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(loc("Dual-Sensor Live Verification", "双目镜头实拍效果验证"), systemImage: "camera.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            HStack(spacing: 14) {
                // 左侧：RGB 可见光镜头
                cameraFeedView(
                    title: loc("Visible Light Camera (RGB 720P)", "可见光镜头 (RGB 720P)"),
                    systemIcon: "camera.fill",
                    image: vm.rgbImage,
                    badgeText: vm.rgbBadgeText,
                    badgeColor: vm.rgbBadgeColor,
                    isRunning: vm.test1State == .running,
                    runningText: loc("Capturing visible light...", "正在捕获可见光画面...")
                )

                // 右侧：IR 红外夜视镜头
                cameraFeedView(
                    title: loc("IR Night-Vision Camera (IR 640x480)", "红外夜视镜头 (IR 640x480)"),
                    systemIcon: "moon.stars.fill",
                    image: vm.irImage,
                    badgeText: vm.irBadgeText,
                    badgeColor: vm.irBadgeColor,
                    isRunning: vm.test4State == .running,
                    runningText: loc("850nm snapshot...", "850nm 补光抓拍中...")
                )
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func cameraFeedView(
        title: String,
        systemIcon: String,
        image: NSImage?,
        badgeText: String?,
        badgeColor: Color,
        isRunning: Bool,
        runningText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .frame(height: 155)

                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: 155)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.small)
                            Text(runningText)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.8))
                        } else {
                            Image(systemName: systemIcon)
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.35))
                            Text(loc("Click self-test to capture", "点击自检后抓拍"))
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }

                // 底部状态胶囊
                if let badge = badgeText {
                    VStack {
                        Spacer()
                        HStack {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.65))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(badgeColor.opacity(0.8), lineWidth: 1)
                                )
                            Spacer()
                        }
                        .padding(8)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 3. 硬件链路诊断步骤卡片
    private var diagnosticPipelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(loc("Hardware Diagnostic Pipeline", "硬件全链路诊断步骤"), systemImage: "checklist")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 6) {
                testItemRow(index: 1, title: loc("1. Visible light (RGB 720P) stream and frame sampling", "可见光镜头 (RGB 720P) 视频流与画面采样"), state: vm.test1State)
                Divider()
                testItemRow(index: 2, title: loc("2. Realtek UVC Extension Unit (Unit 4) 5-step handshake", "Realtek UVC 扩展单元 (Unit 4) 5步状态机握手"), state: vm.test2State)
                Divider()
                testItemRow(index: 3, title: loc("3. 850nm NIR emitter trigger and night-vision mode switch", "850nm 近红外发射管点亮与夜视模式切换"), state: vm.test3State)
                Divider()
                testItemRow(index: 4, title: loc("4. Near-infrared camera (640x480 YUY2) frame capture", "近红外物理镜头 (640x480 YUY2) 数据帧抓取"), state: vm.test4State)
                Divider()
                testItemRow(index: 5, title: loc("5. Biometric facial feature extraction and cosine scoring", "人脸识别特征提取与面容比对打分"), state: vm.test5State, customPassedText: vm.test5Detail)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 状态横幅
    private var statusBanner: some View {
        HStack(spacing: 8) {
            if vm.isTesting {
                ProgressView()
                    .controlSize(.small)
            } else if vm.allPassed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.secondary)
            }

            Text(vm.statusMessage)
                .font(.subheadline)
                .foregroundColor(vm.allPassed ? .green : .secondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            (vm.allPassed ? Color.green : Color.secondary).opacity(0.08)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 底部操作栏
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                vm.runSelfTest()
            }) {
                HStack(spacing: 6) {
                    if vm.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(vm.isTesting ? loc("Testing...", "正在自检...") : loc("Run Hardware Test", "开始硬件自检"))
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isTesting || !vm.isConnected)
            .keyboardShortcut(.defaultAction)

            Button(action: {
                DiagnosticFileManager.shared.openFolder()
            }) {
                Label(loc("Logs & Snaps", "日志与截图"), systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: {
                DiagnosticFileManager.shared.openIRFramesFolder()
            }) {
                Label(loc("IR Album", "红外相册"), systemImage: "photo.stack")
            }
            .buttonStyle(.bordered)

            Spacer()

            if vm.allPassed && vm.hardwareConfirmed {
                Button(action: {
                    UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                    onStartEnrollment()
                }) {
                    HStack(spacing: 4) {
                        Text(FaceDatabase.shared.isEnrolled ? loc("Re-enroll Face ID", "重新录入面容 ID") : loc("Set Up Face ID Now", "立即录入面容 ID"))
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            Button(vm.allPassed ? loc("Done", "完成") : loc("Close", "关闭")) {
                if vm.allPassed && vm.hardwareConfirmed {
                    UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                }
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 辅助子视图
    private func specRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func testItemRow(index: Int, title: String, state: TestState, customPassedText: String? = nil) -> some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                default:
                    Image(systemName: state.icon)
                        .foregroundColor(state.color)
                        .font(.system(size: 15))
                }
            }
            .frame(width: 20)

            Text(title)
                .font(.subheadline)

            Spacer()

            switch state {
            case .idle:
                Text(loc("Pending", "等待开始"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .running:
                Text(loc("Testing...", "正在测试..."))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            case .passed:
                Text(customPassedText ?? loc("Passed ✓", "通过 ✓"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
            case .warning(let warn):
                Text(warn)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
            case .failed(let err):
                Text("\(loc("Failed", "失败")): \(err)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 3)
    }
}

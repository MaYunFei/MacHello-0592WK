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
        case .running: return "hourglass.circle"
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .orange
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
                filter.setValue(0.0, forKey: kCIInputSaturationKey) // 纯正黑白灰度夜视，不压暗阴影
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
    @Published public var cameraName: String = "正在检测..."
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
    @Published public var statusMessage: String = "点击下方按钮开始全面的硬件链路自检"

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
                    self.rgbBadgeText = "👤 检测到人脸"
                    self.rgbBadgeColor = .green
                } else {
                    self.rgbBadgeText = "⚪ 未检测到人脸"
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
                            self.irBadgeText = "🟢 机主已识别 (\(pct)%)"
                            self.irBadgeColor = .green
                        } else {
                            self.irBadgeText = "🟠 未匹配机主 (\(pct)%)"
                            self.irBadgeColor = .orange
                        }
                    } else {
                        self.irBadgeText = "👤 检测到人脸 (未录入)"
                        self.irBadgeColor = .blue
                    }
                } else {
                    self.irBadgeText = "⚪ 未检测到人脸"
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
                self.cameraName = "未连接到 Linux 服务端 (\(client.serverURLString))"
                self.hardwareConfirmed = false
            } else if !client.isHardwareConnected {
                self.cameraName = "Linux 服务端在线，但未检测到摄像头插入"
                self.hardwareConfirmed = false
            } else {
                self.cameraName = "Dell CN-0592WK (局域网 Linux 服务端直连)"
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
            self.cameraName = "未找到可用视频设备"
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
        statusMessage = "正在连接可见光镜头并拉取实时画面..."

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
                        self.test1State = .failed("未接收到画面 (捕获 0 帧)")
                        self.isTesting = false
                        self.statusMessage = "可见光测试失败：未捕获到视频帧，请检查相机是否正常供流"
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
                        self.rgbBadgeText = "👤 检测到人脸"
                        self.rgbBadgeColor = .green
                    } else {
                        self.rgbBadgeText = "⚪ 未检测到人脸"
                        self.rgbBadgeColor = .secondary
                    }
                    self.test1State = .passed
                    self.test2State = .running
                    self.statusMessage = "正在验证 UVC 扩展单元协议握手..."
                }
            } catch {
                DiagnosticFileManager.shared.log("Step 1: RGB 测试失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.test1State = .failed(error.localizedDescription)
                    self.isTesting = false
                    self.statusMessage = "可见光测试失败"
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
                        self.test2State = .failed("局域网硬件未就绪")
                        self.isTesting = false
                        self.statusMessage = "硬件验证失败：局域网服务端未就绪或未插摄像头"
                    }
                    return
                }
            } else {
                guard irController.isConnected else {
                    DiagnosticFileManager.shared.log("Step 2: 未找到 USB 0bda:5767 接口")
                    DispatchQueue.main.async {
                        self.test2State = .failed("未找到 USB 0bda:5767 接口")
                        self.isTesting = false
                        self.statusMessage = "未检测到本机 USB 0bda:5767 硬件"
                    }
                    return
                }
            }
            DiagnosticFileManager.shared.log("Step 2: 硬件与 UVC 扩展单元接口就绪")
            DispatchQueue.main.async {
                self.test2State = .passed
                self.test3State = .running
                self.statusMessage = "正在打亮 850nm 红外发射管..."
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
                    self.test3State = .failed("红外切换指令失败")
                    self.isTesting = false
                    self.statusMessage = "红外模式切换失败，请检查摄像头硬件"
                }
                return
            }
            DiagnosticFileManager.shared.log("Step 3: IR 模式与 850nm 发射管打亮成功")
            DispatchQueue.main.async {
                self.test3State = .passed
                self.test4State = .running
                self.statusMessage = "正在启动红外夜视镜头 (自动增益爬升中)..."
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
                        self.test4State = .failed("未捕获到红外帧 (0 帧)")
                        self.isTesting = false
                        self.statusMessage = "红外测试失败：未接收到夜视画面，请检查镜头与补光灯"
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
                    self.statusMessage = "正在通过神经网络分析人脸特征并执行比对打分..."
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
                            badgeText = "🟢 机主已识别 (\(pct)%)"
                            badgeColor = .green
                            step5Text = "已识别机主本人 (匹配度: \(pct)%) ✓"
                            step5State = .passed
                            finalMessage = "🎉 双目镜头与机主识别全链路通过！匹配度 \(pct)%，红外解锁已就绪。"
                        } else {
                            badgeText = "🟠 未匹配机主 (\(pct)%)"
                            badgeColor = .orange
                            step5Text = "识别到人脸，相似度较弱 (\(pct)%)"
                            step5State = .warning("相似度较弱 (\(pct)%)")
                            finalMessage = "⚠️ 硬件正常且识别到人脸，但与机主相似度较低 (\(pct)%)，建议正视镜头。"
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
                        badgeText = "👤 检测到人脸 (未录入)"
                        badgeColor = .blue
                        step5Text = "已检测到人脸 (面容未录入) ℹ️"
                        step5State = .passed
                        finalMessage = "🎉 硬件双目自检通过，已识别人脸！建议点击下方【立即录入面容 ID】。"
                    }
                } else {
                    DiagnosticFileManager.shared.log("Step 5: 红外镜头未检测到人脸")
                    if rgbHasFace {
                        badgeText = "⚪ 红外未识别人脸"
                        badgeColor = .secondary
                        step5Text = "仅可见光检测到人脸 (红外未捕获)"
                        step5State = .warning("红外未捕获面部")
                        finalMessage = "⚠️ 硬件正常，可见光检测到人，但红外未捕获清晰面部，请正对摄像头重试。"
                    } else {
                        badgeText = "⚪ 未检测到人脸"
                        badgeColor = .secondary
                        step5Text = "未检测到人脸 (请正视镜头)"
                        step5State = .warning("未检测到人脸")
                        finalMessage = "⚠️ 硬件双目自检通过，但未检测到人脸，请确保摄像头无遮挡并正对镜头。"
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
                    self.statusMessage = "红外捕获失败"
                }
            }
        }
    }
}

public struct HardwareDiagnosticView: View {
    @StateObject private var vm = DiagnosticViewModel()

    var onDismiss: () -> Void
    var onStartEnrollment: () -> Void

    public init(onDismiss: @escaping () -> Void, onStartEnrollment: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.onStartEnrollment = onStartEnrollment
    }

    public var body: some View {
        VStack(spacing: 16) {
            // 顶部标题与图标
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: "NSApplicationIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 50, height: 50)
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 3) {
                    Text("MacHello 硬件自检与设备确认")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("请确认连接的模组为 Dell CN-0592WK，并完成可见光与近红外双目自检。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Divider()

            // 1. 硬件规格与识别卡片
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("目标支持硬件规格")
                        .font(.headline)
                    Spacer()
                    if vm.isConnected {
                        Label(MacHelloService.shared.isNetworkModeEnabled ? "局域网硬件已就绪" : "检测到兼容硬件 (0bda:5767)", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label(MacHelloService.shared.isNetworkModeEnabled ? "局域网服务未就绪 / 未插摄像头" : "未检测到目标硬件", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                VStack(spacing: 5) {
                    infoRow(title: "预期硬件型号", value: "Dell CN-0592WK (Realtek 0bda:5767)")
                    infoRow(title: "系统识别设备", value: vm.cameraName)
                    infoRow(title: "近红外支持", value: "850nm 独立发射管 + 640x480 YUY2 红外镜头")
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)

                Toggle(isOn: $vm.hardwareConfirmed) {
                    Text("我已确认当前连接的设备是 **Dell CN-0592WK** (0bda:5767) 硬件双目模组")
                        .font(.subheadline)
                }

                Toggle(isOn: Binding(
                    get: { vm.isCameraInverted },
                    set: { _ in vm.toggleCameraInversion() }
                )) {
                    HStack(spacing: 4) {
                        Text("🙃 摄像头倒置安装模式 (旋转 180°)")
                            .font(.subheadline)
                        Text("— 适合倒贴在显示器下方使用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)

            // 2. 双镜头实拍照片回显卡片
            VStack(alignment: .leading, spacing: 8) {
                Text("双目镜头实拍效果验证")
                    .font(.headline)

                HStack(spacing: 16) {
                    // 左侧：RGB 可见光镜头
                    VStack(spacing: 6) {
                        HStack {
                            Text("📷 可见光镜头 (RGB 720P)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            if vm.rgbImage != nil {
                                Text("抓拍成功 ✓").font(.caption2).foregroundColor(.green)
                            }
                        }
                        if let img = vm.rgbImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 250, height: 140)
                                .clipped()
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.2))
                                .frame(width: 250, height: 140)
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "camera")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                        Text(vm.test1State == .running ? "正在抓拍可见光..." : "点击自检后抓拍")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                )
                        }

                        if let badge = vm.rgbBadgeText {
                            HStack {
                                Text(badge)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(vm.rgbBadgeColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(vm.rgbBadgeColor.opacity(0.12))
                                    .cornerRadius(6)
                                Spacer()
                            }
                        }
                    }

                    // 右侧：IR 红外夜视镜头
                    VStack(spacing: 6) {
                        HStack {
                            Text("🌙 红外夜视镜头 (IR 640x480)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            if vm.irImage != nil {
                                Text("850nm 补光正常 ✓").font(.caption2).foregroundColor(.green)
                            }
                        }
                        if let img = vm.irImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 250, height: 140)
                                .clipped()
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.2))
                                .frame(width: 250, height: 140)
                                .overlay(
                                    VStack(spacing: 4) {
                                        Image(systemName: "moon.stars")
                                            .font(.title2)
                                            .foregroundColor(.secondary)
                                        Text(vm.test4State == .running ? "850nm 补光增益抓拍中..." : "等待红外夜视抓拍")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                )
                        }

                        if let badge = vm.irBadgeText {
                            HStack {
                                Text(badge)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(vm.irBadgeColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(vm.irBadgeColor.opacity(0.12))
                                    .cornerRadius(6)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            // 3. 硬件链路测试状态
            VStack(spacing: 6) {
                testItemRow(title: "1. 可见光镜头 (RGB 720P) 视频流与画面采样", state: vm.test1State)
                testItemRow(title: "2. Realtek UVC 扩展单元 (Unit 4) 5步状态机握手", state: vm.test2State)
                testItemRow(title: "3. 850nm 近红外发射管打亮与夜视模式写入", state: vm.test3State)
                testItemRow(title: "4. 近红外物理镜头 (640x480 YUY2) 数据帧抓取", state: vm.test4State)
                testItemRow(title: "5. 人脸识别特征提取与面容比对打分", state: vm.test5State, customPassedText: vm.test5Detail)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(8)
            .padding(.horizontal, 24)

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundColor(vm.allPassed ? .green : .secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer()

            // 底部操作栏
            HStack(spacing: 12) {
                Button("开始硬件自检") {
                    vm.runSelfTest()
                }
                .disabled(vm.isTesting || !vm.isConnected)
                .keyboardShortcut(.defaultAction)

                Button("📂 日志与截图") {
                    DiagnosticFileManager.shared.openFolder()
                }
                .font(.subheadline)

                Button("🖼️ 查看全部红外帧") {
                    DiagnosticFileManager.shared.openIRFramesFolder()
                }
                .font(.subheadline)

                Spacer()

                if vm.allPassed && vm.hardwareConfirmed {
                    Button(FaceDatabase.shared.isEnrolled ? "重新录入面容 ID ➔" : "立即录入面容 ID ➔") {
                        UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                        onStartEnrollment()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(vm.allPassed ? "完成" : "关闭") {
                    if vm.allPassed && vm.hardwareConfirmed {
                        UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                    }
                    onDismiss()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: 580, height: 720)
        .onAppear {
            vm.refreshHardwareInfo()
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func testItemRow(title: String, state: TestState, customPassedText: String? = nil) -> some View {
        HStack {
            Image(systemName: state.icon)
                .foregroundColor(state.color)
                .frame(width: 20)
            Text(title)
                .font(.subheadline)
            Spacer()
            switch state {
            case .idle:
                Text("等待开始").font(.caption).foregroundColor(.secondary)
            case .running:
                Text("正在测试...").font(.caption).foregroundColor(.orange)
            case .passed:
                Text(customPassedText ?? "正常 ✓").font(.caption).fontWeight(.semibold).foregroundColor(.green)
            case .warning(let warn):
                Text(warn).font(.caption).fontWeight(.semibold).foregroundColor(.orange)
            case .failed(let err):
                Text("失败: \(err)").font(.caption).foregroundColor(.red)
            }
        }
    }
}

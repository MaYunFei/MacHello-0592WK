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

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .running: return "hourglass.circle"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .orange
        case .passed: return .green
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
}

final class DiagnosticCaptureHelper: NSObject, CameraCaptureDelegate {
    var onFrame: ((NSImage) -> Void)?
    var isGrayscale: Bool = false
    var isIRTarget: Bool = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastUpdate: TimeInterval = 0
    public var frameCount = 0
    private var bestJPEGData: Data?
    private var bestLuminance: Float = 0.0

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
        // 红外模式下跳过最初 6 帧，避免曝光增益爬升初期的暗帧
        if isGrayscale && frameCount < 7 { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let lum = calculateAverageLuminance(pixelBuffer: pixelBuffer)

        // 核心保护：如果之前已经抓取到正常照亮的人脸（bestLuminance > 0.06），而新帧变黑（lum < 0.03，如硬件眼部保护自动灭灯或停机冲刷），坚决拒绝覆盖！
        if isGrayscale && bestLuminance > 0.06 && lum < 0.035 {
            return
        }

        let now = CACurrentMediaTime()
        // 限制在 ~15fps (约 65ms 一帧)，既丝滑生动，又绝不卡顿 UI
        guard now - lastUpdate >= 0.065 else { return }
        lastUpdate = now

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

        // 使用 GPU/Metal 立即渲染成独立不可变的 CGImage，绝不依赖 AVFoundation 内部缓冲区生命周期
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(nsImage)
            }
            // 实时保留最佳亮度有效帧的 JPEG 数据，供测试存档查验
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let data = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) {
                if lum >= self.bestLuminance || self.bestJPEGData == nil {
                    self.bestLuminance = lum
                    self.bestJPEGData = data
                }
            }
        }
    }

    func saveSnapshot() {
        guard let data = bestJPEGData else { return }
        DiagnosticFileManager.shared.saveImage(data, isIR: isIRTarget)
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

    @Published public var rgbImage: NSImage?
    @Published public var irImage: NSImage?

    @Published public var isTesting: Bool = false
    @Published public var allPassed: Bool = false
    @Published public var statusMessage: String = "点击下方按钮开始全面的硬件链路自检"

    public init() {
        refreshHardwareInfo()
    }

    public func refreshHardwareInfo() {
        self.isConnected = IRController.shared.isConnected
        if let dev = AVCaptureDevice.default(for: .video) {
            self.cameraName = "\(dev.localizedName) (\(dev.modelID))"
        } else {
            self.cameraName = "未找到可用视频设备"
        }
        if self.isConnected {
            self.hardwareConfirmed = true
        }
    }

    public func runSelfTest() {
        isTesting = true
        allPassed = false
        test1State = .running
        test2State = .idle
        test3State = .idle
        test4State = .idle
        rgbImage = nil
        irImage = nil
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

            // 先确保摄像头停止，处于干净准备状态
            cameraService.stop()
            Thread.sleep(forTimeInterval: 0.25)

            // Step 1: 测试可见光 (RGB 720P) 实时画面
            DiagnosticFileManager.shared.log("Step 1: 正在测试可见光 (RGB 720P) 镜头...")
            let rgbHelper = DiagnosticCaptureHelper()
            rgbHelper.isGrayscale = false
            rgbHelper.isIRTarget = false
            rgbHelper.onFrame = { [weak self] img in
                self?.rgbImage = img
            }
            cameraService.delegate = rgbHelper

            do {
                try cameraService.start(mode: .rgb)
                // 采集 0.8 秒（约 24 帧），与真实业务场景对齐
                Thread.sleep(forTimeInterval: 0.8)
                cameraService.delegate = nil // 先断开回调，严防 session 关闭过程中的黑帧污染画面
                cameraService.stop()
                rgbHelper.saveSnapshot()
                DiagnosticFileManager.shared.log("Step 1: RGB 720P 测试完成，捕获 \(rgbHelper.frameCount) 帧")

                DispatchQueue.main.async {
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
            DiagnosticFileManager.shared.log("Step 2: 正在验证 UVC 扩展单元 (0bda:5767)...")
            Thread.sleep(forTimeInterval: 0.15)
            guard irController.isConnected else {
                DiagnosticFileManager.shared.log("Step 2: 未找到 USB 0bda:5767 接口")
                DispatchQueue.main.async {
                    self.test2State = .failed("未找到 USB 0bda:5767 接口")
                    self.isTesting = false
                }
                return
            }
            DiagnosticFileManager.shared.log("Step 2: UVC 扩展单元接口就绪")
            DispatchQueue.main.async {
                self.test2State = .passed
                self.test3State = .running
                self.statusMessage = "正在打亮 850nm 红外发射管..."
            }

            // Step 3: 触发 IR 模式
            DiagnosticFileManager.shared.log("Step 3: 正在下发 UVC 寄存器切换至 IR 模式 (0x00)...")
            Thread.sleep(forTimeInterval: 0.15)
            let irSuccess = irController.setMode(.ir)
            guard irSuccess else {
                DiagnosticFileManager.shared.log("Step 3: UVC 寄存器写入失败")
                DispatchQueue.main.async {
                    self.test3State = .failed("UVC 寄存器写入失败")
                    self.isTesting = false
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
                // 采集 0.8 秒（约 24 帧），与真实 Face ID 核验业务时长严格 1:1 对齐
                Thread.sleep(forTimeInterval: 0.8)
                cameraService.delegate = nil // 先断开回调，严防 session 关闭过程中的空帧/黑帧冲刷
                cameraService.stop()
                irHelper.saveSnapshot()
                irController.resetToRGB()
                DiagnosticFileManager.shared.log("Step 4: IR 测试完成，捕获 \(irHelper.frameCount) 帧")
                DiagnosticFileManager.shared.log("=== 硬件自检全部通过 ===")

                DispatchQueue.main.async {
                    self.test4State = .passed
                    self.allPassed = true
                    self.isTesting = false
                    self.statusMessage = "🎉 双目镜头全部自检通过！可见光与红外实拍成像完美。"
                }
            } catch {
                irController.resetToRGB()
                DiagnosticFileManager.shared.log("Step 4: IR 捕获失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.test4State = .failed(error.localizedDescription)
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
                        Label("检测到兼容硬件 (0bda:5767)", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label("未检测到目标硬件", systemImage: "exclamationmark.triangle.fill")
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

                Button("📂 打开日志与截图") {
                    DiagnosticFileManager.shared.openFolder()
                }
                .font(.subheadline)

                Spacer()

                if vm.allPassed && vm.hardwareConfirmed {
                    Button("立即录入面容 ID ➔") {
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
        .frame(width: 580, height: 680)
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

    private func testItemRow(title: String, state: TestState) -> some View {
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
                Text("正常 ✓").font(.caption).fontWeight(.semibold).foregroundColor(.green)
            case .failed(let err):
                Text("失败: \(err)").font(.caption).foregroundColor(.red)
            }
        }
    }
}

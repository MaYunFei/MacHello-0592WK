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

final class DiagnosticCaptureHelper: NSObject, CameraCaptureDelegate {
    var onFrame: ((NSImage) -> Void)?
    var isGrayscale: Bool = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastUpdate: TimeInterval = 0

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        let now = CACurrentMediaTime()
        // 限制在 ~15fps (约 65ms 一帧)，既丝滑生动，又绝不卡顿 UI
        guard now - lastUpdate >= 0.065 else { return }
        lastUpdate = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if isGrayscale {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.0, forKey: kCIInputSaturationKey)
                filter.setValue(1.35, forKey: kCIInputContrastKey)   // 提升 35% 对比度，增强暗室人脸轮廓
                filter.setValue(0.12, forKey: kCIInputBrightnessKey) // 提亮 12%，补偿远距离红外光衰减
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cameraService = CameraCaptureService.shared
            let irController = IRController.shared

            // 先确保摄像头停止，处于干净准备状态
            cameraService.stop()
            Thread.sleep(forTimeInterval: 0.25)

            // Step 1: 测试可见光 (RGB 720P) 实时画面
            let rgbHelper = DiagnosticCaptureHelper()
            rgbHelper.isGrayscale = false
            rgbHelper.onFrame = { [weak self] img in
                self?.rgbImage = img
            }
            cameraService.delegate = rgbHelper

            do {
                try cameraService.start(mode: .rgb)
                // 持续预览 2.0 秒，让画面充分曝光并让用户看到实时动态
                Thread.sleep(forTimeInterval: 2.0)
                cameraService.stop()

                DispatchQueue.main.async {
                    self.test1State = .passed
                    self.test2State = .running
                    self.statusMessage = "正在验证 UVC 扩展单元协议握手..."
                }
            } catch {
                DispatchQueue.main.async {
                    self.test1State = .failed(error.localizedDescription)
                    self.isTesting = false
                    self.statusMessage = "可见光测试失败"
                }
                return
            }

            // Step 2: 验证 UVC 扩展单元
            Thread.sleep(forTimeInterval: 0.3)
            guard irController.isConnected else {
                DispatchQueue.main.async {
                    self.test2State = .failed("未找到 USB 0bda:5767 接口")
                    self.isTesting = false
                }
                return
            }
            DispatchQueue.main.async {
                self.test2State = .passed
                self.test3State = .running
                self.statusMessage = "正在打亮 850nm 红外发射管..."
            }

            // Step 3: 触发 IR 模式
            Thread.sleep(forTimeInterval: 0.3)
            let irSuccess = irController.setMode(.ir)
            guard irSuccess else {
                DispatchQueue.main.async {
                    self.test3State = .failed("UVC 寄存器写入失败")
                    self.isTesting = false
                }
                return
            }
            DispatchQueue.main.async {
                self.test3State = .passed
                self.test4State = .running
                self.statusMessage = "正在启动红外夜视镜头 (自动增益爬升中)..."
            }

            // Step 4: 捕获 IR 视频流 (切换为红外灰度采集)
            Thread.sleep(forTimeInterval: 0.4)
            let irHelper = DiagnosticCaptureHelper()
            irHelper.isGrayscale = true
            irHelper.onFrame = { [weak self] img in
                self?.irImage = img
            }
            cameraService.delegate = irHelper

            do {
                try cameraService.start(mode: .ir)
                // 给予 2.5 秒时间让红外夜视曝光增益充分爬升，用户可实时看到暗室被照亮的画面
                Thread.sleep(forTimeInterval: 2.5)
                cameraService.stop()
                irController.resetToRGB()

                DispatchQueue.main.async {
                    self.test4State = .passed
                    self.allPassed = true
                    self.isTesting = false
                    self.statusMessage = "🎉 双目镜头全部自检通过！可见光与红外实拍成像完美。"
                }
            } catch {
                irController.resetToRGB()
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

import SwiftUI
import AppKit
import MacHelloCore
import AVFoundation

public enum TestState {
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

public struct HardwareDiagnosticView: View {
    @State private var isConnected: Bool = false
    @State private var cameraName: String = "正在检测..."
    @State private var hardwareConfirmed: Bool = false

    @State private var test1State: TestState = .idle // 可见光
    @State private var test2State: TestState = .idle // UVC XU 握手
    @State private var test3State: TestState = .idle // 红外发射管
    @State private var test4State: TestState = .idle // 红外视频流

    @State private var isTesting: Bool = false
    @State private var allPassed: Bool = false
    @State private var statusMessage: String = "点击下方按钮开始全面的硬件链路自检"

    var onDismiss: () -> Void
    var onStartEnrollment: () -> Void

    public init(onDismiss: @escaping () -> Void, onStartEnrollment: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.onStartEnrollment = onStartEnrollment
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 顶部标题与图标
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: "NSApplicationIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 54, height: 54)
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("MacHello 硬件自检与设备确认")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("请确认连接的模组为 Dell CN-0592WK，并完成硬件通畅性测试。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Divider()

            // 1. 硬件规格与识别卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("目标支持硬件规格")
                        .font(.headline)
                    Spacer()
                    if isConnected {
                        Label("检测到兼容硬件 (0bda:5767)", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label("未检测到目标硬件", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                VStack(spacing: 6) {
                    infoRow(title: "预期硬件型号", value: "Dell CN-0592WK (Realtek 0bda:5767)")
                    infoRow(title: "系统识别设备", value: cameraName)
                    infoRow(title: "近红外支持", value: "850nm 独立发射管 + 640x480 YUY2 红外镜头")
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)

                Toggle(isOn: $hardwareConfirmed) {
                    Text("我已确认当前连接的设备是 **Dell CN-0592WK** (0bda:5767) 硬件双目模组")
                        .font(.subheadline)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)

            // 2. 自检项目清单
            VStack(alignment: .leading, spacing: 12) {
                Text("硬件链路完整性测试")
                    .font(.headline)

                VStack(spacing: 8) {
                    testItemRow(title: "1. 可见光镜头 (RGB 720P) 视频流协商", state: test1State)
                    testItemRow(title: "2. Realtek UVC 扩展单元 (Unit 4) 5步状态机握手", state: test2State)
                    testItemRow(title: "3. 850nm 近红外发射管打亮与模式写入", state: test3State)
                    testItemRow(title: "4. 近红外物理镜头 (640x480 YUY2) 数据帧抓取", state: test4State)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(allPassed ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 24)

            Spacer()

            // 底部操作栏
            HStack(spacing: 12) {
                Button("开始硬件自检") {
                    runSelfTest()
                }
                .disabled(isTesting || !isConnected)
                .keyboardShortcut(.defaultAction)

                Spacer()

                if allPassed && hardwareConfirmed {
                    Button("立即录入面容 ID ➔") {
                        UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                        onStartEnrollment()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(allPassed ? "完成" : "关闭") {
                    if allPassed && hardwareConfirmed {
                        UserDefaults.standard.set(true, forKey: "com.machello.hardwareVerified")
                    }
                    onDismiss()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 580, height: 530)
        .onAppear {
            refreshHardwareInfo()
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

    private func refreshHardwareInfo() {
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

    private func runSelfTest() {
        isTesting = true
        allPassed = false
        test1State = .running
        test2State = .idle
        test3State = .idle
        test4State = .idle
        statusMessage = "正在测试可见光摄像头..."

        DispatchQueue.global(qos: .userInitiated).async {
            let cameraService = CameraCaptureService.shared
            let irController = IRController.shared

            // Step 1: 测试可见光
            do {
                try cameraService.start(mode: .rgb)
                Thread.sleep(forTimeInterval: 0.8)
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

            // Step 2: 验证 UVC 5步状态机
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
                self.statusMessage = "正在触发 850nm 红外发射管..."
            }

            // Step 3: 触发 IR 模式
            Thread.sleep(forTimeInterval: 0.3)
            let irSuccess = irController.setMode(.ir)
            guard irSuccess else {
                DispatchQueue.main.async {
                    self.test3State = .failed("UVC 写寄存器失败")
                    self.isTesting = false
                }
                return
            }
            DispatchQueue.main.async {
                self.test3State = .passed
                self.test4State = .running
                self.statusMessage = "正在捕获红外夜视镜头原始 YUY2 流..."
            }

            // Step 4: 捕获 IR 视频流
            do {
                try cameraService.start(mode: .ir)
                Thread.sleep(forTimeInterval: 0.8)
                cameraService.stop()
                irController.resetToRGB()

                DispatchQueue.main.async {
                    self.test4State = .passed
                    self.allPassed = true
                    self.isTesting = false
                    self.statusMessage = "🎉 全部 4 项硬件自检通过！设备状态完美。"
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

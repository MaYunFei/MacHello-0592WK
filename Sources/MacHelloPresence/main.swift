import Foundation
import CoreMedia
import MacHelloCore

final class PresenceMonitorDelegate: CameraCaptureDelegate, PresenceDetectorDelegate {
    let detector = PresenceDetector.shared
    var frameCounter = 0

    init() {
        detector.delegate = self
        detector.autoNotify = true
    }

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        frameCounter += 1
        detector.processSampleBuffer(sampleBuffer)
    }

    func presenceDetector(_ detector: PresenceDetector, didChangePresence isPresent: Bool, faceCount: Int) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if isPresent {
            print("[\(timestamp)] 🟢【有人】检测到目标出现在摄像头前！（人脸数: \(faceCount)）已弹出系统通知 🔔")
        } else {
            print("[\(timestamp)] ⚪️【无人】目标已离开摄像头视野。")
        }
    }
}

print("""
======================================================
  MacHello 人体感应监控器 (Human Presence Monitor)
  - 硬件: Dell 0592WK (0bda:5767)
  - 算法: Apple Vision Framework (NPU 实时检测)
  - 响应: 检测到有人时自动推送 macOS 系统横幅通知
======================================================
""")

let irController = IRController.shared
guard irController.isConnected else {
    print("❌ 错误: 未检测到戴尔 0592WK 摄像头模组。")
    exit(1)
}

let captureService = CameraCaptureService.shared
let monitor = PresenceMonitorDelegate()
captureService.delegate = monitor

// 处理 Ctrl+C 安全退出
signal(SIGINT) { _ in
    print("\n🛑 收到退出信号，正在停止视频流并复位硬件...")
    CameraCaptureService.shared.stop()
    IRController.shared.resetToRGB()
    print("👋 退出完成。")
    exit(0)
}

do {
    print("🎥 正在启动可见光环境检测流 (RGB 720P)...")
    try captureService.start(mode: .rgb)
    print("👁️ 感应器已就绪！请将脸面对/移出摄像头视野进行测试 (按 Ctrl+C 退出)\n")

    RunLoop.main.run()
} catch {
    print("❌ 启动失败: \(error)")
    irController.resetToRGB()
    exit(1)
}

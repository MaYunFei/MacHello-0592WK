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
            print("[\(timestamp)] 🟢 [PRESENT] Target detected in front of camera! (Faces: \(faceCount)) Notification sent 🔔")
        } else {
            print("[\(timestamp)] ⚪️ [AWAY] Target left camera field of view.")
        }
    }
}

print("""
======================================================
  MacHello Human Presence Monitor
  - Hardware: Dell CN-0592WK (0bda:5767)
  - Engine: Apple Vision Framework (NPU real-time detection)
  - Response: Auto push macOS banner notification when present
======================================================
""")

let irController = IRController.shared
guard irController.isConnected else {
    print("❌ Error: Dell 0592WK camera module not detected.")
    exit(1)
}

let captureService = CameraCaptureService.shared
let monitor = PresenceMonitorDelegate()
captureService.delegate = monitor

// 处理 Ctrl+C 安全退出
signal(SIGINT) { _ in
    print("\n🛑 Interrupt received, stopping video stream and resetting hardware...")
    CameraCaptureService.shared.stop()
    IRController.shared.resetToRGB()
    print("👋 Exited.")
    exit(0)
}

do {
    print("🎥 Starting visible ambient light detection stream (RGB 720P)...")
    try captureService.start(mode: .rgb)
    print("👁️ Sensor ready! Move face into/out of camera field of view to test (Press Ctrl+C to exit)\n")

    RunLoop.main.run()
} catch {
    print("❌ Start failed: \(error)")
    irController.resetToRGB()
    exit(1)
}

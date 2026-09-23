import Foundation
import MacHelloCore
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

final class DarkTestCapture: NSObject, CameraCaptureDelegate {
    let sema = DispatchSemaphore(value: 0)
    var frameCount = 0
    var targetFrames = 30 // 给予 30 帧 (约 1 秒) 让传感器硬件的夜视自动曝光 (AEC/AGC) 充分提升增益
    var capturedBuffer: CMSampleBuffer?

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        frameCount += 1
        // 抓取第 30 帧（经过充分自动曝光增益后的稳定帧）
        if frameCount >= targetFrames {
            capturedBuffer = sampleBuffer
            sema.signal()
        }
    }
}

func saveJPEG(sampleBuffer: CMSampleBuffer, to path: String) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let ctx = CIContext()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let data = ctx.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let captureService = CameraCaptureService.shared
let irController = IRController.shared

let outputDir = URL(fileURLWithPath: "Tests/Snapshots")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let irPath = "Tests/Snapshots/snapshot_dark_ir.jpg"
let irGrayPath = "Tests/Snapshots/snapshot_dark_ir_grayscale.jpg"

print("1. 正在打亮 850nm 红外发射管，并等待自动曝光增益调整 (30帧)...")
_ = irController.setMode(.ir)
let irCapture = DarkTestCapture()
captureService.delegate = irCapture
try? captureService.start(mode: .ir)
_ = irCapture.sema.wait(timeout: .now() + 5.0)
captureService.stop()

if let buf = irCapture.capturedBuffer {
    saveJPEG(sampleBuffer: buf, to: irPath)
    print("   已保存 IR 原色彩图: \(irPath)")

    // 保存纯灰度图 (Grayscale)
    if let pixelBuffer = CMSampleBufferGetImageBuffer(buf) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(0.0, forKey: kCIInputSaturationKey) // 去色纯灰度
        if let outImg = filter?.outputImage {
            let ctx = CIContext()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let grayData = ctx.jpegRepresentation(of: outImg, colorSpace: colorSpace, options: [:]) {
                try? grayData.write(to: URL(fileURLWithPath: irGrayPath))
                print("   已保存 IR 纯灰度图: \(irGrayPath)")
            }
        }
    }
} else {
    print("❌ 未捕获到 IR 视频帧")
}

// 安全复位
irController.resetToRGB()
print("2. 硬件已安全复位至 RGB 模式。")

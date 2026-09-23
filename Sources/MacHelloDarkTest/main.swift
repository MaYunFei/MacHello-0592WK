import Foundation
import MacHelloCore
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

final class DarkTestCapture: NSObject, CameraCaptureDelegate {
    let sema = DispatchSemaphore(value: 0)
    var frameCount = 0
    var targetFrames = 15
    var capturedBuffer: CMSampleBuffer?

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        frameCount += 1
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

print("1. 正在关闭屏幕...")
let sleepProc = Process()
sleepProc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
sleepProc.arguments = ["displaysleepnow"]
try? sleepProc.run()
sleepProc.waitUntilExit()

// 等待显示器彻底熄灭，杜绝屏幕背光干扰
Thread.sleep(forTimeInterval: 1.5)

let captureService = CameraCaptureService.shared
let irController = IRController.shared

let outputDir = URL(fileURLWithPath: "Tests/Snapshots")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let rgbPath = "Tests/Snapshots/snapshot_dark_rgb.jpg"
let irPath = "Tests/Snapshots/snapshot_dark_ir.jpg"

// 2. 抓拍关灯全黑下的 RGB 可见光镜头
print("2. 正在全黑环境下抓拍 RGB 镜头...")
let rgbCapture = DarkTestCapture()
captureService.delegate = rgbCapture
try? captureService.start(mode: .rgb)
_ = rgbCapture.sema.wait(timeout: .now() + 3.0)
captureService.stop()
if let buf = rgbCapture.capturedBuffer {
    saveJPEG(sampleBuffer: buf, to: rgbPath)
    print("   已保存: \(rgbPath)")
}

// 等待 0.5 秒平滑切换
Thread.sleep(forTimeInterval: 0.5)

// 3. 抓拍关灯全黑下的 IR 红外夜视镜头（触发 850nm 补光灯）
print("3. 正在全黑环境下打亮红外发射器并抓拍 IR 镜头...")
_ = irController.setMode(.ir)
let irCapture = DarkTestCapture()
captureService.delegate = irCapture
try? captureService.start(mode: .ir)
_ = irCapture.sema.wait(timeout: .now() + 3.0)
captureService.stop()
if let buf = irCapture.capturedBuffer {
    saveJPEG(sampleBuffer: buf, to: irPath)
    print("   已保存: \(irPath)")
}

// 4. 硬件安全复位
print("4. 安全复位硬件至 RGB 模式...")
irController.resetToRGB()

// 5. 立即唤醒点亮屏幕
print("5. 正在唤醒显示器...")
let wakeProc = Process()
wakeProc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
wakeProc.arguments = ["-u", "-t", "2"]
try? wakeProc.run()
wakeProc.waitUntilExit()
print("6. 屏幕已点亮！测试完成。")

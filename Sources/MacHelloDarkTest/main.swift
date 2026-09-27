import Foundation
import MacHelloCore
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

final class DarkTestCapture: NSObject, CameraCaptureDelegate {
    let sema = DispatchSemaphore(value: 0)
    var frameCount = 0
    var targetFrames = 30 // Allow 30 frames (~1 sec) for AEC/AGC hardware gain stabilization
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

let captureService = CameraCaptureService.shared
let irController = IRController.shared

let outputDir = URL(fileURLWithPath: "Tests/Snapshots")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let irPath = "Tests/Snapshots/snapshot_dark_ir.jpg"
let irGrayPath = "Tests/Snapshots/snapshot_dark_ir_grayscale.jpg"

print("1. Turning on 850nm IR emitter, waiting for auto-exposure gain adjustment (30 frames)...")
_ = irController.setMode(.ir)
let irCapture = DarkTestCapture()
captureService.delegate = irCapture
try? captureService.start(mode: .ir)
_ = irCapture.sema.wait(timeout: .now() + 5.0)
captureService.stop()

if let buf = irCapture.capturedBuffer {
    saveJPEG(sampleBuffer: buf, to: irPath)
    print("   Saved raw IR image: \(irPath)")

    if let pixelBuffer = CMSampleBufferGetImageBuffer(buf) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(0.0, forKey: kCIInputSaturationKey)
        if let outImg = filter?.outputImage {
            let ctx = CIContext()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let grayData = ctx.jpegRepresentation(of: outImg, colorSpace: colorSpace, options: [:]) {
                try? grayData.write(to: URL(fileURLWithPath: irGrayPath))
                print("   Saved IR grayscale image: \(irGrayPath)")
            }
        }
    }
} else {
    print("❌ No IR frames captured")
}

// Reset
irController.resetToRGB()
print("2. Hardware safely reset to RGB mode.")

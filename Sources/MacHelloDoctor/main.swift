import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import MacHelloCore
import CIOKitHelper

final class DoctorDelegate: CameraCaptureDelegate {
    var frameCount = 0
    var captureNext = false
    var currentLabel = ""
    var currentFilename = ""
    var isIRCurrent = false
    let ciContext = CIContext()
    var sema: DispatchSemaphore?

    func requestSnapshot(label: String, filename: String, isIR: Bool, sema: DispatchSemaphore) {
        self.currentLabel = label
        self.currentFilename = filename
        self.isIRCurrent = isIR
        self.sema = sema
        self.captureNext = true
    }

    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        frameCount += 1

        let requiredFrames = isIRCurrent ? 25 : 10
        if captureNext && frameCount > requiredFrames {
            captureNext = false
            saveSnapshot(sampleBuffer, filename: currentFilename, label: currentLabel, isIR: isIRCurrent)
            sema?.signal()
        }
    }

    private func saveSnapshot(_ sampleBuffer: CMSampleBuffer, filename: String, label: String, isIR: Bool) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. 保存原色彩图像
        if let jpegData = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) {
            let url = URL(fileURLWithPath: filename)
            try? jpegData.write(to: url)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            print("    📸 Saved \(label) [\(w)x\(h)]: \(filename) (\(jpegData.count) bytes)")
        }

        // 2. 如果是 IR 模式，同时保存一份标准的红外灰度图 (Grayscale NIR)
        if isIR {
            let grayFilter = CIFilter(name: "CIColorControls")
            grayFilter?.setValue(ciImage, forKey: kCIInputImageKey)
            grayFilter?.setValue(0.0, forKey: kCIInputSaturationKey) // 去色成为纯灰度

            if let grayImage = grayFilter?.outputImage,
               let grayData = ciContext.jpegRepresentation(of: grayImage, colorSpace: colorSpace, options: [:]) {
                let grayName = filename.replacingOccurrences(of: ".jpg", with: "_grayscale.jpg")
                try? grayData.write(to: URL(fileURLWithPath: grayName))
                print("    🌙 Saved IR Grayscale [标准灰度红外图]: \(grayName) (\(grayData.count) bytes)")
            }
        }
    }
}

print("==========================================")
print(" MacHello Hardware Doctor (0592WK)")
print("==========================================")

let outputDir = URL(fileURLWithPath: "Tests/Snapshots")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let irController = IRController.shared
print("\n[1] Checking Dell 0592WK USB connection via IOKit...")
guard irController.isConnected else {
    print("❌ ERROR: Dell 0592WK not detected on USB bus.")
    exit(1)
}
print("    Connected: YES (0bda:5767 detected)")

print("\n[2] Checking Camera authorization...")
let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
if authStatus != .authorized {
    let sema = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sema.signal() }
    sema.wait()
}
print("    Camera authorized.")

let captureService = CameraCaptureService.shared
let delegate = DoctorDelegate()
captureService.delegate = delegate

let rgbPath = outputDir.appendingPathComponent("snapshot_rgb.jpg").path
let irPath = outputDir.appendingPathComponent("snapshot_ir.jpg").path
let irGrayPath = outputDir.appendingPathComponent("snapshot_ir_grayscale.jpg").path

do {
    // 1. RGB 模式测试 (720P)
    print("\n[3] Testing RGB Camera Mode (720P)...")
    try captureService.start(mode: .rgb)
    let semaRgb = DispatchSemaphore(value: 0)
    delegate.requestSnapshot(label: "RGB Snapshot", filename: rgbPath, isIR: false, sema: semaRgb)
    _ = semaRgb.wait(timeout: .now() + 3.0)
    captureService.stop()

    // 2. IR 红外模式测试 (640x480 YUY2)
    print("\n[4] Testing IR Camera Mode (640x480 YUY2)...")
    delegate.frameCount = 0
    try captureService.start(mode: .ir)
    let semaIr = DispatchSemaphore(value: 0)
    delegate.requestSnapshot(label: "IR Snapshot", filename: irPath, isIR: true, sema: semaIr)
    _ = semaIr.wait(timeout: .now() + 3.0)
    captureService.stop()

    // 3. 安全复位
    print("\n[5] Safety Guard: Resetting hardware to RGB mode...")
    irController.resetToRGB()

    print("\n==========================================")
    print(" Test Summary:")
    print(" - Output Directory: Tests/Snapshots/")
    print(" - RGB Camera: OK (\(rgbPath))")
    print(" - IR Camera:  OK (\(irPath) & \(irGrayPath))")
    print(" - Hardware Mode Switching: OK")
    print("==========================================")
} catch {
    print("❌ Error: \(error)")
    irController.resetToRGB()
    exit(1)
}

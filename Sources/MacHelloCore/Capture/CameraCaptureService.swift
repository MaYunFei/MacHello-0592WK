import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CIOKitHelper

public protocol CameraCaptureDelegate: AnyObject {
    func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool)
}

public final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public static let shared = CameraCaptureService()

    public enum CaptureMode {
        case rgb
        case ir
    }

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.machello.camera.capture.queue")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentMode: CaptureMode = .rgb

    public weak var delegate: CameraCaptureDelegate?
    public private(set) var isRunning: Bool = false

    private override init() {
        super.init()
    }

    public static func findDellCamera() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.first(where: {
            $0.modelID.contains("3034") && $0.modelID.contains("22375")
        }) ?? discovery.devices.first(where: {
            $0.localizedName.contains("Integrated Webcam")
        })
    }

    /// 切换工作模式（RGB 彩色或 IR 红外）
    /// 注意：Dell 0592WK 红外传感器为 640x480 YUY2，RGB 传感器支持 720P。
    public func setMode(_ mode: CaptureMode) throws {
        self.currentMode = mode

        // 1. 设置硬件寄存器
        let hwCode: UInt8 = (mode == .ir) ? 0x00 : 0x01
        _ = dell_camera_set_mode(hwCode)

        // 2. 如果正在运行，需要平滑重新配置格式
        if isRunning {
            stop()
            try start(mode: mode)
        }
    }

    public func start(mode: CaptureMode = .rgb) throws {
        guard !isRunning else { return }
        self.currentMode = mode

        // 先向硬件发送模式
        let hwCode: UInt8 = (mode == .ir) ? 0x00 : 0x01
        _ = dell_camera_set_mode(hwCode)

        guard let device = CameraCaptureService.findDellCamera() else {
            throw NSError(domain: "MacHello", code: 404, userInfo: [NSLocalizedDescriptionKey: "Dell 0592WK Camera not found"])
        }

        session.beginConfiguration()
        session.sessionPreset = (mode == .ir) ? .vga640x480 : .high
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        try device.lockForConfiguration()
        if mode == .ir {
            // IR 模式必须锁定为 640x480 YUY2 (yuvs) 格式
            if let irFormat = device.formats.first(where: {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width == 640 && dims.height == 480
            }) {
                device.activeFormat = irFormat
            }
        }
        device.unlockForConfiguration()

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        if mode == .ir {
            output.videoSettings = [
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 480,
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        } else {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        }
        output.setSampleBufferDelegate(self, queue: outputQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            self.videoOutput = output
        }

        session.commitConfiguration()
        session.startRunning()
        isRunning = session.isRunning
    }

    public func stop() {
        if isRunning {
            session.stopRunning()
            isRunning = false
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.cameraCaptureService(self, didOutput: sampleBuffer, isIR: currentMode == .ir)
    }
}

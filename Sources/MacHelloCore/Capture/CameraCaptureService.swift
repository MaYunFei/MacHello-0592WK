import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import CoreGraphics
import ImageIO
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
    fileprivate var currentMode: CaptureMode = .rgb
    private lazy var networkReceiver = NetworkStreamReceiver(owner: self)

    public weak var delegate: CameraCaptureDelegate?
    public var isNetworkMode: Bool = false
    public var networkServerURL: String = "http://192.168.1.100:8765"
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
        // 如果正在运行，必须先关停视频流，避免 Realtek ISP 在数据流中切换模式导致固件死锁或黑屏
        if isRunning {
            stop()
            usleep(60000)
        }

        self.currentMode = mode
        let targetIrMode: IRController.Mode = (mode == .ir) ? .ir : .rgb
        _ = IRController.shared.setMode(targetIrMode)

        try start(mode: mode)
    }

    public func start(mode: CaptureMode = .rgb) throws {
        guard !isRunning else { return }
        self.currentMode = mode

        // 统一判断数据源模式：
        // 模式 B：局域网 Linux 数据源 (Samba 式网络相机网关，彻底解耦)
        if isNetworkMode {
            guard let streamURL = URL(string: "\(networkServerURL)/stream") else {
                throw NSError(domain: "MacHello", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Linux server URL"])
            }
            LinuxPresenceClient.shared.setIRMode(isIR: (mode == .ir))
            networkReceiver.start(url: streamURL)
            isRunning = true
            return
        }

        // 模式 A：本机 USB 直连模式 (AVFoundation)
        let targetIrMode: IRController.Mode = (mode == .ir) ? .ir : .rgb
        _ = IRController.shared.setMode(targetIrMode)

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
        } else {
            // RGB 模式必须恢复为 1280x720 格式，否则会被遗留在 IR 格式上导致黑屏
            if let rgbFormat = device.formats.first(where: {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width == 1280 && dims.height == 720
            }) {
                device.activeFormat = rgbFormat
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
            if isNetworkMode {
                networkReceiver.stop()
                LinuxPresenceClient.shared.setIRMode(isIR: false)
            } else {
                session.stopRunning()
            }
            isRunning = false
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.cameraCaptureService(self, didOutput: sampleBuffer, isIR: currentMode == .ir)
    }
}

// MARK: - 局域网 MJPEG 视频流解码接收器 (Samba 模式数据源)

final class NetworkStreamReceiver: NSObject, URLSessionDataDelegate {
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.machello.network.camera.queue")
    private weak var owner: CameraCaptureService?
    private(set) var isRunning: Bool = false

    init(owner: CameraCaptureService) {
        self.owner = owner
        super.init()
    }

    func start(url: URL) {
        stop()
        isRunning = true
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: url)
        task?.resume()
        print("[NetworkCamera] 已连接局域网相机数据流: \(url)")
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isRunning else { return }
        queue.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.buffer.append(data)

            while let start = self.buffer.range(of: Data([0xFF, 0xD8])),
                  let end = self.buffer.range(of: Data([0xFF, 0xD9]), in: start.lowerBound..<self.buffer.count) {
                let jpegData = self.buffer.subdata(in: start.lowerBound..<end.upperBound)
                self.buffer.removeSubrange(0..<end.upperBound)

                guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continue
                }

                if let sampleBuffer = self.makeSampleBuffer(from: cgImage) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let owner = self.owner, self.isRunning else { return }
                        owner.delegate?.cameraCaptureService(owner, didOutput: sampleBuffer, isIR: owner.currentMode == .ir)
                    }
                }
            }

            // 缓冲区溢出保护
            if self.buffer.count > 2 * 1024 * 1024 {
                self.buffer.removeAll()
            }
        }
    }

    private func makeSampleBuffer(from cgImage: CGImage) -> CMSampleBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let pxdata = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: pxdata,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: desc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}

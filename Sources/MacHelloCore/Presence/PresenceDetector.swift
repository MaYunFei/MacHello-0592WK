import Foundation
import Vision
import CoreMedia
import CoreVideo

public protocol PresenceDetectorDelegate: AnyObject {
    func presenceDetector(_ detector: PresenceDetector, didChangePresence isPresent: Bool, faceCount: Int)
}

public final class PresenceDetector {
    public static let shared = PresenceDetector()

    public weak var delegate: PresenceDetectorDelegate?

    public var autoNotify: Bool = true
    public private(set) var isPersonPresent: Bool = false
    public private(set) var lastDetectedFaceCount: Int = 0

    // 防抖与阈值配置
    private let hitThreshold: Int
    private let missThreshold: Int
    private var consecutiveHits: Int = 0
    private var consecutiveMisses: Int = 0

    private let processingQueue = DispatchQueue(label: "com.machello.presence.processing", qos: .userInitiated)
    private var isAnalyzing = false

    public var onPersonArrived: (() -> Void)?
    public var onPersonDeparted: (() -> Void)?

    public init(hitThreshold: Int = 2, missThreshold: Int = 20) {
        self.hitThreshold = hitThreshold
        self.missThreshold = missThreshold
    }

    /// 分析捕获到的视频帧
    public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !isAnalyzing else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isAnalyzing = true
        processingQueue.async { [weak self] in
            defer { self?.isAnalyzing = false }
            self?.analyze(pixelBuffer: pixelBuffer)
        }
    }

    /// 基于 Apple Vision Framework 分析人脸是否存在
    private func analyze(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
            let faces = request.results ?? []
            let count = faces.count

            updateState(faceCount: count)
        } catch {
            // 分析异常保持当前状态
        }
    }

    private func updateState(faceCount: Int) {
        lastDetectedFaceCount = faceCount

        if faceCount > 0 {
            consecutiveHits += 1
            consecutiveMisses = 0

            if !isPersonPresent && consecutiveHits >= hitThreshold {
                isPersonPresent = true
                handlePresenceStateChanged(isPresent: true, faceCount: faceCount)
            }
        } else {
            consecutiveMisses += 1
            consecutiveHits = 0

            if isPersonPresent && consecutiveMisses >= missThreshold {
                isPersonPresent = false
                handlePresenceStateChanged(isPresent: false, faceCount: 0)
            }
        }
    }

    private func handlePresenceStateChanged(isPresent: Bool, faceCount: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.presenceDetector(self, didChangePresence: isPresent, faceCount: faceCount)

            if isPresent {
                self.onPersonArrived?()
                if self.autoNotify {
                    SystemNotifier.shared.postNotification(
                        title: "MacHello 人体感应器",
                        body: "有人进入视野（检测到 \(faceCount) 张面孔）"
                    )
                }
            } else {
                self.onPersonDeparted?()
            }
        }
    }

    public func reset() {
        consecutiveHits = 0
        consecutiveMisses = 0
        isPersonPresent = false
        lastDetectedFaceCount = 0
    }
}

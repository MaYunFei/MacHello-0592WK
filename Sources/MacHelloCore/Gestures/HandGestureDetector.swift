import Foundation
import Vision
import CoreMedia
import AppKit

public enum HandGestureType: String, CaseIterable {
    case none = "无手势"
    case openPalm = "手掌展开 (✋)"
    case indexFingerUp = "竖起食指 (☝️)"
    case fist = "握拳 (✊)"
    case victory = "胜利剪刀手 (✌️)"
    case thumbsUp = "大拇指点赞 (👍)"
}

public protocol HandGestureDetectorDelegate: AnyObject {
    func handGestureDetector(_ detector: HandGestureDetector, didTrigger gesture: HandGestureType)
}

public final class HandGestureDetector {
    public static let shared = HandGestureDetector()

    public weak var delegate: HandGestureDetectorDelegate?

    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private var sequenceHandler = VNSequenceRequestHandler()

    // 防抖与冷却控制
    private var candidateGesture: HandGestureType = .none
    private var candidateStreak: Int = 0
    private let requiredStreak: Int = 4 // 需要连续 4 帧确认同一手势（约 0.25 秒）
    private var lastTriggerTime: Date = .distantPast
    private let cooldownDuration: TimeInterval = 1.8 // 触发后冷却 1.8 秒，防止连续误触

    public init() {
        handPoseRequest.maximumHandCount = 1
    }

    public func process(pixelBuffer: CVPixelBuffer) {
        // 如果处于触发冷却中，直接跳过
        guard Date().timeIntervalSince(lastTriggerTime) >= cooldownDuration else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observation = handPoseRequest.results?.first else {
            resetStreak()
            return
        }

        let detected = classifyGesture(from: observation)
        handleDetectedGesture(detected)
    }

    private func handleDetectedGesture(_ gesture: HandGestureType) {
        guard gesture != .none else {
            resetStreak()
            return
        }

        if gesture == candidateGesture {
            candidateStreak += 1
            if candidateStreak >= requiredStreak {
                // 成功触发手势动作！
                lastTriggerTime = Date()
                resetStreak()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.handGestureDetector(self, didTrigger: gesture)
                }
            }
        } else {
            candidateGesture = gesture
            candidateStreak = 1
        }
    }

    private func resetStreak() {
        candidateGesture = .none
        candidateStreak = 0
    }

    // MARK: - 几何规则分类器

    private func classifyGesture(from observation: VNHumanHandPoseObservation) -> HandGestureType {
        guard let points = try? observation.recognizedPoints(.all) else { return .none }

        // 获取手腕点
        guard let wrist = points[.wrist], wrist.confidence > 0.3 else { return .none }

        func dist(_ a: VNRecognizedPoint?, _ b: VNRecognizedPoint?) -> CGFloat {
            guard let a = a, let b = b, a.confidence > 0.3, b.confidence > 0.3 else { return 0 }
            return hypot(a.location.x - b.location.x, a.location.y - b.location.y)
        }

        // 判定四指（食指、中指、无名指、小指）是否伸展
        func isFingerExtended(tip: VNRecognizedPoint?, pip: VNRecognizedPoint?, mcp: VNRecognizedPoint?) -> Bool {
            let tipDist = dist(tip, wrist)
            let pipDist = dist(pip, wrist)
            let mcpDist = dist(mcp, wrist)
            guard tipDist > 0 && pipDist > 0 else { return false }
            return tipDist > pipDist * 1.15 && pipDist > mcpDist
        }

        func isFingerCurled(tip: VNRecognizedPoint?, pip: VNRecognizedPoint?, mcp: VNRecognizedPoint?) -> Bool {
            let tipDist = dist(tip, wrist)
            let pipDist = dist(pip, wrist)
            let mcpDist = dist(mcp, wrist)
            guard tipDist > 0 && pipDist > 0 else { return false }
            return tipDist <= pipDist * 1.05 || tipDist < mcpDist * 1.15
        }

        let isIndexExtended = isFingerExtended(tip: points[.indexTip], pip: points[.indexPIP], mcp: points[.indexMCP])
        let isIndexCurled = isFingerCurled(tip: points[.indexTip], pip: points[.indexPIP], mcp: points[.indexMCP])

        let isMiddleExtended = isFingerExtended(tip: points[.middleTip], pip: points[.middlePIP], mcp: points[.middleMCP])
        let isMiddleCurled = isFingerCurled(tip: points[.middleTip], pip: points[.middlePIP], mcp: points[.middleMCP])

        let isRingExtended = isFingerExtended(tip: points[.ringTip], pip: points[.ringPIP], mcp: points[.ringMCP])
        let isRingCurled = isFingerCurled(tip: points[.ringTip], pip: points[.ringPIP], mcp: points[.ringMCP])

        let isLittleExtended = isFingerExtended(tip: points[.littleTip], pip: points[.littlePIP], mcp: points[.littleMCP])
        let isLittleCurled = isFingerCurled(tip: points[.littleTip], pip: points[.littlePIP], mcp: points[.littleMCP])

        // 大拇指判定
        let thumbTip = points[.thumbTip]
        let thumbIP = points[.thumbIP]
        let thumbDist = dist(thumbTip, wrist)
        let isThumbExtended = (thumbDist > dist(thumbIP, wrist) * 1.05)

        // 1. 手掌全开 (✋ Open Palm): 五指全部伸展
        if isThumbExtended && isIndexExtended && isMiddleExtended && isRingExtended && isLittleExtended {
            return .openPalm
        }

        // 2. 握拳 (✊ Fist): 四指全部蜷缩
        if isIndexCurled && isMiddleCurled && isRingCurled && isLittleCurled {
            // 如果大拇指向上直立，则是点赞 👍
            if let tTip = thumbTip, let tIP = thumbIP, tTip.confidence > 0.4, tTip.location.y > tIP.location.y + 0.05 {
                return .thumbsUp
            }
            return .fist
        }

        // 3. 胜利剪刀手 (✌️ Victory): 食指和中指伸展，无名指和小指蜷缩
        if isIndexExtended && isMiddleExtended && isRingCurled && isLittleCurled {
            return .victory
        }

        // 4. 竖起食指 (☝️ Index Up): 仅食指伸展，中指/无名指/小指蜷缩
        if isIndexExtended && isMiddleCurled && isRingCurled && isLittleCurled {
            return .indexFingerUp
        }

        return .none
    }
}

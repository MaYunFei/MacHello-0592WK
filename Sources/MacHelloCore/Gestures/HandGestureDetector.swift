import Foundation
import Vision
import CoreMedia
import AppKit

public protocol HandGestureDetectorDelegate: AnyObject {
    func handGestureDetector(_ detector: HandGestureDetector, didTrigger gesture: HandGestureType)
    func handGestureDetector(_ detector: HandGestureDetector, didTrackLive gesture: HandGestureType)
}

public final class HandGestureDetector {
    public static let shared = HandGestureDetector()

    public weak var delegate: HandGestureDetectorDelegate?

    private let handPoseRequest = VNDetectHumanHandPoseRequest()

    // 动态手势时序轨迹缓存 (过去 0.6 秒内的手腕坐标)
    private var trajectoryBuffer: [(point: CGPoint, time: Date)] = []

    // 静态手势防抖与冷却控制
    private var candidateGesture: HandGestureType? = nil
    private var candidateStreak: Int = 0
    private let requiredStreak: Int = 3 // 连续 3 帧确认 (约 0.15 秒)
    private var lastTriggerTime: Date = .distantPast
    private let cooldownDuration: TimeInterval = 1.6 // 触发后冷却 1.6 秒

    public init() {
        handPoseRequest.maximumHandCount = 1
    }

    public func process(pixelBuffer: CVPixelBuffer) {
        // 1. 键鼠活跃防护：用户打字/动鼠标中，完全静默跳过（0 CPU，防误触）
        if GestureConfigManager.shared.isTypingProtectionEnabled && InputIdleMonitor.shared.isUserActivelyWorking {
            resetStreak()
            trajectoryBuffer.removeAll()
            return
        }

        // 2. 触发后冷却锁定
        guard Date().timeIntervalSince(lastTriggerTime) >= cooldownDuration else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        guard let observation = handPoseRequest.results?.first else {
            resetStreak()
            trajectoryBuffer.removeAll()
            return
        }

        // 3. 动态轨迹检测（优先判别挥手扫动）
        if let dynamicGesture = checkDynamicTrajectory(from: observation) {
            triggerGesture(dynamicGesture)
            return
        }

        // 4. 静态手势识别（姿势判别）
        if let staticGesture = classifyStaticPose(from: observation) {
            handleCandidateStatic(staticGesture)
        } else {
            resetStreak()
        }
    }

    private func triggerGesture(_ gesture: HandGestureType) {
        lastTriggerTime = Date()
        resetStreak()
        trajectoryBuffer.removeAll()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.handGestureDetector(self, didTrigger: gesture)
        }
    }

    private func handleCandidateStatic(_ gesture: HandGestureType) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.handGestureDetector(self, didTrackLive: gesture)
        }

        if gesture == candidateGesture {
            candidateStreak += 1
            if candidateStreak >= requiredStreak {
                triggerGesture(gesture)
            }
        } else {
            candidateGesture = gesture
            candidateStreak = 1
        }
    }

    private func resetStreak() {
        candidateGesture = nil
        candidateStreak = 0
    }

    // MARK: - 动态轨迹手势 (Swipe & Circle)

    private func checkDynamicTrajectory(from observation: VNHumanHandPoseObservation) -> HandGestureType? {
        guard let points = try? observation.recognizedPoints(.all),
              let wrist = points[.wrist], wrist.confidence > 0.4 else {
            return nil
        }

        let now = Date()
        trajectoryBuffer.append((point: wrist.location, time: now))

        // 保留过去 0.5 秒的数据
        trajectoryBuffer.removeAll { now.timeIntervalSince($0.time) > 0.5 }
        guard trajectoryBuffer.count >= 6 else { return nil }

        let first = trajectoryBuffer.first!
        let last = trajectoryBuffer.last!
        let dt = last.time.timeIntervalSince(first.time)
        guard dt > 0.15 else { return nil }

        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        let vx = dx / CGFloat(dt)
        let vy = dy / CGFloat(dt)

        // 1. 水平横扫判定 (横向速度显著大于纵向速度)
        if abs(vx) > 0.7 && abs(vx) > abs(vy) * 1.8 {
            if dx > 0.22 {
                // 镜像画面中，手向左扫在坐标轴表现为正向位移（或反向）
                return .swipeLeft
            } else if dx < -0.22 {
                return .swipeRight
            }
        }

        // 2. 向上划动
        if vy > 0.8 && abs(vy) > abs(vx) * 1.8 && dy > 0.25 {
            return .swipeUp
        }

        // 3. 空中画圈判定 (通过轨迹点绕质心的累积旋转角)
        if trajectoryBuffer.count >= 10 {
            var sumX: CGFloat = 0, sumY: CGFloat = 0
            for item in trajectoryBuffer { sumX += item.point.x; sumY += item.point.y }
            let centerX = sumX / CGFloat(trajectoryBuffer.count)
            let centerY = sumY / CGFloat(trajectoryBuffer.count)

            var cumulativeAngle: CGFloat = 0
            for i in 1..<trajectoryBuffer.count {
                let p1 = trajectoryBuffer[i - 1].point
                let p2 = trajectoryBuffer[i].point
                let a1 = atan2(p1.y - centerY, p1.x - centerX)
                let a2 = atan2(p2.y - centerY, p2.x - centerX)
                var diff = a2 - a1
                if diff > .pi { diff -= 2 * .pi }
                if diff < -.pi { diff += 2 * .pi }
                cumulativeAngle += diff
            }

            if abs(cumulativeAngle) > 4.5 { // 接近一整圈 (2 * pi ≈ 6.28)
                return .circle
            }
        }

        return nil
    }

    // MARK: - 静态几何姿势分类器

    private func classifyStaticPose(from observation: VNHumanHandPoseObservation) -> HandGestureType? {
        guard let points = try? observation.recognizedPoints(.all),
              let wrist = points[.wrist], wrist.confidence > 0.3 else {
            return nil
        }

        func dist(_ a: VNRecognizedPoint?, _ b: VNRecognizedPoint?) -> CGFloat {
            guard let a = a, let b = b, a.confidence > 0.3, b.confidence > 0.3 else { return 0 }
            return hypot(a.location.x - b.location.x, a.location.y - b.location.y)
        }

        func isExtended(tip: VNRecognizedPoint?, pip: VNRecognizedPoint?, mcp: VNRecognizedPoint?) -> Bool {
            let tDist = dist(tip, wrist)
            let pDist = dist(pip, wrist)
            let mDist = dist(mcp, wrist)
            guard tDist > 0 && pDist > 0 else { return false }
            return tDist > pDist * 1.15 && pDist > mDist
        }

        func isCurled(tip: VNRecognizedPoint?, pip: VNRecognizedPoint?, mcp: VNRecognizedPoint?) -> Bool {
            let tDist = dist(tip, wrist)
            let pDist = dist(pip, wrist)
            let mDist = dist(mcp, wrist)
            guard tDist > 0 && pDist > 0 else { return false }
            return tDist <= pDist * 1.05 || tDist < mDist * 1.15
        }

        let isIdxExt = isExtended(tip: points[.indexTip], pip: points[.indexPIP], mcp: points[.indexMCP])
        let isIdxCurl = isCurled(tip: points[.indexTip], pip: points[.indexPIP], mcp: points[.indexMCP])

        let isMidExt = isExtended(tip: points[.middleTip], pip: points[.middlePIP], mcp: points[.middleMCP])
        let isMidCurl = isCurled(tip: points[.middleTip], pip: points[.middlePIP], mcp: points[.middleMCP])

        let isRingExt = isExtended(tip: points[.ringTip], pip: points[.ringPIP], mcp: points[.ringMCP])
        let isRingCurl = isCurled(tip: points[.ringTip], pip: points[.ringPIP], mcp: points[.ringMCP])

        let isLitExt = isExtended(tip: points[.littleTip], pip: points[.littlePIP], mcp: points[.littleMCP])
        let isLitCurl = isCurled(tip: points[.littleTip], pip: points[.littlePIP], mcp: points[.littleMCP])

        let thumbTip = points[.thumbTip]
        let thumbIP = points[.thumbIP]
        let isThumbExt = (dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.05)

        // 1. 捏指比心 (🫰 Finger Heart): 拇指尖与食指尖捏在一起靠拢，其余中指/无名指/小指蜷缩
        let thumbIndexTipDist = dist(thumbTip, points[.indexTip])
        if isMidCurl && isRingCurl && isLitCurl {
            if thumbIndexTipDist > 0 && thumbIndexTipDist < dist(points[.indexPIP], points[.indexMCP]) * 0.95 {
                return .fingerHeart
            }
        }

        // 2. 手掌全开 (✋ Open Palm): 五指全部伸展
        if isThumbExt && isIdxExt && isMidExt && isRingExt && isLitExt {
            return .openPalm
        }

        // 3. 握拳 (✊ Fist) 或 点赞 (👍 Thumbs Up)
        if isIdxCurl && isMidCurl && isRingCurl && isLitCurl {
            if let tTip = thumbTip, let tIP = thumbIP, tTip.confidence > 0.4, tTip.location.y > tIP.location.y + 0.05 {
                return .thumbsUp
            }
            return .fist
        }

        // 4. 胜利剪刀手 (✌️ Victory): 食指中指伸展，无名指小指蜷缩
        if isIdxExt && isMidExt && isRingCurl && isLitCurl {
            return .victory
        }

        // 5. 竖起食指 (☝️ Index Up): 仅食指伸展，其余蜷缩
        if isIdxExt && isMidCurl && isRingCurl && isLitCurl {
            return .indexFingerUp
        }

        return nil
    }
}

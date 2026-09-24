import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import CIOKitHelper

public enum EnrollmentStage: String {
    case regular = "日常/戴镜外观"
    case alternative = "脱镜/替用外观"
}

public enum TargetPose: String, CaseIterable {
    case center = "正视镜头"
    case turnLeft = "向左微转头部"
    case turnRight = "向右微转头部"
    case tiltUp = "微微抬头"

    public var instruction: String {
        switch self {
        case .center: return "👀 请正视摄像头，保持平视"
        case .turnLeft: return "👈 请将头部微微向左转动 (约 15°)"
        case .turnRight: return "👉 请将头部微微向右转动 (约 15°)"
        case .tiltUp: return "👆 请将头部微微向上抬起"
        }
    }
}

public protocol FaceEnrollmentDelegate: AnyObject {
    func enrollmentDidUpdateInstruction(stage: EnrollmentStage, pose: TargetPose, progress: Double, message: String)
    func enrollmentDidCapturePose(stage: EnrollmentStage, pose: TargetPose)
    func enrollmentPoseDidFreeze(stage: EnrollmentStage, pose: TargetPose, isFreezing: Bool)
    func enrollmentStageDidComplete(stage: EnrollmentStage)
    func enrollmentDidFinishAll(totalSamples: Int)
    func enrollmentDidFail(error: String)
    func enrollmentDidOutputPreview(image: CGImage, stage: EnrollmentStage, currentPose: TargetPose?, isMatching: Bool, faceBoundingBox: CGRect?)
}

public extension FaceEnrollmentDelegate {
    func enrollmentPoseDidFreeze(stage: EnrollmentStage, pose: TargetPose, isFreezing: Bool) {}
    func enrollmentDidOutputPreview(image: CGImage, stage: EnrollmentStage, currentPose: TargetPose?, isMatching: Bool, faceBoundingBox: CGRect?) {}
}

public final class FaceEnrollmentService: NSObject, CameraCaptureDelegate {
    public static let shared = FaceEnrollmentService()

    public weak var delegate: FaceEnrollmentDelegate?

    public private(set) var currentStage: EnrollmentStage = .regular
    public private(set) var currentPoseIndex: Int = 0
    private let poses: [TargetPose] = TargetPose.allCases

    private var collectedSamples: [FaceSample] = []
    public private(set) var isEnrolling: Bool = false
    public private(set) var isFreezingPose: Bool = false
    private var consecutiveHitCount: Int = 0
    private let requiredHits: Int = 3
    private var freezeWorkItem: DispatchWorkItem?
    private var smoothedMatching: Bool = false
    private var lastMatchingTimestamp: TimeInterval = 0

    private let ciContext = CIContext()
    private let extractor = FaceFeatureExtractor.shared
    private let captureService = CameraCaptureService.shared
    private let irController = IRController.shared

    private override init() {
        super.init()
    }

    public var currentTargetPose: TargetPose {
        return poses[min(currentPoseIndex, poses.count - 1)]
    }

    public var completedPosesInCurrentStage: Set<TargetPose> {
        let currentAppearance = (currentStage == .regular) ? "regular" : "alternative"
        let stageSamples = collectedSamples.filter { $0.appearance == currentAppearance }
        let completed = stageSamples.compactMap { TargetPose(rawValue: $0.pose) }
        return Set(completed)
    }

    /// 开始录入流程（开启红外摄像头 640x480 并点亮红外 LED）
    public func startEnrollment(stage: EnrollmentStage = .regular) throws {
        guard !isEnrolling else { return }

        self.currentStage = stage
        self.currentPoseIndex = 0
        self.consecutiveHitCount = 0
        self.isEnrolling = true

        captureService.delegate = self
        try captureService.start(mode: .ir)

        let initialPose = currentTargetPose
        delegate?.enrollmentDidUpdateInstruction(
            stage: currentStage,
            pose: initialPose,
            progress: calculateProgress(),
            message: initialPose.instruction
        )
    }

    /// 进入第二阶段（脱镜/替用外观录入）
    public func startAlternativeStage() throws {
        self.currentStage = .alternative
        self.currentPoseIndex = 0
        self.consecutiveHitCount = 0

        let initialPose = currentTargetPose
        delegate?.enrollmentDidUpdateInstruction(
            stage: currentStage,
            pose: initialPose,
            progress: calculateProgress(),
            message: initialPose.instruction
        )
    }

    /// 停止录入并确保硬件复位
    public func stopEnrollment() {
        freezeWorkItem?.cancel()
        freezeWorkItem = nil
        isFreezingPose = false
        isEnrolling = false
        consecutiveHitCount = 0
        smoothedMatching = false
        captureService.stop()
        irController.resetToRGB()
    }

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnrolling else { return }
        // 成功识别后定格展示中，暂不刷新视频流，保持定格画面供用户清晰查看
        if isFreezingPose { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let faces = extractor.extract(from: pixelBuffer)
        let primaryFace = faces.first
        let target = currentTargetPose
        let now = ProcessInfo.processInfo.systemUptime

        var rawMatching = false
        if let face = primaryFace, faces.count == 1 {
            rawMatching = isPoseMatching(face: face, target: target)
        }

        // 防抖平滑处理：消除红外补光灯频闪暗帧导致 UI 高频剧烈闪烁
        if rawMatching {
            lastMatchingTimestamp = now
            smoothedMatching = true
            consecutiveHitCount += 1
        } else {
            // 350ms 宽限期：容忍红外自动曝光与脉冲暗帧
            if now - lastMatchingTimestamp < 0.35 {
                // 维持 matching 状态
            } else {
                smoothedMatching = false
                consecutiveHitCount = 0
            }
        }

        if faces.count > 1 {
            delegate?.enrollmentDidUpdateInstruction(
                stage: currentStage,
                pose: currentTargetPose,
                progress: calculateProgress(),
                message: "⚠️ 视野内检测到多张面孔，请确保只有您一人在镜头前"
            )
        }

        // 生成高对比度红外灰度预览底图
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let grayFilter = CIFilter(name: "CIColorControls")
        grayFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        grayFilter?.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let outputCI = grayFilter?.outputImage,
              let rawCGImage = ciContext.createCGImage(outputCI, from: outputCI.extent) else {
            return
        }

        // 将面部特征关键点绘制到红外预览画面上 (打点打上去，随向左向右移动自适应流动)
        let previewCGImage: CGImage
        if let face = primaryFace, !face.landmarks.isEmpty {
            previewCGImage = renderLandmarksOnImage(
                image: rawCGImage,
                landmarks: face.landmarks,
                isMatching: smoothedMatching
            )
        } else {
            previewCGImage = rawCGImage
        }

        delegate?.enrollmentDidOutputPreview(
            image: previewCGImage,
            stage: currentStage,
            currentPose: target,
            isMatching: smoothedMatching,
            faceBoundingBox: primaryFace?.boundingBox
        )

        // 达到命中门槛，触发动作识别成功与定格画面
        if consecutiveHitCount >= requiredHits, let face = primaryFace {
            consecutiveHitCount = 0
            handlePoseCaptured(face: face, pose: target, frozenImage: previewCGImage)
        }
    }

    /// 在预览帧图像上绘制高精度特征关键点
    private func renderLandmarksOnImage(
        image: CGImage,
        landmarks: [CGPoint],
        isMatching: Bool
    ) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // 绘制红外原图
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 科技感粒子点阵样式 (匹配时翡翠绿，搜寻时冰川青蓝)
        let coreRadius: CGFloat = 2.0
        let glowRadius: CGFloat = 4.0

        let (coreColor, glowColor) = isMatching
            ? (CGColor(red: 0.15, green: 0.95, blue: 0.40, alpha: 0.95), CGColor(red: 0.15, green: 0.95, blue: 0.40, alpha: 0.35))
            : (CGColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.85), CGColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.25))

        for pt in landmarks {
            let px = pt.x * CGFloat(width)
            let py = pt.y * CGFloat(height)

            // 外层微光晕
            ctx.setFillColor(glowColor)
            ctx.fillEllipse(in: CGRect(x: px - glowRadius, y: py - glowRadius, width: glowRadius * 2, height: glowRadius * 2))

            // 内层核心亮点
            ctx.setFillColor(coreColor)
            ctx.fillEllipse(in: CGRect(x: px - coreRadius, y: py - coreRadius, width: coreRadius * 2, height: coreRadius * 2))
        }

        return ctx.makeImage() ?? image
    }

    private func isPoseMatching(face: FaceFeatureResult, target: TargetPose) -> Bool {
        switch target {
        case .center:
            return abs(face.yaw) < 0.20 && abs(face.pitch) < 0.20
        case .turnLeft:
            // 用户向自身左侧转头时，Apple Vision 检测到的 yaw 为正值 (> +0.18)
            return face.yaw > 0.18
        case .turnRight:
            // 用户向自身右侧转头时，Apple Vision 检测到的 yaw 为负值 (< -0.18)
            return face.yaw < -0.18
        case .tiltUp:
            return face.pitch > 0.16
        }
    }

    private func handlePoseCaptured(face: FaceFeatureResult, pose: TargetPose, frozenImage: CGImage) {
        // 1. 开启定格
        isFreezingPose = true
        freezeWorkItem?.cancel()

        // 2. 保存样本
        let sample = FaceSample(
            pose: pose.rawValue,
            appearance: currentStage == .regular ? "regular" : "alternative",
            embedding: face.embedding
        )
        collectedSamples.append(sample)

        // 3. 播放清脆的 macOS Tink 成功提示音
        AudioFeedbackHelper.shared.playSuccess()

        // 4. 派发成功与定格状态事件
        delegate?.enrollmentDidCapturePose(stage: currentStage, pose: pose)
        delegate?.enrollmentPoseDidFreeze(stage: currentStage, pose: pose, isFreezing: true)

        // 5. 定格 1.2 秒：让用户看清楚识别成功与打点画面，随后平滑过渡
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isEnrolling else { return }

            self.isFreezingPose = false
            self.delegate?.enrollmentPoseDidFreeze(stage: self.currentStage, pose: pose, isFreezing: false)

            self.currentPoseIndex += 1
            if self.currentPoseIndex < self.poses.count {
                let nextPose = self.poses[self.currentPoseIndex]
                self.delegate?.enrollmentDidUpdateInstruction(
                    stage: self.currentStage,
                    pose: nextPose,
                    progress: self.calculateProgress(),
                    message: nextPose.instruction
                )
            } else {
                // 当前阶段完成
                self.delegate?.enrollmentStageDidComplete(stage: self.currentStage)
                if self.currentStage == .alternative {
                    self.finishAllEnrollment()
                }
            }
        }

        self.freezeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    public func finishAllEnrollment() {
        stopEnrollment()

        // 保存到数据库
        var profile = FaceDatabase.shared.load() ?? FaceProfile(username: NSUserName())
        profile.samples = collectedSamples
        profile.updatedAt = Date()
        try? FaceDatabase.shared.save(profile: profile)

        delegate?.enrollmentDidFinishAll(totalSamples: collectedSamples.count)
    }

    public func skipAlternativeStage() {
        finishAllEnrollment()
    }

    public func calculateProgress() -> Double {
        let stageOffset = (currentStage == .regular) ? 0.0 : 0.5
        let poseProgress = Double(currentPoseIndex) / Double(poses.count) * 0.5
        return stageOffset + poseProgress
    }
}

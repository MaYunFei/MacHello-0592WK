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
    func enrollmentStageDidComplete(stage: EnrollmentStage)
    func enrollmentDidFinishAll(totalSamples: Int)
    func enrollmentDidFail(error: String)
    func enrollmentDidOutputPreview(image: CGImage, stage: EnrollmentStage, currentPose: TargetPose?, isMatching: Bool, faceBoundingBox: CGRect?)
}

public extension FaceEnrollmentDelegate {
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
    private var consecutiveHitCount: Int = 0
    private let requiredHits: Int = 3

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
        isEnrolling = false
        captureService.stop()
        irController.resetToRGB()
    }

    public func cameraCaptureService(_ service: CameraCaptureService, didOutput sampleBuffer: CMSampleBuffer, isIR: Bool) {
        guard isEnrolling else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let faces = extractor.extract(from: pixelBuffer)
        let primaryFace = faces.first
        let target = currentTargetPose
        var isMatching = false

        if let face = primaryFace, faces.count == 1 {
            isMatching = isPoseMatching(face: face, target: target)
            if isMatching {
                consecutiveHitCount += 1
                if consecutiveHitCount >= requiredHits {
                    consecutiveHitCount = 0
                    recordSample(face: face, pose: target)
                }
            } else {
                consecutiveHitCount = 0
            }
        } else {
            consecutiveHitCount = 0
            if faces.count > 1 {
                delegate?.enrollmentDidUpdateInstruction(
                    stage: currentStage,
                    pose: currentTargetPose,
                    progress: calculateProgress(),
                    message: "⚠️ 视野内检测到多张面孔，请确保只有您一人在镜头前"
                )
            }
        }

        // 生成高对比度红外灰度预览图，传给 UI 界面渲染
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let grayFilter = CIFilter(name: "CIColorControls")
        grayFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        grayFilter?.setValue(0.0, forKey: kCIInputSaturationKey)

        if let outputCI = grayFilter?.outputImage,
           let cgImage = ciContext.createCGImage(outputCI, from: outputCI.extent) {
            delegate?.enrollmentDidOutputPreview(
                image: cgImage,
                stage: currentStage,
                currentPose: target,
                isMatching: isMatching,
                faceBoundingBox: primaryFace?.boundingBox
            )
        }
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

    private func recordSample(face: FaceFeatureResult, pose: TargetPose) {
        let sample = FaceSample(
            pose: pose.rawValue,
            appearance: currentStage == .regular ? "regular" : "alternative",
            embedding: face.embedding
        )
        collectedSamples.append(sample)

        delegate?.enrollmentDidCapturePose(stage: currentStage, pose: pose)

        currentPoseIndex += 1
        if currentPoseIndex < poses.count {
            let nextPose = poses[currentPoseIndex]
            delegate?.enrollmentDidUpdateInstruction(
                stage: currentStage,
                pose: nextPose,
                progress: calculateProgress(),
                message: nextPose.instruction
            )
        } else {
            // 当前阶段完成
            delegate?.enrollmentStageDidComplete(stage: currentStage)
            if currentStage == .alternative {
                finishAllEnrollment()
            }
        }
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

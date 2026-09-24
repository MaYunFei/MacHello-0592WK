import Foundation
import Vision
import CoreMedia
import CoreVideo

public struct FaceFeatureResult {
    public let boundingBox: CGRect
    public let yaw: Float // 左右转头角度 (负数向左，正数向右)
    public let pitch: Float // 上下抬头角度 (正数向上，负数向下)
    public let roll: Float // 左右歪头角度
    public let embedding: [Float] // 128 维特征向量
    public let confidence: Float
    public let landmarks: [CGPoint] // 关键点 (全图归一化坐标 0.0~1.0, 原点左下角)

    public init(
        boundingBox: CGRect,
        yaw: Float,
        pitch: Float,
        roll: Float,
        embedding: [Float],
        confidence: Float,
        landmarks: [CGPoint] = []
    ) {
        self.boundingBox = boundingBox
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.embedding = embedding
        self.confidence = confidence
        self.landmarks = landmarks
    }
}

public final class FaceFeatureExtractor {
    public static let shared = FaceFeatureExtractor()

    private let faceprintRequestClass: VNRequest.Type?

    public init() {
        self.faceprintRequestClass = NSClassFromString("VNCreateFaceprintRequest") as? VNRequest.Type
    }

    /// 从视频帧中提取人脸特征与朝向角度
    public func extract(from pixelBuffer: CVPixelBuffer) -> [FaceFeatureResult] {
        guard let reqClass = faceprintRequestClass else { return [] }
        let faceprintReq = reqClass.init()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return performExtraction(handler: handler, request: faceprintReq)
    }

    /// 从静态图像/局域网快照中提取人脸特征 (经 Apple NPU 加速)
    public func extract(from cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) -> [FaceFeatureResult] {
        guard let reqClass = faceprintRequestClass else { return [] }
        let faceprintReq = reqClass.init()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        return performExtraction(handler: handler, request: faceprintReq)
    }

    /// 从 JPEG 原始字节流中直接提取人脸特征 (经 Apple NPU 加速)
    public func extract(from data: Data, orientation: CGImagePropertyOrientation = .up) -> [FaceFeatureResult] {
        guard let reqClass = faceprintRequestClass else { return [] }
        let faceprintReq = reqClass.init()
        let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
        return performExtraction(handler: handler, request: faceprintReq)
    }

    private func performExtraction(handler: VNImageRequestHandler, request: VNRequest) -> [FaceFeatureResult] {
        let landmarksReq = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([request, landmarksReq])
            guard let observations = request.results as? [VNFaceObservation] else {
                return []
            }

            let landmarkObs = landmarksReq.results ?? []
            var results: [FaceFeatureResult] = []

            for (index, obs) in observations.enumerated() {
                // 1. 获取朝向角度 (弧度)
                let yaw = (obs.yaw?.floatValue) ?? 0.0
                let pitch = (obs.pitch?.floatValue) ?? 0.0
                let roll = (obs.roll?.floatValue) ?? 0.0

                // 2. 提取 128 维特征向量 (运行于 Apple NPU)
                guard let fpObj = obs.value(forKey: "faceprint") as? NSObject,
                      let data = fpObj.value(forKey: "VNEntityIdentificationModelPrintData") as? Data else {
                    continue
                }

                let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard floats.count == 128 else { continue }

                // 3. 提取 2D 关键点
                let matchedObs = (index < landmarkObs.count) ? landmarkObs[index] : obs
                var points: [CGPoint] = []
                if let lm = matchedObs.landmarks ?? obs.landmarks, let all = lm.allPoints {
                    let bbox = matchedObs.boundingBox
                    points = all.normalizedPoints.map { pt in
                        CGPoint(
                            x: bbox.origin.x + pt.x * bbox.size.width,
                            y: bbox.origin.y + pt.y * bbox.size.height
                        )
                    }
                }

                let result = FaceFeatureResult(
                    boundingBox: obs.boundingBox,
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    embedding: floats,
                    confidence: obs.confidence,
                    landmarks: points
                )
                results.append(result)
            }

            return results
        } catch {
            return []
        }
    }
}

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

    public init(boundingBox: CGRect, yaw: Float, pitch: Float, roll: Float, embedding: [Float], confidence: Float) {
        self.boundingBox = boundingBox
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.embedding = embedding
        self.confidence = confidence
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
    public func extract(from cgImage: CGImage) -> [FaceFeatureResult] {
        guard let reqClass = faceprintRequestClass else { return [] }
        let faceprintReq = reqClass.init()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        return performExtraction(handler: handler, request: faceprintReq)
    }

    /// 从 JPEG 原始字节流中直接提取人脸特征 (经 Apple NPU 加速)
    public func extract(from data: Data) -> [FaceFeatureResult] {
        guard let reqClass = faceprintRequestClass else { return [] }
        let faceprintReq = reqClass.init()
        let handler = VNImageRequestHandler(data: data, orientation: .up, options: [:])
        return performExtraction(handler: handler, request: faceprintReq)
    }

    private func performExtraction(handler: VNImageRequestHandler, request: VNRequest) -> [FaceFeatureResult] {
        do {
            try handler.perform([request])
            guard let observations = request.results as? [VNFaceObservation] else {
                return []
            }

            var results: [FaceFeatureResult] = []

            for obs in observations {
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

                let result = FaceFeatureResult(
                    boundingBox: obs.boundingBox,
                    yaw: yaw,
                    pitch: pitch,
                    roll: roll,
                    embedding: floats,
                    confidence: obs.confidence
                )
                results.append(result)
            }

            return results
        } catch {
            return []
        }
    }
}

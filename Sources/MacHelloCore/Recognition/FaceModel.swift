import Foundation

public struct FaceSample: Codable {
    public let id: UUID
    public let pose: String // "center", "left", "right", "up", "down"
    public let appearance: String // "regular" (戴镜/日常) or "alternative" (脱镜/替用)
    public let embedding: [Float] // 128 维特征向量
    public let capturedAt: Date

    public init(id: UUID = UUID(), pose: String, appearance: String, embedding: [Float], capturedAt: Date = Date()) {
        self.id = id
        self.pose = pose
        self.appearance = appearance
        self.embedding = embedding
        self.capturedAt = capturedAt
    }
}

public struct FaceProfile: Codable {
    public let username: String
    public var samples: [FaceSample]
    public let enrolledAt: Date
    public var updatedAt: Date

    public init(username: String = NSUserName(), samples: [FaceSample] = [], enrolledAt: Date = Date(), updatedAt: Date = Date()) {
        self.username = username
        self.samples = samples
        self.enrolledAt = enrolledAt
        self.updatedAt = updatedAt
    }
}

public final class FaceDatabase {
    public static let shared = FaceDatabase()

    private let storageURL: URL
    private var cachedProfile: FaceProfile?
    private let cacheLock = NSLock()

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".machello", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("faces.json")
        _ = load()
    }

    public func save(profile: FaceProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        try data.write(to: storageURL, options: .atomic)
        cacheLock.lock()
        self.cachedProfile = profile
        cacheLock.unlock()
    }

    public func load() -> FaceProfile? {
        cacheLock.lock()
        if let cached = cachedProfile {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try? decoder.decode(FaceProfile.self, from: data)
        cacheLock.lock()
        self.cachedProfile = profile
        cacheLock.unlock()
        return profile
    }

    public func clear() {
        try? FileManager.default.removeItem(at: storageURL)
        cacheLock.lock()
        self.cachedProfile = nil
        cacheLock.unlock()
    }

    public var isEnrolled: Bool {
        guard let profile = load() else { return false }
        return !profile.samples.isEmpty
    }

    /// 余弦相似度比对：与库中所有样本进行比对，返回最高相似度和是否命中
    public func match(embedding: [Float], threshold: Float = 0.65) -> (matched: Bool, highestScore: Float, matchedAppearance: String?) {
        guard let profile = load(), !profile.samples.isEmpty else {
            return (false, 0.0, nil)
        }

        var maxScore: Float = -1.0
        var bestAppearance: String?

        for sample in profile.samples {
            let score = FaceDatabase.cosineSimilarity(a: embedding, b: sample.embedding)
            if score > maxScore {
                maxScore = score
                bestAppearance = sample.appearance
            }
        }

        return (maxScore >= threshold, maxScore, bestAppearance)
    }

    /// 计算两个单位向量的余弦相似度 (点积)
    public static func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dot: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        if denom < 1e-6 { return 0.0 }
        return dot / denom
    }
}

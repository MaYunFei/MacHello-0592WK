import Foundation
import CoreMedia
import CoreImage
import AppKit

public final class AuthAuditLogger {
    public static let shared = AuthAuditLogger()

    public var historyDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".machello/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let maxHistoryCount = 50
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let fileQueue = DispatchQueue(label: "com.machello.authaudit.queue")

    private init() {}

    /// 记录一次人脸解锁/认证的抓拍实况与日志
    public func recordAuth(pixelBuffer: CVPixelBuffer, reason: String, score: Float, success: Bool) {
        fileQueue.async { [weak self] in
            guard let self = self else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = formatter.string(from: Date())

            let status = success ? "pass" : "fail"
            let filename = "\(timestamp)_\(reason)_\(status)_sim\(String(format: "%.2f", score)).jpg"
            let fileURL = self.historyDirectory.appendingPathComponent(filename)

            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            // 纯正黑白灰度
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.0, forKey: kCIInputSaturationKey)
                if let out = filter.outputImage {
                    ciImage = out
                }
            }

            let cs = CGColorSpaceCreateDeviceRGB()
            if let data = self.ciContext.jpegRepresentation(of: ciImage, colorSpace: cs, options: [:]) {
                try? data.write(to: fileURL)
            }

            let logFormatter = DateFormatter()
            logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let logLine = "[\(logFormatter.string(from: Date()))] [\(reason)] \(success ? "✓ 认证成功" : "× 认证失败") | 相似度: \(String(format: "%.3f", score)) | 照片: \(filename)"
            self.appendLog(logLine)

            self.pruneOldHistory()
        }
    }

    private func appendLog(_ message: String) {
        let logFile = historyDirectory.appendingPathComponent("audit.log")
        let line = message + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fh = FileHandle(forWritingAtPath: logFile.path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private func pruneOldHistory() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }

        let jpgFiles = files.filter { $0.pathExtension.lowercased() == "jpg" }
        if jpgFiles.count > maxHistoryCount {
            let sorted = jpgFiles.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d1 < d2
            }
            let toRemove = sorted.prefix(jpgFiles.count - maxHistoryCount)
            for f in toRemove {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    public func openHistoryFolder() {
        NSWorkspace.shared.open(historyDirectory)
    }
}

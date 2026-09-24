import Foundation
import CoreMedia
import CoreImage
import AppKit

public struct AuditRecord: Identifiable, Codable {
    public let id: String
    public let timestamp: Date
    public let reason: String
    public let score: Float
    public let success: Bool
    public let filename: String

    public var displayTitle: String {
        switch reason {
        case "lockscreen": return "锁屏免密自动解锁"
        case "wake_display": return "人脸靠近感应亮屏"
        case "admin_prompt": return "系统管理员弹窗提权"
        case "terminal_sudo": return "终端 Sudo 刷脸认证"
        case "diagnostic": return "双目硬件链路自检"
        default: return "面容识别认证"
        }
    }

    public var displayIcon: String {
        switch reason {
        case "lockscreen": return "lock.open.fill"
        case "wake_display": return "display"
        case "admin_prompt": return "shield.fill"
        case "terminal_sudo": return "terminal.fill"
        case "diagnostic": return "stethoscope"
        default: return "person.crop.circle.fill"
        }
    }
}

public final class AuthAuditLogger: ObservableObject {
    public static let shared = AuthAuditLogger()

    @Published public var records: [AuditRecord] = []

    public var historyDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".machello/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var jsonIndexURL: URL {
        return historyDirectory.appendingPathComponent("history.json")
    }

    private let maxHistoryCount = 50
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "com.machello.authaudit.queue")

    private init() {
        loadRecords()
    }

    public func loadRecords() {
        if let data = try? Data(contentsOf: jsonIndexURL),
           let list = try? JSONDecoder().decode([AuditRecord].self, from: data) {
            DispatchQueue.main.async {
                self.records = list.sorted(by: { $0.timestamp > $1.timestamp })
            }
        }
    }

    private func saveRecordsToDisk() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: jsonIndexURL)
        }
    }

    /// 记录一次人脸解锁/认证的抓拍实况与日志 (CVPixelBuffer 源)
    public func recordAuth(pixelBuffer: CVPixelBuffer, reason: String, score: Float, success: Bool) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        saveRecord(ciImage: ciImage, reason: reason, score: score, success: success)
    }

    /// 记录一次人脸解锁/认证的抓拍实况与日志 (CGImage 源，自动根据倒置设置校正)
    public func recordAuth(cgImage: CGImage, reason: String, score: Float, success: Bool) {
        var ciImage = CIImage(cgImage: cgImage)
        let isInverted = UserDefaults.standard.bool(forKey: "com.machello.isCameraInverted")
        if isInverted {
            ciImage = ciImage.oriented(.down)
        }
        saveRecord(ciImage: ciImage, reason: reason, score: score, success: success)
    }

    /// 记录一次人脸解锁/认证的抓拍实况与日志 (JPEG Data 源)
    public func recordAuth(data: Data, reason: String, score: Float, success: Bool) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        recordAuth(cgImage: cgImage, reason: reason, score: score, success: success)
    }

    private func saveRecord(ciImage: CIImage, reason: String, score: Float, success: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let id = UUID().uuidString
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let timeStr = formatter.string(from: now)

            let status = success ? "pass" : "fail"
            let filename = "\(timeStr)_\(reason)_\(status)_sim\(String(format: "%.2f", score)).jpg"
            let fileURL = self.historyDirectory.appendingPathComponent(filename)

            var processedCI = ciImage
            // 纯正黑白灰度
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(processedCI, forKey: kCIInputImageKey)
                filter.setValue(0.0, forKey: kCIInputSaturationKey)
                if let out = filter.outputImage {
                    processedCI = out
                }
            }

            let cs = CGColorSpaceCreateDeviceRGB()
            if let data = self.ciContext.jpegRepresentation(of: processedCI, colorSpace: cs, options: [:]) {
                try? data.write(to: fileURL)
            }

            let logFormatter = DateFormatter()
            logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let logLine = "[\(logFormatter.string(from: now))] [\(reason)] \(success ? "✓ 认证成功" : "× 认证失败") | 相似度: \(String(format: "%.3f", score)) | 照片: \(filename)"
            self.appendLog(logLine)

            let newRecord = AuditRecord(
                id: id,
                timestamp: now,
                reason: reason,
                score: score,
                success: success,
                filename: filename
            )

            DispatchQueue.main.async {
                var updated = self.records
                updated.insert(newRecord, at: 0)
                if updated.count > self.maxHistoryCount {
                    let surplus = updated.suffix(from: self.maxHistoryCount)
                    for item in surplus {
                        let path = self.historyDirectory.appendingPathComponent(item.filename)
                        try? FileManager.default.removeItem(at: path)
                    }
                    updated = Array(updated.prefix(self.maxHistoryCount))
                }
                self.records = updated
                self.saveRecordsToDisk()
            }
        }
    }

    public func deleteRecord(id: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let item = self.records.first(where: { $0.id == id }) {
                let path = self.historyDirectory.appendingPathComponent(item.filename)
                try? FileManager.default.removeItem(at: path)
            }
            DispatchQueue.main.async {
                self.records.removeAll(where: { $0.id == id })
                self.saveRecordsToDisk()
            }
        }
    }

    public func clearAllRecords() {
        queue.async { [weak self] in
            guard let self = self else { return }
            for item in self.records {
                let path = self.historyDirectory.appendingPathComponent(item.filename)
                try? FileManager.default.removeItem(at: path)
            }
            DispatchQueue.main.async {
                self.records.removeAll()
                self.saveRecordsToDisk()
            }
        }
    }

    public func imageURL(for record: AuditRecord) -> URL {
        return historyDirectory.appendingPathComponent(record.filename)
    }

    public func loadImage(for record: AuditRecord) -> NSImage? {
        let url = imageURL(for: record)
        return NSImage(contentsOf: url)
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

    public func openHistoryFolder() {
        NSWorkspace.shared.open(historyDirectory)
    }
}

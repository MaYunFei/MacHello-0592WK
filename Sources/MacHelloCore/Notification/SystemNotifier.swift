import Foundation
import UserNotifications

public final class SystemNotifier {
    public static let shared = SystemNotifier()

    private var lastNotificationTime: Date = .distantPast
    private let cooldownInterval: TimeInterval

    public init(cooldownInterval: TimeInterval = 5.0) {
        self.cooldownInterval = cooldownInterval
    }

    /// 发送系统级通知
    public func postNotification(title: String, subtitle: String? = nil, body: String) {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationTime) >= cooldownInterval else {
            return
        }
        lastNotificationTime = now

        // 1. 如果在 App 运行环境下且具有 Bundle ID，优先使用 UNUserNotificationCenter
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = title
            if let sub = subtitle {
                content.subtitle = sub
            }
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }

        // 2. 无论是否在 App 还是命令行 CLI，通过 AppleScript 确保系统横幅与提示音必定弹出
        DispatchQueue.global(qos: .userInitiated).async {
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"Ping\""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }
}

import Foundation
import UserNotifications
import AppKit

public final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SystemNotifier()

    public var onNotificationClicked: (() -> Void)?

    private var lastNotificationTime: Date = .distantPast
    private let cooldownInterval: TimeInterval

    public init(cooldownInterval: TimeInterval = 5.0) {
        self.cooldownInterval = cooldownInterval
        super.init()
        setupNotificationCenter()
    }

    private func setupNotificationCenter() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                NSLog("[SystemNotifier] 申请通知权限异常: %@", error.localizedDescription)
            }
        }
    }

    /// 发送系统级通知
    public func postNotification(title: String, subtitle: String? = nil, body: String, force: Bool = false) {
        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastNotificationTime) >= cooldownInterval else {
                return
            }
        }
        lastNotificationTime = now

        // 1. 如果在 App 运行环境下且具有 Bundle ID，优先使用 UNUserNotificationCenter（带本 App 真实原生图标并支持点击响应）
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = title
            if let sub = subtitle {
                content.subtitle = sub
            } else {
                content.subtitle = "点击查看抓拍记录"
            }
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "machello_auth_\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error = error {
                    NSLog("[SystemNotifier] UNUserNotificationCenter 添加通知失败: %@", error.localizedDescription)
                }
            }
            return
        }

        // 2. 仅在无 GUI Bundle 的纯命令行环境下降级使用 osascript 提示
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

    // MARK: - UNUserNotificationCenterDelegate

    // 当 App 处于前台或状态栏活跃时，仍然正常展示通知横幅并播放提示音
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    // 当用户点击通知横幅时触发：唤起抓拍历史窗口
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            self.onNotificationClicked?()
        }
        completionHandler()
    }
}

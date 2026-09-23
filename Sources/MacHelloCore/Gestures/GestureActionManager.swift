import Foundation
import AppKit

public final class GestureActionManager: NSObject, HandGestureDetectorDelegate {
    public static let shared = GestureActionManager()

    private let defaultsKeyEnabled = "com.machello.airGesturesEnabled"

    public var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyEnabled) == nil {
                return true // 默认开启隔空手势
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyEnabled)
        }
    }

    public var onGestureTriggered: ((HandGestureType) -> Void)?

    private override init() {
        super.init()
        HandGestureDetector.shared.delegate = self
    }

    // MARK: - HandGestureDetectorDelegate

    public func handGestureDetector(_ detector: HandGestureDetector, didTrigger gesture: HandGestureType) {
        guard isEnabled else { return }

        // 如果屏幕处于息屏状态，忽略手势（除人脸亮屏外）
        guard !DisplayPowerManager.shared.isDisplayAsleep else { return }

        executeAction(for: gesture)
        onGestureTriggered?(gesture)
    }

    public func executeAction(for gesture: HandGestureType) {
        switch gesture {
        case .openPalm:
            // ✋ 手掌前推 ➔ 立即息屏
            NSSound(named: "Pop")?.play()
            DisplayPowerManager.shared.sleepDisplay()
            SystemNotifier.shared.postNotification(title: "隔空手势 ✋", body: "检测到手掌手势，已关闭显示器息屏")

        case .indexFingerUp:
            // ☝️ 竖起食指 ➔ 切换系统静音
            NSSound(named: "Tink")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let script = "set volume output muted not (output muted of (get volume settings))"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势 ☝️", body: "检测到食指手势，已切换系统静音")

        case .fist:
            // ✊ 握拳 ➔ 播放 / 暂停媒体
            NSSound(named: "Tink")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let script = """
                if application "Music" is running then
                    tell application "Music" to playpause
                else if application "Spotify" is running then
                    tell application "Spotify" to playpause
                end if
                """
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势 ✊", body: "检测到握拳手势，已切换音乐播放/暂停")

        case .victory:
            // ✌️ 剪刀手 ➔ 截取屏幕存至桌面
            NSSound(named: "Glass")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let path = ("~/Desktop/Screenshot_\(dateStr).png" as NSString).expandingTildeInPath
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", path]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势 ✌️", body: "检测到剪刀手，已截屏保存至桌面")

        case .thumbsUp:
            // 👍 点赞
            NSSound(named: "Hero")?.play()
            SystemNotifier.shared.postNotification(title: "隔空手势 👍", body: "收到点赞！祝你工作愉快！")

        case .none:
            break
        }
    }
}

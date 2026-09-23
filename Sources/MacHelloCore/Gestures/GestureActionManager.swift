import Foundation
import AppKit

public final class GestureActionManager: NSObject, HandGestureDetectorDelegate {
    public static let shared = GestureActionManager()

    private let defaultsKeyEnabled = "com.machello.airGesturesEnabled"
    private let config = GestureConfigManager.shared

    public var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyEnabled)
        }
    }

    public var onGestureTriggered: ((HandGestureType, GestureActionType) -> Void)?
    public var onLiveGestureDetected: ((HandGestureType) -> Void)?

    private override init() {
        super.init()
        HandGestureDetector.shared.delegate = self
    }

    // MARK: - HandGestureDetectorDelegate

    public func handGestureDetector(_ detector: HandGestureDetector, didTrigger gesture: HandGestureType) {
        guard isEnabled else { return }
        guard !DisplayPowerManager.shared.isDisplayAsleep else { return }

        let rule = config.rule(for: gesture)
        guard rule.action != .none else { return }

        executeAction(rule.action, appName: rule.appName, gesture: gesture)
        onGestureTriggered?(gesture, rule.action)
    }

    public func handGestureDetector(_ detector: HandGestureDetector, didTrackLive gesture: HandGestureType) {
        guard isEnabled else { return }
        onLiveGestureDetected?(gesture)
    }

    public func executeAction(_ action: GestureActionType, appName: String = "Music", gesture: HandGestureType) {
        switch action {
        case .none:
            break

        case .sleepDisplay:
            NSSound(named: "Pop")?.play()
            DisplayPowerManager.shared.sleepDisplay()
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 已执行息屏")

        case .lockScreen:
            NSSound(named: "Pop")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
                proc.arguments = ["-suspend"]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 锁定屏幕")

        case .toggleMute:
            NSSound(named: "Tink")?.play()
            runAppleScript("set volume output muted not (output muted of (get volume settings))")
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 切换静音")

        case .mediaPlayPause:
            NSSound(named: "Tink")?.play()
            let script = """
            if application "Music" is running then
                tell application "Music" to playpause
            else if application "Spotify" is running then
                tell application "Spotify" to playpause
            end if
            """
            runAppleScript(script)
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 播放/暂停音乐")

        case .mediaNext:
            NSSound(named: "Tink")?.play()
            let script = """
            if application "Music" is running then
                tell application "Music" to next track
            else if application "Spotify" is running then
                tell application "Spotify" to next track
            end if
            """
            runAppleScript(script)
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 下一曲")

        case .mediaPrevious:
            NSSound(named: "Tink")?.play()
            let script = """
            if application "Music" is running then
                tell application "Music" to previous track
            else if application "Spotify" is running then
                tell application "Spotify" to previous track
            end if
            """
            runAppleScript(script)
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 上一曲")

        case .volumeUp:
            NSSound(named: "Tink")?.play()
            runAppleScript("set volume output volume ((output volume of (get volume settings)) + 6)")

        case .volumeDown:
            NSSound(named: "Tink")?.play()
            runAppleScript("set volume output volume ((output volume of (get volume settings)) - 6)")

        case .missionControl:
            NSSound(named: "Pop")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", "Mission Control"]
                try? proc.run()
            }

        case .screenshot:
            NSSound(named: "Glass")?.play()
            DispatchQueue.global(qos: .userInitiated).async {
                let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let path = ("~/Desktop/Screenshot_\(dateStr).png" as NSString).expandingTildeInPath
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", path]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 截图已保存至桌面")

        case .launchApp:
            NSSound(named: "Hero")?.play()
            let target = appName.isEmpty ? "Music" : appName
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                proc.arguments = ["-a", target]
                try? proc.run()
            }
            SystemNotifier.shared.postNotification(title: "隔空手势触发", body: "\(gesture.displayName) ➔ 启动应用 \(target)")
        }
    }

    private func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}

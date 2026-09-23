import Foundation

public enum HandGestureType: String, CaseIterable, Codable, Identifiable {
    public var id: String { rawValue }

    // 静态手势 (Static Poses)
    case openPalm       = "openPalm"
    case indexFingerUp  = "indexFingerUp"
    case fist           = "fist"
    case victory        = "victory"
    case thumbsUp       = "thumbsUp"
    case fingerHeart    = "fingerHeart"

    // 动态手势 (Dynamic Trajectories)
    case swipeLeft      = "swipeLeft"
    case swipeRight     = "swipeRight"
    case swipeUp        = "swipeUp"
    case circle         = "circle"

    public var displayName: String {
        switch self {
        case .openPalm:      return "✋ 手掌前推 (Open Palm)"
        case .indexFingerUp: return "☝️ 竖起食指 (Shh/Index Up)"
        case .fist:          return "✊ 隔空握拳 (Fist)"
        case .victory:       return "✌️ 剪刀手 (Victory)"
        case .thumbsUp:      return "👍 大拇指点赞 (Thumbs Up)"
        case .fingerHeart:   return "🫰 捏指比心 (Finger Heart)"
        case .swipeLeft:     return "👈 向左横扫 (Swipe Left)"
        case .swipeRight:    return "👉 向右横扫 (Swipe Right)"
        case .swipeUp:       return "👆 向上划动 (Swipe Up)"
        case .circle:        return "🔄 空中画圈 (Circle)"
        }
    }

    public var icon: String {
        switch self {
        case .openPalm:      return "hand.raised.fill"
        case .indexFingerUp: return "hand.point.up.fill"
        case .fist:          return "hand.closed.fill"
        case .victory:       return "hand.draw.fill"
        case .thumbsUp:      return "hand.thumbsup.fill"
        case .fingerHeart:   return "heart.fill"
        case .swipeLeft:     return "arrow.left"
        case .swipeRight:    return "arrow.right"
        case .swipeUp:       return "arrow.up"
        case .circle:        return "arrow.triangle.2.circlepath"
        }
    }
}

public enum GestureActionType: String, CaseIterable, Codable, Identifiable {
    public var id: String { rawValue }

    case none            = "none"
    case sleepDisplay    = "sleepDisplay"
    case lockScreen      = "lockScreen"
    case toggleMute      = "toggleMute"
    case mediaPlayPause  = "mediaPlayPause"
    case mediaNext       = "mediaNext"
    case mediaPrevious   = "mediaPrevious"
    case volumeUp        = "volumeUp"
    case volumeDown      = "volumeDown"
    case missionControl  = "missionControl"
    case screenshot      = "screenshot"
    case launchApp       = "launchApp"

    public var displayName: String {
        switch self {
        case .none:           return "无操作 (禁用该手势)"
        case .sleepDisplay:   return "立即息屏 (关闭显示器)"
        case .lockScreen:     return "锁定屏幕 (⌃+⌘+Q)"
        case .toggleMute:     return "系统静音 / 取消静音"
        case .mediaPlayPause: return "媒体 播放 / 暂停"
        case .mediaNext:      return "媒体 下一曲"
        case .mediaPrevious:  return "媒体 上一曲"
        case .volumeUp:       return "调高系统音量 (+6%)"
        case .volumeDown:     return "降低系统音量 (-6%)"
        case .missionControl: return "调度中心 (Mission Control)"
        case .screenshot:     return "桌面全屏截图"
        case .launchApp:      return "打开指定应用程序"
        }
    }
}

public struct GestureRule: Codable, Equatable {
    public var action: GestureActionType
    public var appName: String

    public init(action: GestureActionType, appName: String = "Music") {
        self.action = action
        self.appName = appName
    }
}

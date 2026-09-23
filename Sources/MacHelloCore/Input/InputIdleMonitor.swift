import Foundation
import CoreGraphics

public final class InputIdleMonitor {
    public static let shared = InputIdleMonitor()

    private init() {}

    /// 获取自上次键盘、鼠标或触摸板操作以来的系统空闲时间（秒）
    public var idleSeconds: TimeInterval {
        let anyInputType = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputType)
    }

    /// 用户是否在最近的几秒内正在进行键鼠输入
    public func isUserActive(within seconds: TimeInterval = 3.0) -> Bool {
        return idleSeconds < seconds
    }
}

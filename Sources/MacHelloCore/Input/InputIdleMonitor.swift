import Foundation
import CoreGraphics

public final class InputIdleMonitor {
    public static let shared = InputIdleMonitor()

    private init() {}

    /// 获取自上次键盘/鼠标/触摸板输入以来的空闲时间（秒）
    public var idleSeconds: TimeInterval {
        // CGEventType(rawValue: ~0) 代表监听任意类型的输入事件 (Keyboard, Mouse, Tablet)
        let anyInputType = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputType)
    }

    /// 用户当前是否正在积极键鼠工作（停手小于 2.5 秒）
    public var isUserActivelyWorking: Bool {
        return idleSeconds < 2.5
    }
}

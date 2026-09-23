import Foundation
import IOKit.pwr_mgt

public final class MediaActivityDetector {
    public static let shared = MediaActivityDetector()

    private init() {}

    /// 检测系统当前是否有音视频播放、在线会议、全屏演示等阻止息屏的断言
    /// 例如：YouTube / Bilibili 视频播放 (Safari/Chrome)、IINA、VLC、Zoom、腾讯会议等
    public var isPreventingDisplaySleep: Bool {
        var assertionsStatus: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsStatus(&assertionsStatus)
        guard status == kIOReturnSuccess,
              let dict = assertionsStatus?.takeRetainedValue() as? [String: Any] else {
            return false
        }

        if let count = dict[kIOPMAssertionTypePreventUserIdleDisplaySleep as String] as? Int, count > 0 {
            return true
        }
        if let count = dict[kIOPMAssertionTypeNoDisplaySleep as String] as? Int, count > 0 {
            return true
        }

        return false
    }
}

import Foundation
import AppKit
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

    /// 获取当前正在阻止息屏的应用名称或断言名称（若有多个，以逗号分隔，例如 "Google Chrome"、"腾讯会议"、"IINA"）
    public var activeMediaAppName: String? {
        guard isPreventingDisplaySleep else { return nil }

        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess,
              let dict = assertionsByProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]] else {
            return "媒体播放中"
        }

        var appNames: [String] = []

        for (pidNum, assertions) in dict {
            let pid = pid_t(pidNum.intValue)
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String,
                      type == kIOPMAssertionTypePreventUserIdleDisplaySleep as String ||
                      type == kIOPMAssertionTypeNoDisplaySleep as String else {
                    continue
                }

                // 优先读取进程本地化应用名称
                if let app = NSRunningApplication(processIdentifier: pid),
                   let name = app.localizedName, !name.isEmpty {
                    if !appNames.contains(name) {
                        appNames.append(name)
                    }
                } else if let assertionName = assertion[kIOPMAssertionNameKey as String] as? String,
                          !assertionName.isEmpty {
                    if !appNames.contains(assertionName) {
                        appNames.append(assertionName)
                    }
                }
            }
        }

        if appNames.isEmpty {
            return "媒体播放中"
        }

        return appNames.joined(separator: ", ")
    }
}


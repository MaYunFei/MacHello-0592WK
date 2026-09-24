import Foundation
import AppKit
import IOKit.pwr_mgt

public protocol DisplayPowerObserver: AnyObject {
    func displayPowerStateDidChange(isDisplayAsleep: Bool)
}

public final class DisplayPowerManager: NSObject {
    public static let shared = DisplayPowerManager()

    public private(set) var isDisplayAsleep: Bool = false
    private var observers = NSHashTable<AnyObject>.weakObjects()

    private override init() {
        super.init()
        setupWorkspaceNotifications()
    }

    private func setupWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleScreenSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleScreenWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func handleScreenSleep() {
        isDisplayAsleep = true
        notifyObservers()
    }

    @objc private func handleScreenWake() {
        isDisplayAsleep = false
        notifyObservers()
    }

    public func addObserver(_ observer: DisplayPowerObserver) {
        observers.add(observer)
    }

    private func notifyObservers() {
        for object in observers.allObjects {
            if let obs = object as? DisplayPowerObserver {
                obs.displayPowerStateDidChange(isDisplayAsleep: isDisplayAsleep)
            }
        }
    }

    /// 立即锁定屏幕并休眠显示器（真正的系统级锁屏，立即进入 loginwindow 锁屏状态）
    public func sleepDisplay() {
        guard !isDisplayAsleep else { return }
        isDisplayAsleep = true
        notifyObservers()

        // 1. 核心锁屏：调用 macOS login.framework 的 SACLockScreenImmediate 真正锁定系统屏幕
        typealias SACLockScreenImmediateType = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) {
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                let lockFunc = unsafeBitCast(sym, to: SACLockScreenImmediateType.self)
                _ = lockFunc()
            }
            dlclose(handle)
        }

        // 2. 关闭显示器背光
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        }
    }

    /// 立即唤醒并点亮显示器
    public func wakeDisplay() {
        guard isDisplayAsleep else { return }
        isDisplayAsleep = false
        notifyObservers()

        // 1. 发起 IOKit 用户活动声明断言
        var assertionID: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "MacHello Presence Wake" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )

        // 2. 配合 caffeinate 瞬时模拟用户击键触发屏幕背光点亮
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-u", "-t", "2"]
            try? process.run()
        }
    }
}

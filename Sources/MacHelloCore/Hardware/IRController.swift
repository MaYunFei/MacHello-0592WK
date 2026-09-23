import Foundation
import CIOKitHelper

public final class IRController {
    public static let shared = IRController()

    public enum Mode: UInt8 {
        case ir = 0x00
        case rgb = 0x01
    }

    private let lock = NSLock()
    private(set) public var currentMode: Mode = .rgb

    private init() {}

    public var isConnected: Bool {
        return dell_camera_is_connected()
    }

    @discardableResult
    public func setMode(_ mode: Mode, force: Bool = false) -> Bool {
        guard isConnected else { return false }
        lock.lock()
        defer { lock.unlock() }

        if !force && currentMode == mode {
            return true // 已处于目标模式，跳过重复写入避免 Realtek RTS5822 状态机冲突
        }

        let ret = dell_camera_set_mode(mode.rawValue)
        if ret == 0 {
            currentMode = mode
            usleep(50000) // 50ms 硬件状态机过渡沉淀时间
            return true
        } else {
            return false
        }
    }

    @discardableResult
    public func toggle() -> Bool {
        guard isConnected else { return false }
        let newMode: Mode = (currentMode == .ir) ? .rgb : .ir
        return setMode(newMode)
    }

    public func resetToRGB() {
        if isConnected {
            _ = setMode(.rgb)
        }
    }
}

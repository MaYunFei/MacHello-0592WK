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
    public func setMode(_ mode: Mode) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let ret = dell_camera_set_mode(mode.rawValue)
        if ret == 0 {
            currentMode = mode
            return true
        } else {
            return false
        }
    }

    @discardableResult
    public func toggle() -> Bool {
        let newMode: Mode = (currentMode == .ir) ? .rgb : .ir
        return setMode(newMode)
    }

    public func resetToRGB() {
        _ = setMode(.rgb)
    }
}

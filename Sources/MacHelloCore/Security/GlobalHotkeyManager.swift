import Foundation
import Carbon
import AppKit

public struct HotkeyPreset: Identifiable, Equatable {
    public var id: String { "\(keyCode)_\(modifiers)" }
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let title: String

    public init(keyCode: UInt32, modifiers: UInt32, title: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.title = title
    }
}

public final class GlobalHotkeyManager: ObservableObject {
    public static let shared = GlobalHotkeyManager()

    private let defaultsKeyEnabled = "com.machello.isGlobalHotkeyFillEnabled"
    private let defaultsKeyKeyCode = "com.machello.hotkeyKeyCode"
    private let defaultsKeyModifiers = "com.machello.hotkeyModifiers"

    // 默认快捷键：Command + \ (⌘\，经典 1Password 风格)
    public static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_Backslash) // 42, '\'
    public static let defaultModifiers: UInt32 = UInt32(cmdKey) // 256, ⌘

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    public var onHotKeyTriggered: (() -> Void)?

    @Published public var currentKeyCode: UInt32 = defaultKeyCode
    @Published public var currentModifiers: UInt32 = defaultModifiers
    @Published public var currentDisplay: String = "⌘\\"

    public var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKeyEnabled) == nil {
                return true // 默认开启全局快捷键刷脸填密
            }
            return UserDefaults.standard.bool(forKey: defaultsKeyEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKeyEnabled)
            if newValue {
                register()
            } else {
                unregister()
            }
        }
    }

    public static let presets: [HotkeyPreset] = [
        HotkeyPreset(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey), title: "⌘\\ (Command + \\ - 1Password 风格)"),
        HotkeyPreset(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey), title: "⌥⌘P (Option + Command + P)"),
        HotkeyPreset(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), title: "⌃⌥Space (Control + Option + Space)"),
        HotkeyPreset(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(optionKey), title: "⌥\\ (Option + \\)"),
        HotkeyPreset(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey | shiftKey), title: "⇧⌘\\ (Shift + Command + \\)")
    ]

    private init() {
        let savedCode = UserDefaults.standard.object(forKey: defaultsKeyKeyCode) as? UInt32
        let savedMods = UserDefaults.standard.object(forKey: defaultsKeyModifiers) as? UInt32
        self.currentKeyCode = savedCode ?? Self.defaultKeyCode
        self.currentModifiers = savedMods ?? Self.defaultModifiers
        self.currentDisplay = Self.formatHotkey(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    public func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers
        self.currentDisplay = Self.formatHotkey(keyCode: keyCode, modifiers: modifiers)

        UserDefaults.standard.set(keyCode, forKey: defaultsKeyKeyCode)
        UserDefaults.standard.set(modifiers, forKey: defaultsKeyModifiers)

        if isEnabled {
            register()
        }
    }

    public func resetToDefault() {
        setHotkey(keyCode: Self.defaultKeyCode, modifiers: Self.defaultModifiers)
    }

    public func start() {
        if isEnabled {
            register()
        }
    }

    public func register() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            guard let event = event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if err == noErr && hotKeyID.signature == 0x4D483031 && hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    GlobalHotkeyManager.shared.onHotKeyTriggered?()
                }
            }
            return noErr
        }

        // 关键修复：必须向全局系统级 GetEventDispatcherTarget() 安装事件处理器，
        // 否则 LSUIElement 状态栏应用在失去前台焦点时，无法通过 GetApplicationEventTarget() 接收全局快捷键！
        let target = GetEventDispatcherTarget()
        InstallEventHandler(
            target,
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: 0x4D483031, id: 1) // "MH01"

        let status = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotKeyID,
            target,
            0,
            &hotKeyRef
        )

        if status == noErr {
            print("[GlobalHotkey] ✓ 成功注册全局刷脸填密快捷键: \(currentDisplay) (keyCode: \(currentKeyCode), modifiers: \(currentModifiers))")
        } else {
            print("[GlobalHotkey] ⚠️ 注册全局快捷键失败 (\(currentDisplay)), OSStatus: \(status)")
        }
    }

    public func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    public static func formatHotkey(keyCode: UInt32, modifiers: UInt32) -> String {
        var modStr = ""
        if (modifiers & UInt32(controlKey)) != 0 { modStr += "⌃" }
        if (modifiers & UInt32(optionKey)) != 0 { modStr += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { modStr += "⇧" }
        if (modifiers & UInt32(cmdKey)) != 0 { modStr += "⌘" }

        let keyStr: String
        switch Int(keyCode) {
        case kVK_ANSI_A: keyStr = "A"
        case kVK_ANSI_B: keyStr = "B"
        case kVK_ANSI_C: keyStr = "C"
        case kVK_ANSI_D: keyStr = "D"
        case kVK_ANSI_E: keyStr = "E"
        case kVK_ANSI_F: keyStr = "F"
        case kVK_ANSI_G: keyStr = "G"
        case kVK_ANSI_H: keyStr = "H"
        case kVK_ANSI_I: keyStr = "I"
        case kVK_ANSI_J: keyStr = "J"
        case kVK_ANSI_K: keyStr = "K"
        case kVK_ANSI_L: keyStr = "L"
        case kVK_ANSI_M: keyStr = "M"
        case kVK_ANSI_N: keyStr = "N"
        case kVK_ANSI_O: keyStr = "O"
        case kVK_ANSI_P: keyStr = "P"
        case kVK_ANSI_Q: keyStr = "Q"
        case kVK_ANSI_R: keyStr = "R"
        case kVK_ANSI_S: keyStr = "S"
        case kVK_ANSI_T: keyStr = "T"
        case kVK_ANSI_U: keyStr = "U"
        case kVK_ANSI_V: keyStr = "V"
        case kVK_ANSI_W: keyStr = "W"
        case kVK_ANSI_X: keyStr = "X"
        case kVK_ANSI_Y: keyStr = "Y"
        case kVK_ANSI_Z: keyStr = "Z"
        case kVK_ANSI_0: keyStr = "0"
        case kVK_ANSI_1: keyStr = "1"
        case kVK_ANSI_2: keyStr = "2"
        case kVK_ANSI_3: keyStr = "3"
        case kVK_ANSI_4: keyStr = "4"
        case kVK_ANSI_5: keyStr = "5"
        case kVK_ANSI_6: keyStr = "6"
        case kVK_ANSI_7: keyStr = "7"
        case kVK_ANSI_8: keyStr = "8"
        case kVK_ANSI_9: keyStr = "9"
        case kVK_ANSI_Backslash: keyStr = "\\"
        case kVK_ANSI_Slash: keyStr = "/"
        case kVK_Space: keyStr = "Space"
        case kVK_Return: keyStr = "↩"
        case kVK_Tab: keyStr = "⇥"
        case kVK_Escape: keyStr = "⎋"
        case kVK_Delete: keyStr = "⌫"
        default:
            if let str = translateKeyCode(UInt16(keyCode)) {
                keyStr = str
            } else {
                keyStr = "Key(\(keyCode))"
            }
        }
        return "\(modStr)\(keyStr)"
    }

    public static func translateKeyCode(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let result = UCKeyTranslate(
            keyLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            4,
            &actualLength,
            &chars
        )
        if result == noErr && actualLength > 0 {
            return String(utf16CodeUnits: chars, count: actualLength).uppercased()
        }
        return nil
    }
}

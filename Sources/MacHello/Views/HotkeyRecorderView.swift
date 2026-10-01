import SwiftUI
import AppKit
import Carbon
import MacHelloCore

public struct HotkeyRecorderView: View {
    @ObservedObject private var service = MacHelloService.shared
    @State private var recordedDisplay: String = ""
    @State private var isListening: Bool = true
    var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 顶部图标与标题
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)
                    Image(systemName: "keyboard.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.accentColor)
                }

                Text(loc("Configure Auto-Fill Hotkey", "设置刷脸填密快捷键"))
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(loc("Press any modifier + key combo to record new hotkey.", "在键盘上直接按下新的快捷键组合（需包含 ⌘、⌥、⌃ 或 ⇧ 修饰键）。"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            // 当前录制/活跃热键展示卡片
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(loc("Active Hotkey:", "当前快捷键:"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(service.currentHotkeyDisplay)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.bold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        )
                }

                Text(loc("Listening for keystrokes... (Press Esc to cancel)", "正在监听键盘按键...（按 Esc 键可退出）"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)

            Divider()

            // 快捷预设一键切换
            VStack(alignment: .leading, spacing: 10) {
                Text(loc("Popular Presets:", "常用推荐预设:"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(GlobalHotkeyManager.presets) { preset in
                        Button {
                            service.setHotkey(keyCode: preset.keyCode, modifiers: preset.modifiers)
                            AudioFeedbackHelper.shared.playSuccess()
                        } label: {
                            HStack {
                                Text(preset.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                if service.currentHotkeyKeyCode == preset.keyCode && service.currentHotkeyModifiers == preset.modifiers {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(service.currentHotkeyKeyCode == preset.keyCode && service.currentHotkeyModifiers == preset.modifiers
                                          ? Color.accentColor.opacity(0.12)
                                          : Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)

            Spacer()

            // 底部操作栏
            HStack {
                Button(loc("Reset to Default (⌘\\)", "恢复默认 (⌘\\)")) {
                    service.resetHotkeyToDefault()
                    AudioFeedbackHelper.shared.playSuccess()
                }
                .buttonStyle(.link)
                .font(.callout)

                Spacer()

                Button(loc("Done", "完成")) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440, height: 380)
    }
}

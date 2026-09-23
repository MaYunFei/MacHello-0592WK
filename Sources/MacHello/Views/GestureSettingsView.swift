import SwiftUI
import MacHelloCore

public struct GestureSettingsView: View {
    @ObservedObject var config = GestureConfigManager.shared
    @State private var liveGesture: HandGestureType? = nil
    @State private var lastTriggered: (gesture: HandGestureType, action: GestureActionType)? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            VStack(spacing: 4) {
                Text("隔空手势与按键映射设置")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("支持静态姿态与动态挥手轨迹，为每个手势自由绑定 macOS 快捷行为")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // 实时感应调试回显卡片
            HStack(spacing: 16) {
                Image(systemName: liveGesture?.icon ?? "hand.raised")
                    .font(.system(size: 28))
                    .foregroundColor(liveGesture != nil ? .blue : .secondary)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(liveGesture != nil ? "实时检测到: \(liveGesture!.displayName)" : "摄像头正静默守候手势...")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(liveGesture != nil ? .primary : .secondary)

                    if let last = lastTriggered {
                        Text("最近触发: \(last.gesture.displayName) ➔ \(last.action.displayName)")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else {
                        Text("对着摄像头尝试伸手做个手势即可实时测试")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 键鼠活跃防护选项
            Toggle(isOn: Binding(
                get: { config.isTypingProtectionEnabled },
                set: { config.setTypingProtection($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("智能键鼠活跃防误触")
                        .font(.body)
                    Text("打字、敲击键盘或移动鼠标时自动暂停手势运算，避免工作时误触发，同时节约电量")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            Divider()

            // 手势映射列表
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(HandGestureType.allCases) { gesture in
                        gestureRow(for: gesture)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 280)

            Divider()

            // 底部操作栏
            HStack {
                Button("恢复默认映射") {
                    config.resetToDefaults()
                }
                Spacer()
                Button("关闭") {
                    GestureSettingsWindowController.shared.closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 500)
        .onAppear {
            GestureActionManager.shared.onLiveGestureDetected = { g in
                self.liveGesture = g
            }
            GestureActionManager.shared.onGestureTriggered = { g, a in
                self.lastTriggered = (g, a)
            }
        }
    }

    @ViewBuilder
    private func gestureRow(for gesture: HandGestureType) -> some View {
        let rule = config.rule(for: gesture)

        HStack(spacing: 12) {
            Image(systemName: gesture.icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(gesture.displayName)
                .font(.subheadline)
                .frame(width: 190, alignment: .leading)

            Spacer()

            Picker("", selection: Binding(
                get: { rule.action },
                set: { newAction in
                    config.updateRule(for: gesture, action: newAction, appName: rule.appName)
                }
            )) {
                ForEach(GestureActionType.allCases) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            if rule.action == .launchApp {
                TextField("App 名", text: Binding(
                    get: { rule.appName },
                    set: { newApp in
                        config.updateRule(for: gesture, action: rule.action, appName: newApp)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }
        }
        .padding(.vertical, 2)
    }
}

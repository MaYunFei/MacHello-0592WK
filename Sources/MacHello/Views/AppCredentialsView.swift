import SwiftUI
import AppKit
import MacHelloCore

public struct AppCredentialsView: View {
    @ObservedObject private var manager = AppCredentialManager.shared
    @State private var isShowingAddSheet: Bool = false
    @State private var runningApps: [RunningAppInfo] = []
    @State private var statusMessage: String?
    var onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            headerView

            Divider()

            // 主列表区
            if manager.rules.isEmpty {
                emptyStateView
            } else {
                rulesListView
            }

            Divider()

            // 底部操作栏
            footerView
        }
        .frame(width: 580, height: 460)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            refreshRunningApps()
            // 每次打开管理窗口时，自动运行一次被动卸载孤儿凭据检查
            let orphaned = manager.cleanOrphanedAppCredentials()
            if !orphaned.isEmpty {
                statusMessage = loc("Cleaned up orphaned credentials for uninstalled apps.", "已自动清理 \(orphaned.count) 个已卸载应用的残留凭据。")
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddAppCredentialSheet(
                onDismiss: { isShowingAddSheet = false },
                onSaved: {
                    isShowingAddSheet = false
                    statusMessage = loc("App credential saved successfully.", "应用专属凭据已安全保存到钥匙串 ✓")
                }
            )
        }
    }

    // MARK: - 顶部视图
    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: "lock.app.dashed")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(loc("App-Specific Credentials", "应用专属密码管理 (Bitwarden 等)"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(loc("Credentials are encrypted in macOS Keychain. Injected automatically via Face ID upon hotkey or window focus.", "凭据在系统钥匙串中以 Bundle ID 物理隔离。在对应应用中刷脸后自动注入。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                refreshRunningApps()
                isShowingAddSheet = true
            }) {
                Label(loc("Add App", "添加应用"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "shield.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text(loc("No Custom App Credentials Configured", "尚未配置任何第三方应用专属凭据"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(loc("Click 'Add App' above to configure independent credentials for apps like Bitwarden, 1Password, or WeChat.", "点击右上角「添加应用」，为 Bitwarden、1Password 或微信等应用设置独立解锁密码。\n快捷键刷脸时将智能识别并自动填入对应密码。"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - 规则列表视图
    private var rulesListView: some View {
        List {
            ForEach(manager.rules) { rule in
                appRuleRow(for: rule)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - 单条规则行
    @ViewBuilder
    private func appRuleRow(for rule: AppCredentialRule) -> some View {
        let isInstalled = manager.checkAppInstalled(bundleId: rule.bundleId).installed

        HStack(spacing: 12) {
            // 应用图标
            if let icon = getAppIcon(for: rule.bundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.secondary)
            }

            // 应用名称与 Bundle ID
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.appName)
                        .font(.system(size: 13, weight: .semibold))

                    if isInstalled {
                        Text(loc("Installed ✓", "已安装 ✓"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(4)
                    } else {
                        Text(loc("Uninstalled ⚠️", "未在系统中找到 (已卸载) ⚠️"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                    }
                }

                Text(rule.bundleId)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 开关组
            VStack(alignment: .trailing, spacing: 4) {
                Toggle(loc("Auto Enter", "自动回车"), isOn: Binding(
                    get: { rule.autoConfirm },
                    set: { newVal in
                        manager.updateRuleOptions(bundleId: rule.bundleId, autoConfirm: newVal, isAutoUnlockEnabled: rule.isAutoUnlockEnabled)
                    }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle(loc("Auto Focus Unlock", "前台激活自动解锁"), isOn: Binding(
                    get: { rule.isAutoUnlockEnabled },
                    set: { newVal in
                        manager.updateRuleOptions(bundleId: rule.bundleId, autoConfirm: rule.autoConfirm, isAutoUnlockEnabled: newVal)
                    }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }

            // 删除按钮 (主动物理删除)
            Button(action: {
                manager.deleteRule(bundleId: rule.bundleId)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(loc("Delete credential and remove from Keychain", "彻底删除该应用规则并抹除钥匙串密码"))
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 底部操作栏
    private var footerView: some View {
        HStack {
            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text(loc("Global Hotkey (⌘\\) will automatically select credentials based on frontmost app.", "在任何地方按下 ⌘\\，MacHello 将根据前台应用自动匹配对应密码。"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(loc("Clean Orphaned", "清理已卸载残留")) {
                let cleaned = manager.cleanOrphanedAppCredentials()
                if cleaned.isEmpty {
                    statusMessage = loc("No orphaned app credentials found.", "所有配置的应用均正常存在，无残留。")
                } else {
                    statusMessage = loc("Cleaned \(cleaned.count) orphaned credentials.", "已清理 \(cleaned.count) 个失效应用的残留密码。")
                }
            }
            .controlSize(.small)

            Button(loc("Done", "完成")) {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - 辅助方法
    private func refreshRunningApps() {
        self.runningApps = manager.runningGUIApplications()
    }

    private func getAppIcon(for bundleId: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

// MARK: - 添加应用凭据弹窗 (Sheet) - App Grid 卡片墙直选模式
struct AddAppCredentialSheet: View {
    var onDismiss: () -> Void
    var onSaved: () -> Void

    @State private var runningApps: [RunningAppInfo] = []
    @State private var selectedBundleId: String = ""
    @State private var customBundleId: String = ""
    @State private var customAppName: String = ""
    @State private var customAppIcon: NSImage?
    @State private var passwordInput: String = ""
    @State private var isPasswordVisible: Bool = false
    @State private var autoConfirm: Bool = true
    @State private var isAutoUnlockEnabled: Bool = false
    @State private var errorMessage: String?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 85, maximum: 100), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 14) {
            // 顶部标题与关闭
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Add App-Specific Password", "添加应用专属凭据"))
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(loc("Click any running app below to select instantly, or browse in Finder.", "点击下方正在运行的应用图标直接选中，或从访达浏览。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }

            // 1. 应用卡片网格直选区
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(loc("Running Applications (\(runningApps.count))", "正在运行的应用 (\(runningApps.count) 个可直选)"))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Button(action: loadRunningApps) {
                        Label(loc("Refresh", "刷新"), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }

                // 卡片滚动网格
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: gridColumns, spacing: 10) {
                        ForEach(runningApps) { app in
                            appCard(app: app)
                        }

                        // 访达浏览卡片 (常驻网格末尾)
                        browseFinderCard
                    }
                    .padding(6)
                }
                .frame(height: 165)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            // 当前选中的应用横幅
            if !customBundleId.isEmpty {
                HStack(spacing: 10) {
                    if let icon = customAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 28, height: 28)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(customAppName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(loc("Selected ✓", "已选择 ✓"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.green)
                        }
                        Text(customBundleId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            } else {
                HStack {
                    Image(systemName: "hand.tap.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(loc("Please tap an app icon above to select it.", "请点击上方任意应用卡片直接选中"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            // 2. 凭据输入
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("2. Enter App Unlock Credential", "2. 录入应用解锁凭据 (密码或 PIN)"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    if isPasswordVisible {
                        TextField(loc("Password or PIN", "输入该应用的主密码或 PIN 码"), text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(loc("Password or PIN", "输入该应用的主密码或 PIN 码"), text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { isPasswordVisible.toggle() }) {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text(loc("Recommended: Enter the master password (e.g. for Bitwarden) for cold-start & full-session unlock, or a fast-unlock PIN.", "建议：推荐直接填入主密码（如 Bitwarden 主密码），以支持冷启动与全场景解锁；若已开启 PIN 码，亦可填入快速 PIN。"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // 3. 行为选项
            VStack(alignment: .leading, spacing: 6) {
                Toggle(loc("Auto-Confirm: Automatically simulate Enter key after pasting", "自动回车：密码注入后自动模拟敲击回车直接解锁"), isOn: $autoConfirm)
                    .controlSize(.small)

                Toggle(loc("Auto-Unlock: Automatically trigger Face ID when switching to this app", "前台感知：切换至该应用且检测到锁定密码框时，自动触发刷脸解锁"), isOn: $isAutoUnlockEnabled)
                    .controlSize(.small)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            // 底部按钮
            HStack {
                Button(loc("Cancel", "取消")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(loc("Save to Keychain", "安全保存到钥匙串")) {
                    saveCredential()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(customBundleId.isEmpty || passwordInput.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
        .onAppear {
            loadRunningApps()
        }
    }

    // 单个应用卡片组件
    @ViewBuilder
    private func appCard(app: RunningAppInfo) -> some View {
        let isSelected = selectedBundleId.lowercased() == app.bundleId.lowercased()

        Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                selectedBundleId = app.bundleId
                customBundleId = app.bundleId
                customAppName = app.name
                customAppIcon = app.icon
            }
        }) {
            VStack(spacing: 5) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 36, height: 36)
                        .foregroundColor(.secondary)
                }

                Text(app.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(height: 72)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.windowBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // 访达选择卡片
    private var browseFinderCard: some View {
        Button(action: selectAppFromFinder) {
            VStack(spacing: 5) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 36)

                Text(loc("Browse...", "访达选择..."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(height: 72)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    private func loadRunningApps() {
        self.runningApps = AppCredentialManager.shared.runningGUIApplications()
    }

    private func selectAppFromFinder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = loc("Select", "选择应用")

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                self.selectedBundleId = bid
                self.customBundleId = bid
                self.customAppName = bundle.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                self.customAppIcon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                let appName = url.deletingPathExtension().lastPathComponent
                self.selectedBundleId = appName
                self.customBundleId = appName
                self.customAppName = appName
                self.customAppIcon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }

    private func saveCredential() {
        guard !customBundleId.isEmpty else {
            errorMessage = loc("Please select an application first.", "请先选择目标应用程序。")
            return
        }
        guard !passwordInput.isEmpty else {
            errorMessage = loc("Please enter a password.", "请输入解锁凭据。")
            return
        }

        let success = AppCredentialManager.shared.addOrUpdateRule(
            bundleId: customBundleId,
            appName: customAppName,
            password: passwordInput,
            autoConfirm: autoConfirm,
            isAutoUnlockEnabled: isAutoUnlockEnabled
        )

        if success {
            onSaved()
        } else {
            errorMessage = loc("Failed to save to Keychain. Please verify permissions.", "保存到系统钥匙串失败，请检查钥匙串授权。")
        }
    }
}

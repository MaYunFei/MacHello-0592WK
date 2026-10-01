import SwiftUI
import AppKit
import MacHelloCore

@main
struct MacHelloApp: App {
    @StateObject private var service = MacHelloService.shared
    @ObservedObject private var lang = LanguageManager.shared

    init() {
        // 设置点击通知横幅直接打开通行抓拍历史
        SystemNotifier.shared.onNotificationClicked = {
            AuditHistoryWindowController.shared.showWindow()
        }

        // 首次打开或未确认硬件时，自动弹出硬件自检与设备确认向导
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !UserDefaults.standard.bool(forKey: "com.machello.hardwareVerified") {
                DiagnosticWindowController.shared.showWindow()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra(
            "MacHello",
            systemImage: service.isDeviceConnected ? "faceid" : "person.crop.circle.badge.exclamationmark"
        ) {
            // 1. 状态摘要与设备连接概览
            Section {
                if service.isNetworkModeEnabled {
                    if !service.isLinuxServerReachable {
                        Label(loc("Disconnected from Linux server", "未连接到 Linux 服务端"), systemImage: "wifi.exclamationmark")
                    } else if !service.isLinuxConnected {
                        Label(loc("Linux server online (camera not found)", "Linux 服务端在线 (未检测到摄像头)"), systemImage: "exclamationmark.triangle")
                    } else {
                        Label(loc("Linux gateway ready (\(service.linuxLatencyMs) ms)", "Linux 局域网硬件已就绪 (\(service.linuxLatencyMs) ms)"), systemImage: "network")
                    }
                } else {
                    if service.isDeviceConnected {
                        Label(loc("Dell CN-0592WK (USB Direct)", "Dell CN-0592WK (USB 直连)"), systemImage: "checkmark.circle.fill")
                    } else {
                        Label(loc("0592WK camera not found", "未检测到 0592WK 摄像头"), systemImage: "xmark.circle")
                    }
                }

                if service.isEnrolled {
                    Label(loc("\(service.enrolledSamplesCount) face sample sets enrolled", "已录入 \(service.enrolledSamplesCount) 组面容特征"), systemImage: "faceid")
                } else {
                    Label(loc("Face ID: Not enrolled", "面容 ID: 尚未录入数据"), systemImage: "person.crop.circle.badge.plus")
                }

                if service.isNetworkModeEnabled && service.isAutoDisplayEnabled {
                    if service.isOwnerVerified {
                        Label(loc("Presence: Owner present", "实时状态：机主在位"), systemImage: "person.fill.checkmark")
                    } else if service.isPersonPresent {
                        Label(loc("Presence: Person in view", "实时状态：有人在视野内"), systemImage: "person.fill")
                    } else {
                        Label(loc("Presence: Nobody in view", "实时状态：桌前无人"), systemImage: "person.slash")
                    }
                }
            }

            Divider()

            // 2. 部署模式与镜头朝向
            Menu(loc("Mode: \(service.isNetworkModeEnabled ? "Linux Gateway" : "USB Direct")", "工作模式: \(service.isNetworkModeEnabled ? "局域网 Linux" : "本机 USB 直连")")) {
                Button {
                    if service.isNetworkModeEnabled { service.toggleNetworkMode() }
                } label: {
                    HStack {
                        Text(loc("USB Direct (Lock on idle + 0.5s Face ID on wake)", "本机 USB 直连 (无操作锁屏 + 唤醒瞬间 0.5s 刷脸)"))
                        if !service.isNetworkModeEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    if !service.isNetworkModeEnabled { service.toggleNetworkMode() }
                } label: {
                    HStack {
                        Text(loc("Linux Gateway (24/7 presence sensing + 0 green dot)", "局域网 Linux 智能服务 (全天候 24h 人体感应 + 0 绿点)"))
                        if service.isNetworkModeEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                if service.isNetworkModeEnabled {
                    Divider()
                    Text(loc("Server: \(service.linuxServerURL)", "服务端: \(service.linuxServerURL)"))
                    Button(loc("Configure Linux Server URL", "配置 Linux 服务端地址")) {
                        service.promptForLinuxServerURL()
                    }
                    if service.isLinuxConnected {
                        Button(loc("View Live Stream in Browser", "在浏览器中查看实时监控流")) {
                            if let url = URL(string: "\(service.linuxServerURL)/stream") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Toggle(loc("Inverted Mount Mode (Rotate 180°)", "倒置安装模式 (旋转 180°)"), isOn: Binding(
                get: { service.isCameraInverted },
                set: { _ in service.toggleCameraInverted() }
            ))

            Divider()

            // 3. 屏幕电源与自动化感应
            Toggle(
                service.isNetworkModeEnabled
                    ? loc("Linux Smart Presence (Walk-away sleep / Approach wake)", "局域网智能感应 (走开息屏 / 来人亮屏)")
                    : loc("Auto Lock on Idle (BLEUnlock mode)", "无操作自动锁屏 (BLEUnlock 模式)"),
                isOn: Binding(
                    get: { service.isAutoDisplayEnabled },
                    set: { _ in service.toggleAutoDisplay() }
                )
            )
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            if service.isAutoDisplayEnabled {
                Toggle(service.mediaPlaybackMenuTitle, isOn: Binding(
                    get: { service.respectMediaPlayback },
                    set: { _ in service.toggleRespectMediaPlayback() }
                ))

                Menu(idleLockTimeoutTitle) {
                    let timeouts: [(TimeInterval, String)] = [
                        (15, loc("15 seconds (Quick test)", "15 秒 (测试快速体验)")),
                        (30, loc("30 seconds (Recommended test)", "30 秒 (测试推荐)")),
                        (60, loc("1 minute", "1 分钟")),
                        (180, loc("3 minutes", "3 分钟")),
                        (300, loc("5 minutes (Daily recommended)", "5 分钟 (日常推荐)")),
                        (600, loc("10 minutes", "10 分钟"))
                    ]
                    ForEach(timeouts, id: \.0) { sec, title in
                        Button {
                            service.setAbsenceTimeout(sec)
                        } label: {
                            HStack {
                                Text(title)
                                if service.absenceTimeout == sec {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            // 4. 面容与硬件管理向导
            Button {
                DiagnosticWindowController.shared.showWindow()
            } label: {
                Label(loc("Hardware Diagnostics & Setup", "硬件自检与设备确认"), systemImage: "wrench.and.screwdriver")
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Button {
                service.refreshStatus()
                EnrollmentWindowController.shared.showWindow()
            } label: {
                Label(
                    service.isEnrolled
                        ? loc("Re-enroll / Add Alternative Appearance", "重新录入 / 添加替用外观")
                        : loc("Set Up Face ID", "设置面容 ID"),
                    systemImage: "person.crop.circle.badge.plus"
                )
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Button {
                service.toggleIRTest()
            } label: {
                Label(
                    service.isIRActive
                        ? loc("Turn Off IR Test LED", "熄灭红外测试灯")
                        : loc("Turn On IR Test LED", "点亮红外测试灯"),
                    systemImage: service.isIRActive ? "moon.stars.fill" : "moon.stars"
                )
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Divider()

            // 5. 权限提权与全场景免密
            Toggle(loc("Terminal Sudo Face ID Unlock", "终端 Sudo 刷脸免密提权"), isOn: Binding(
                get: { service.isPAMInstalled },
                set: { _ in service.togglePAMInstallation() }
            ))

            Toggle(loc("Hotkey Auto-Fill Password (\(service.currentHotkeyDisplay))", "快捷键刷脸填充密码 (\(service.currentHotkeyDisplay))"), isOn: Binding(
                get: { service.isGlobalHotkeyFillEnabled },
                set: { _ in service.toggleGlobalHotkeyFill() }
            ))

            if service.isGlobalHotkeyFillEnabled {
                Menu(loc("Shortcut: \(service.currentHotkeyDisplay)", "填密快捷键: \(service.currentHotkeyDisplay)")) {
                    ForEach(GlobalHotkeyManager.presets) { preset in
                        Button {
                            service.setHotkey(keyCode: preset.keyCode, modifiers: preset.modifiers)
                        } label: {
                            HStack {
                                Text(preset.title)
                                if service.currentHotkeyKeyCode == preset.keyCode && service.currentHotkeyModifiers == preset.modifiers {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(loc("Record Custom Shortcut...", "录制自定义快捷键...")) {
                        HotkeyRecorderWindowController.shared.showWindow()
                    }
                }
            }

            Menu(loc("Full Face ID Auto-Auth Settings", "全场景 Face ID 自动免密授权")) {
                Toggle(loc("Admin Prompt Face ID Auto-Auth", "应用管理员弹窗 Face ID 自动认证"), isOn: Binding(
                    get: { service.isAppAuthEnabled },
                    set: { _ in service.toggleAppAuth() }
                ))

                if service.isAppAuthEnabled {
                    Menu(service.isAdminPromptAutoConfirm
                        ? loc("Elevation: Fast (Auto-Confirm)", "提权确认方式: 极速模式 (直接确认)")
                        : loc("Elevation: Safe (Manual Return)", "提权确认方式: 安全模式 (手动按回车)")) {
                        Button {
                            if !service.isAdminPromptAutoConfirm { service.toggleAdminPromptAutoConfirm() }
                        } label: {
                            HStack {
                                Text(loc("Fast Mode (Fill & Auto-Confirm)", "极速模式 (自动填入并直接确认)"))
                                if service.isAdminPromptAutoConfirm { Image(systemName: "checkmark") }
                            }
                        }

                        Button {
                            if service.isAdminPromptAutoConfirm { service.toggleAdminPromptAutoConfirm() }
                        } label: {
                            HStack {
                                Text(loc("Safe Mode (Fill Only, Manual Return)", "安全模式 (自动填入密码，手动按回车)"))
                                if !service.isAdminPromptAutoConfirm { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }

                Toggle(loc("Lock Screen Auto-Unlock on Wake", "锁屏感应唤醒自动解锁进桌面"), isOn: Binding(
                    get: { service.isLockScreenUnlockEnabled },
                    set: { _ in service.toggleLockScreenUnlock() }
                ))

                Toggle(loc("Play Sound on Face ID Success", "播放 Face ID 认证成功提示音"), isOn: Binding(
                    get: { service.isAudioFeedbackEnabled },
                    set: { _ in service.toggleAudioFeedback() }
                ))

                Button(loc("Play Test Success Sound", "试听认证提示音")) {
                    service.playTestAudio()
                }

                Divider()

                Button(loc("App-Specific Credentials (Bitwarden etc.)...", "🔐 应用专属密码管理 (Bitwarden 等)...")) {
                    AppCredentialsWindowController.shared.showWindow()
                }

                Divider()

                if service.hasStoredPassword {
                    Text(loc("Keychain Password: Saved ✓", "钥匙串密码：已安全保存 ✓"))
                    Button(loc("Verify / Authorize Keychain Access", "🔑 验证 / 授权钥匙串访问权限")) {
                        service.verifyKeychainAccess()
                    }
                    Button(loc("Update Keychain Password", "更新钥匙串密码")) {
                        service.promptToStorePassword()
                    }
                    Button(loc("Remove Saved Password", "清除保存的密码")) {
                        service.deleteStoredPassword()
                    }
                } else {
                    Button(loc("Set Unlock Password in Keychain", "设置钥匙串免密解锁密码")) {
                        service.promptToStorePassword()
                    }
                }

                Divider()

                if service.isAccessibilityTrusted {
                    Text(loc("Accessibility Permission: Granted ✓", "辅助功能权限：已获得 ✓"))
                } else {
                    Button(loc("Grant Accessibility Permission", "授予辅助功能权限 (打开系统设置)")) {
                        service.openAccessibilitySettings()
                    }
                }

                Divider()

                Button(service.isPromptTestRunning
                    ? loc("Testing Admin Prompt...", "正在测试管理员提权弹窗...")
                    : loc("Test Admin Prompt (Face ID)", "测试管理员提权弹窗 (Face ID)")) {
                    service.triggerAdminPromptTest()
                }
                .disabled(service.isPromptTestRunning)

                Button(loc("View Access & Snapshot History", "查看通行抓拍与识别历史")) {
                    AuditHistoryWindowController.shared.showWindow()
                }
            }

            // 6. 系统开机启动、语言与退出
            Toggle(loc("Launch at Login", "登录时自动启动 (开机自启)"), isOn: Binding(
                get: { service.isLaunchAtLoginEnabled },
                set: { _ in service.toggleLaunchAtLogin() }
            ))

            Menu(loc("Language: \(lang.currentDisplayName)", "界面语言: \(lang.currentDisplayName)")) {
                ForEach(AppLanguage.allCases) { item in
                    Button {
                        lang.selectedLanguage = item
                    } label: {
                        HStack {
                            Text(item.title)
                            if lang.selectedLanguage == item {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            if service.isEnrolled {
                Button(role: .destructive) {
                    service.clearFaceData()
                } label: {
                    Label(loc("Clear Local Face Data", "清除本地面容数据"), systemImage: "trash")
                }
            }

            Button(role: .destructive) {
                service.requestCompleteUninstall()
            } label: {
                Label(loc("Uninstall MacHello & Erase All Data...", "🧹 彻底卸载 MacHello 并抹除所有数据..."), systemImage: "trash.slash")
            }

            Button(loc("Quit MacHello", "退出 MacHello")) {
                EnrollmentWindowController.shared.closeWindow()
                DiagnosticWindowController.shared.closeWindow()
                AuditHistoryWindowController.shared.closeWindow()
                IRController.shared.resetToRGB()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }

    private var idleLockTimeoutTitle: String {
        let sec = Int(service.absenceTimeout)
        if sec < 60 {
            return loc("Idle Lock Timeout: \(sec)s", "无操作锁屏等待时长: \(sec) 秒")
        } else if sec % 60 == 0 {
            let mins = sec / 60
            let enUnit = mins == 1 ? "1 minute" : "\(mins) minutes"
            return loc("Idle Lock Timeout: \(enUnit)", "无操作锁屏等待时长: \(mins) 分钟")
        } else {
            let mins = sec / 60
            let rem = sec % 60
            return loc("Idle Lock Timeout: \(mins)m \(rem)s", "无操作锁屏等待时长: \(mins) 分 \(rem) 秒")
        }
    }
}

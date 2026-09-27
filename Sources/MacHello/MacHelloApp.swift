import SwiftUI
import AppKit
import MacHelloCore

@main
struct MacHelloApp: App {
    @StateObject private var service = MacHelloService.shared

    init() {
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
                        Label("未连接到 Linux 服务端", systemImage: "wifi.exclamationmark")
                    } else if !service.isLinuxConnected {
                        Label("Linux 服务端在线 (未检测到摄像头)", systemImage: "exclamationmark.triangle")
                    } else {
                        Label("Linux 局域网硬件已就绪 (\(service.linuxLatencyMs) ms)", systemImage: "network")
                    }
                } else {
                    if service.isDeviceConnected {
                        Label("Dell CN-0592WK (USB 直连)", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("未检测到 0592WK 摄像头", systemImage: "xmark.circle")
                    }
                }

                if service.isEnrolled {
                    Label("已录入 \(service.enrolledSamplesCount) 组面容特征", systemImage: "faceid")
                } else {
                    Label("面容 ID: 尚未录入数据", systemImage: "person.crop.circle.badge.plus")
                }

                if service.isNetworkModeEnabled && service.isAutoDisplayEnabled {
                    if service.isOwnerVerified {
                        Label("实时状态：机主在位", systemImage: "person.fill.checkmark")
                    } else if service.isPersonPresent {
                        Label("实时状态：有人在视野内", systemImage: "person.fill")
                    } else {
                        Label("实时状态：桌前无人", systemImage: "person.slash")
                    }
                }
            }

            Divider()

            // 2. 部署模式与镜头朝向
            Menu("工作模式: \(service.isNetworkModeEnabled ? "局域网 Linux" : "本机 USB 直连")") {
                Button {
                    if service.isNetworkModeEnabled { service.toggleNetworkMode() }
                } label: {
                    HStack {
                        Text("本机 USB 直连 (无操作锁屏 + 唤醒瞬间 0.5s 刷脸)")
                        if !service.isNetworkModeEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    if !service.isNetworkModeEnabled { service.toggleNetworkMode() }
                } label: {
                    HStack {
                        Text("局域网 Linux 智能服务 (全天候 24h 人体感应 + 0 绿点)")
                        if service.isNetworkModeEnabled {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                if service.isNetworkModeEnabled {
                    Divider()
                    Text("服务端: \(service.linuxServerURL)")
                    Button("配置 Linux 服务端地址") {
                        service.promptForLinuxServerURL()
                    }
                    if service.isLinuxConnected {
                        Button("在浏览器中查看实时监控流") {
                            if let url = URL(string: "\(service.linuxServerURL)/stream") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Toggle("倒置安装模式 (旋转 180°)", isOn: Binding(
                get: { service.isCameraInverted },
                set: { _ in service.toggleCameraInverted() }
            ))

            Divider()

            // 3. 屏幕电源与自动化感应
            Toggle(
                service.isNetworkModeEnabled ? "局域网智能感应 (走开息屏 / 来人亮屏)" : "无操作自动锁屏 (BLEUnlock 模式)",
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

                Menu("无操作锁屏等待时长: \(Int(service.absenceTimeout)) 秒") {
                    let timeouts: [(TimeInterval, String)] = [
                        (15, "15 秒 (测试快速体验)"),
                        (30, "30 秒 (测试推荐)"),
                        (60, "1 分钟"),
                        (180, "3 分钟"),
                        (300, "5 分钟 (日常推荐)"),
                        (600, "10 分钟")
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
                Label("硬件自检与设备确认", systemImage: "wrench.and.screwdriver")
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Button {
                service.refreshStatus()
                EnrollmentWindowController.shared.showWindow()
            } label: {
                Label(service.isEnrolled ? "重新录入 / 添加替用外观" : "设置面容 ID", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Button {
                service.toggleIRTest()
            } label: {
                Label(service.isIRActive ? "熄灭红外测试灯" : "点亮红外测试灯", systemImage: service.isIRActive ? "moon.stars.fill" : "moon.stars")
            }
            .disabled(!service.isDeviceConnected && !service.isNetworkModeEnabled)

            Divider()

            // 5. 权限提权与全场景免密
            Toggle("终端 Sudo 刷脸免密提权", isOn: Binding(
                get: { service.isPAMInstalled },
                set: { _ in service.togglePAMInstallation() }
            ))

            Menu("全场景 Face ID 自动免密授权") {
                Toggle("应用管理员弹窗 Face ID 自动认证", isOn: Binding(
                    get: { service.isAppAuthEnabled },
                    set: { _ in service.toggleAppAuth() }
                ))

                Toggle("锁屏感应唤醒自动解锁进桌面", isOn: Binding(
                    get: { service.isLockScreenUnlockEnabled },
                    set: { _ in service.toggleLockScreenUnlock() }
                ))

                Toggle("播放 Face ID 认证成功提示音", isOn: Binding(
                    get: { service.isAudioFeedbackEnabled },
                    set: { _ in service.toggleAudioFeedback() }
                ))

                Button("试听认证提示音") {
                    service.playTestAudio()
                }

                Divider()

                if service.hasStoredPassword {
                    Text("钥匙串密码：已安全保存 ✓")
                    Button("更新钥匙串密码") {
                        service.promptToStorePassword()
                    }
                    Button("清除保存的密码") {
                        service.deleteStoredPassword()
                    }
                } else {
                    Button("设置钥匙串免密解锁密码") {
                        service.promptToStorePassword()
                    }
                }

                Divider()

                if service.isAccessibilityTrusted {
                    Text("辅助功能权限：已获得 ✓")
                } else {
                    Button("授予辅助功能权限 (打开系统设置)") {
                        service.openAccessibilitySettings()
                    }
                }

                Divider()

                Button("测试管理员提权弹窗 (Face ID)") {
                    service.triggerAdminPromptTest()
                }

                Button("查看通行抓拍与识别历史") {
                    AuditHistoryWindowController.shared.showWindow()
                }
            }

            // 6. 系统开机启动与退出
            Toggle("登录时自动启动 (开机自启)", isOn: Binding(
                get: { service.isLaunchAtLoginEnabled },
                set: { _ in service.toggleLaunchAtLogin() }
            ))

            Divider()

            if service.isEnrolled {
                Button(role: .destructive) {
                    service.clearFaceData()
                } label: {
                    Label("清除本地面容数据", systemImage: "trash")
                }
            }

            Button("退出 MacHello") {
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
}

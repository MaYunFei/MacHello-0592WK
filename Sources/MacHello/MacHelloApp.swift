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
        MenuBarExtra("MacHello", systemImage: service.isDeviceConnected ? "faceid" : "person.crop.circle.badge.exclamationmark") {
            VStack(alignment: .leading, spacing: 6) {
                // 1. 设备与部署状态
                HStack {
                    Circle()
                        .fill(service.isNetworkModeEnabled ? (service.isLinuxConnected ? Color.green : Color.orange) : (service.isDeviceConnected ? Color.green : Color.red))
                        .frame(width: 8, height: 8)
                    if service.isNetworkModeEnabled {
                        Text(service.isLinuxConnected ? "Linux 局域网服务已连接 (\(service.linuxLatencyMs)ms)" : "Linux 局域网服务连接中/离线")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(service.isDeviceConnected ? "Dell 0592WK (本机 USB 直连)" : "未检测到本机 0592WK 摄像头")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Image(systemName: service.isEnrolled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(service.isEnrolled ? .blue : .secondary)
                    Text(service.isEnrolled ? "已录入 \(service.enrolledSamplesCount) 组面容特征" : "尚未录入面容数据")
                        .font(.caption)
                }

                Divider()

                // 2. 部署工作模式选择
                Menu("工作模式: \(service.isNetworkModeEnabled ? "🌐 局域网 Linux 服务" : "🔌 本机 USB 直连")") {
                    Button(action: {
                        if service.isNetworkModeEnabled { service.toggleNetworkMode() }
                    }) {
                        let prefix = !service.isNetworkModeEnabled ? "✓ " : "   "
                        Text(prefix + "🔌 本机 USB 直连 (无操作锁屏 + 唤醒瞬间 0.5s 刷脸)")
                    }

                    Button(action: {
                        if !service.isNetworkModeEnabled { service.toggleNetworkMode() }
                    }) {
                        let prefix = service.isNetworkModeEnabled ? "✓ " : "   "
                        Text(prefix + "🌐 局域网 Linux 智能服务 (全天候 24h 人体感应 + 0 绿点)")
                    }

                    if service.isNetworkModeEnabled {
                        Divider()
                        Text("当前地址: \(service.linuxServerURL)")
                        Button("配置 Linux 服务端地址...") {
                            service.promptForLinuxServerURL()
                        }
                    }
                }

                // 摄像头安装朝向 (屏幕下方倒贴)
                Button(action: {
                    service.toggleCameraInverted()
                }) {
                    let prefix = service.isCameraInverted ? "✓ " : "   "
                    Text(prefix + "🙃 摄像头倒置安装模式 (旋转 180°)")
                }

                Divider()

                // 3. 屏幕电源与感应管理
                if service.isNetworkModeEnabled {
                    // 局域网 Linux 模式：全天候 24h 人体存在感应
                    Button(action: {
                        service.toggleAutoDisplay()
                    }) {
                        Text(service.isAutoDisplayEnabled ? "✓ 局域网智能感应（走开息屏 / 来人亮屏）" : "   局域网智能感应（走开息屏 / 来人亮屏）")
                    }

                    if service.isAutoDisplayEnabled {
                        // 观影/会议免打扰
                        Button(action: {
                            service.toggleRespectMediaPlayback()
                        }) {
                            Text(service.mediaPlaybackMenuTitle)
                        }

                        // 离开/无操作锁屏等待时长 (局域网模式)
                        Menu("离开/无操作锁屏等待时长: \(Int(service.absenceTimeout)) 秒") {
                            Button(action: { service.setAbsenceTimeout(15) }) {
                                Text(service.absenceTimeout == 15 ? "✓ 15 秒 (测试快速体验)" : "   15 秒 (测试快速体验)")
                            }
                            Button(action: { service.setAbsenceTimeout(30) }) {
                                Text(service.absenceTimeout == 30 ? "✓ 30 秒 (测试推荐)" : "   30 秒 (测试推荐)")
                            }
                            Button(action: { service.setAbsenceTimeout(60) }) {
                                Text(service.absenceTimeout == 60 ? "✓ 1 分钟" : "   1 分钟")
                            }
                            Button(action: { service.setAbsenceTimeout(180) }) {
                                Text(service.absenceTimeout == 180 ? "✓ 3 分钟" : "   3 分钟")
                            }
                            Button(action: { service.setAbsenceTimeout(300) }) {
                                Text(service.absenceTimeout == 300 ? "✓ 5 分钟 (日常推荐)" : "   5 分钟 (日常推荐)")
                            }
                            Button(action: { service.setAbsenceTimeout(600) }) {
                                Text(service.absenceTimeout == 600 ? "✓ 10 分钟" : "   10 分钟")
                            }
                        }

                        // 状态显示
                        if service.isOwnerVerified {
                            Text("● 实时状态：机主本人在位").font(.caption2).foregroundColor(.green)
                        } else if service.isPersonPresent {
                            Text("● 实时状态：有人在视野内").font(.caption2).foregroundColor(.blue)
                        } else {
                            Text("○ 实时状态：桌前无人").font(.caption2).foregroundColor(.secondary)
                        }

                        Text("💡 由局域网 Linux 服务器运行传感器，Mac 本机 0 摄像头开销，状态栏 0 绿点！")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // 本机 USB 直连模式：BLEUnlock 纯净模式
                    Button(action: {
                        service.toggleAutoDisplay()
                    }) {
                        Text(service.isAutoDisplayEnabled ? "✓ 无操作自动锁屏 (BLEUnlock 模式)" : "   无操作自动锁屏 (BLEUnlock 模式)")
                    }
                    .disabled(!service.isDeviceConnected)

                    if service.isAutoDisplayEnabled {
                        // 观影/会议免打扰
                        Button(action: {
                            service.toggleRespectMediaPlayback()
                        }) {
                            Text(service.mediaPlaybackMenuTitle)
                        }

                        // 无操作等待时长
                        Menu("无操作等待锁屏时长") {
                            Button(action: { service.setAbsenceTimeout(15) }) {
                                Text(service.absenceTimeout == 15 ? "✓ 15 秒 (测试快速体验)" : "   15 秒 (测试快速体验)")
                            }
                            Button(action: { service.setAbsenceTimeout(30) }) {
                                Text(service.absenceTimeout == 30 ? "✓ 30 秒 (测试推荐)" : "   30 秒 (测试推荐)")
                            }
                            Button(action: { service.setAbsenceTimeout(60) }) {
                                Text(service.absenceTimeout == 60 ? "✓ 1 分钟" : "   1 分钟")
                            }
                            Button(action: { service.setAbsenceTimeout(180) }) {
                                Text(service.absenceTimeout == 180 ? "✓ 3 分钟" : "   3 分钟")
                            }
                            Button(action: { service.setAbsenceTimeout(300) }) {
                                Text(service.absenceTimeout == 300 ? "✓ 5 分钟 (日常推荐)" : "   5 分钟 (日常推荐)")
                            }
                            Button(action: { service.setAbsenceTimeout(600) }) {
                                Text(service.absenceTimeout == 600 ? "✓ 10 分钟" : "   10 分钟")
                            }
                        }

                        Text("💡 平时摄像头 100% 彻底关闭 (0% CPU，状态栏 0 绿点)；动键鼠亮屏瞬间 0.5s 刷脸秒进桌面！")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // 3. 硬件向导与面容功能
                Button(action: {
                    DiagnosticWindowController.shared.showWindow()
                }) {
                    Label("设备自检与硬件确认向导...", systemImage: "wrench.and.screwdriver")
                }
                .disabled(!service.isDeviceConnected && !(service.isNetworkModeEnabled && service.isLinuxConnected))

                Button(action: {
                    service.refreshStatus()
                    EnrollmentWindowController.shared.showWindow()
                }) {
                    Label(service.isEnrolled ? "重新录入 / 添加替用外貌..." : "录入面容 ID...", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!service.isDeviceConnected && !(service.isNetworkModeEnabled && service.isLinuxConnected))

                Button(action: {
                    service.toggleIRTest()
                }) {
                    Label(service.isIRActive ? "熄灭红外测试灯" : "点亮红外测试灯", systemImage: "moon.stars.fill")
                }
                .disabled(!service.isDeviceConnected && !(service.isNetworkModeEnabled && service.isLinuxConnected))

                if service.isNetworkModeEnabled && service.isLinuxConnected {
                    Button("👁️ 浏览器直接打开实时监控流...") {
                        if let url = URL(string: "\(service.linuxServerURL)/stream") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                // 4. 终端 Sudo 刷脸免密提权
                Divider()
                Button(action: {
                    service.togglePAMInstallation()
                }) {
                    let prefix = service.isPAMInstalled ? "✓ " : "   "
                    Text(prefix + (service.isPAMInstalled ? "终端 Sudo 刷脸免密提权 (已启用·点击卸载)" : "终端 Sudo 刷脸免密提权 (点击一键配置)"))
                }

                // 5. 锁屏与应用全场景 Face ID 自动免密授权
                Menu("🔐 全场景 Face ID 自动免密授权") {
                    Button(action: {
                        service.toggleAppAuth()
                    }) {
                        let prefix = service.isAppAuthEnabled ? "✓ " : "   "
                        Text(prefix + "应用管理员弹窗 Face ID 自动认证")
                    }

                    Button(action: {
                        service.toggleLockScreenUnlock()
                    }) {
                        let prefix = service.isLockScreenUnlockEnabled ? "✓ " : "   "
                        Text(prefix + "锁屏感应唤醒自动解锁进桌面")
                    }

                    Button(action: {
                        service.toggleAudioFeedback()
                    }) {
                        let prefix = service.isAudioFeedbackEnabled ? "✓ " : "   "
                        Text(prefix + "播放 Face ID 认证成功提示音 (Tink)")
                    }

                    Button("🔊 试听认证成功提示音") {
                        service.playTestAudio()
                    }

                    Divider()

                    if service.hasStoredPassword {
                        Text("🔑 钥匙串密码: 已安全保存 ✓")
                        Button("更新钥匙串密码...") {
                            service.promptToStorePassword()
                        }
                        Button("清除保存的密码") {
                            service.deleteStoredPassword()
                        }
                    } else {
                        Button("⚠️ 设置钥匙串免密解锁密码...") {
                            service.promptToStorePassword()
                        }
                    }

                    Divider()

                    if service.isAccessibilityTrusted {
                        Text("🛡️ 辅助功能权限: 已获得 ✓")
                    } else {
                        Button("⚠️ 授予辅助功能权限 (点击打开系统设置)...") {
                            service.openAccessibilitySettings()
                        }
                    }

                    Divider()

                    Button("🧪 测试管理员提权弹窗 (Face ID)...") {
                        service.triggerAdminPromptTest()
                    }

                    Button("📸 查看人脸解锁与通行抓拍历史...") {
                        AuditHistoryWindowController.shared.showWindow()
                    }
                }

                // 6. 开机自启动
                Button(action: {
                    service.toggleLaunchAtLogin()
                }) {
                    let prefix = service.isLaunchAtLoginEnabled ? "✓ " : "   "
                    Text(prefix + "登录时自动启动 (开机自启)")
                }

                Divider()

                if service.isEnrolled {
                    Button(action: {
                        service.clearFaceData()
                    }) {
                        Label("清除本地面容数据", systemImage: "trash")
                    }
                }

                Button("退出 MacHello") {
                    EnrollmentWindowController.shared.closeWindow()
                    IRController.shared.resetToRGB()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(4)
        }
        .menuBarExtraStyle(.menu)
    }
}

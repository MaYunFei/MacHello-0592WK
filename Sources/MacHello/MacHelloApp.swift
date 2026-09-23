import SwiftUI
import AppKit
import MacHelloCore

@main
struct MacHelloApp: App {
    @StateObject private var service = MacHelloService.shared

    var body: some Scene {
        MenuBarExtra("MacHello", systemImage: service.isDeviceConnected ? "faceid" : "person.crop.circle.badge.exclamationmark") {
            VStack(alignment: .leading, spacing: 6) {
                // 1. 设备与面容状态
                HStack {
                    Circle()
                        .fill(service.isDeviceConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(service.isDeviceConnected ? "Dell 0592WK 已就绪" : "未检测到 0592WK 摄像头")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: service.isEnrolled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(service.isEnrolled ? .blue : .secondary)
                    Text(service.isEnrolled ? "已录入 \(service.enrolledSamplesCount) 组面容特征" : "尚未录入面容数据")
                        .font(.caption)
                }

                Divider()

                // 2. 人体感应总开关
                Button(action: {
                    service.toggleAutoDisplay()
                }) {
                    Text(service.isAutoDisplayEnabled ? "✓ 人体感应（走开息屏 / 来人亮屏）" : "   人体感应（走开息屏 / 来人亮屏）")
                }
                .disabled(!service.isDeviceConnected)

                if service.isAutoDisplayEnabled {
                    // 机主专属防窥鉴权
                    Button(action: {
                        service.toggleRequireOwnerVerification()
                    }) {
                        let prefix = service.requireOwnerVerification ? "✓ " : "   "
                        Text(prefix + (service.isEnrolled ? "仅限机主本人才亮屏 (防窥安全)" : "仅限机主本人才亮屏 (需先录入)"))
                    }
                    .disabled(!service.isEnrolled)

                    // 智能键鼠感知与低功耗模式
                    Button(action: {
                        service.toggleSmartIdlePowerSaving()
                    }) {
                        let prefix = service.isSmartIdlePowerSavingEnabled ? "✓ " : "   "
                        Text(prefix + "智能键鼠感知 (打字时熄灯，0% CPU)")
                    }

                    // 离席息屏时长选择子菜单
                    Menu("离席等待时长") {
                        Button(action: { service.setAbsenceTimeout(10) }) {
                            Text(service.absenceTimeout == 10 ? "✓ 10 秒 (极速体验)" : "   10 秒 (极速体验)")
                        }
                        Button(action: { service.setAbsenceTimeout(15) }) {
                            Text(service.absenceTimeout == 15 ? "✓ 15 秒 (测试推荐)" : "   15 秒 (测试推荐)")
                        }
                        Button(action: { service.setAbsenceTimeout(30) }) {
                            Text(service.absenceTimeout == 30 ? "✓ 30 秒 (日常推荐)" : "   30 秒 (日常推荐)")
                        }
                        Button(action: { service.setAbsenceTimeout(60) }) {
                            Text(service.absenceTimeout == 60 ? "✓ 1 分钟" : "   1 分钟")
                        }
                    }

                    // 实时状态静态行
                    if service.requireOwnerVerification && service.isEnrolled {
                        if service.isOwnerVerified {
                            Text("● 状态：机主本人在位").font(.caption2).foregroundColor(.green)
                        } else if service.isPersonPresent {
                            Text("● 状态：陌生人（保持黑屏）").font(.caption2).foregroundColor(.orange)
                        } else {
                            Text("○ 状态：无人").font(.caption2).foregroundColor(.secondary)
                        }
                    } else {
                        Text(service.isPersonPresent ? "● 状态：有人" : "○ 状态：无人").font(.caption2).foregroundColor(.secondary)
                    }
                }

                Divider()

                // 3. 面容录入与硬件功能
                Button(action: {
                    service.refreshStatus()
                    EnrollmentWindowController.shared.showWindow()
                }) {
                    Label(service.isEnrolled ? "重新录入 / 添加替用外貌..." : "录入面容 ID...", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!service.isDeviceConnected)

                Button(action: {
                    service.toggleIRTest()
                }) {
                    Label(service.isIRActive ? "熄灭红外测试灯" : "点亮红外测试灯", systemImage: "moon.stars.fill")
                }
                .disabled(!service.isDeviceConnected)

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

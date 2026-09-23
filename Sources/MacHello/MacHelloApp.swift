import SwiftUI
import AppKit
import MacHelloCore

@main
struct MacHelloApp: App {
    @StateObject private var service = MacHelloService.shared

    var body: some Scene {
        MenuBarExtra("MacHello", systemImage: service.isDeviceConnected ? "faceid" : "person.crop.circle.badge.exclamationmark") {
            VStack(alignment: .leading, spacing: 6) {
                // 设备连接状态
                HStack {
                    Circle()
                        .fill(service.isDeviceConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(service.isDeviceConnected ? "Dell 0592WK 已就绪" : "未检测到 0592WK 摄像头")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // 面容特征库状态
                HStack {
                    Image(systemName: service.isEnrolled ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundColor(service.isEnrolled ? .blue : .secondary)
                    Text(service.isEnrolled ? "已录入 \(service.enrolledSamplesCount) 组面容特征" : "尚未录入面容数据")
                        .font(.caption)
                }

                Divider()

                // 人体感应开关 (走开息屏 / 来人亮屏)
                Button(action: {
                    service.toggleAutoDisplay()
                }) {
                    HStack {
                        Image(systemName: service.isAutoDisplayEnabled ? "checkmark" : "")
                        Text("人体感应（走开息屏 / 来人亮屏）")
                    }
                }
                .disabled(!service.isDeviceConnected)

                // 离席息屏延时设置
                if service.isAutoDisplayEnabled {
                    Menu("离席息屏等待时长 (\(Int(service.absenceTimeout)) 秒)") {
                        Button(action: { service.setAbsenceTimeout(10) }) {
                            HStack {
                                if service.absenceTimeout == 10 { Image(systemName: "checkmark") }
                                Text("10 秒 (极速体验)")
                            }
                        }
                        Button(action: { service.setAbsenceTimeout(15) }) {
                            HStack {
                                if service.absenceTimeout == 15 { Image(systemName: "checkmark") }
                                Text("15 秒 (测试推荐)")
                            }
                        }
                        Button(action: { service.setAbsenceTimeout(30) }) {
                            HStack {
                                if service.absenceTimeout == 30 { Image(systemName: "checkmark") }
                                Text("30 秒 (日常推荐)")
                            }
                        }
                        Button(action: { service.setAbsenceTimeout(60) }) {
                            HStack {
                                if service.absenceTimeout == 60 { Image(systemName: "checkmark") }
                                Text("1 分钟")
                            }
                        }
                    }

                    // 实时状态回显
                    HStack {
                        Circle()
                            .fill(service.isPersonPresent ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(service.isPersonPresent ? "检测到位：有人" : "检测状态：无人")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // 打开面容录入窗口 (带实时红外预览与引导)
                Button(action: {
                    service.refreshStatus()
                    EnrollmentWindowController.shared.showWindow()
                }) {
                    Label(service.isEnrolled ? "重新录入 / 添加替用外貌..." : "录入面容 ID...", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!service.isDeviceConnected)

                // 硬件测试：手动点亮/熄灭红外灯
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

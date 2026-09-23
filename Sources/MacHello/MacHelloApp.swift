import SwiftUI
import MacHelloCore

@main
struct MacHelloApp: App {
    @StateObject private var service = MacHelloService.shared

    var body: some Scene {
        MenuBarExtra("MacHello", systemImage: service.isDeviceConnected ? "faceid" : "person.crop.circle.badge.exclamationmark") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(service.isDeviceConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(service.isDeviceConnected ? "Dell 0592WK 已就绪" : "未检测到 0592WK 摄像头")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                Button(action: {
                    service.toggleIRTest()
                }) {
                    Label(service.isIRActive ? "熄灭红外测试灯" : "点亮红外测试灯", systemImage: "moon.stars.fill")
                }
                .disabled(!service.isDeviceConnected)

                Button(action: {
                    service.startFaceEnrollment()
                }) {
                    Label("录入面部数据...", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!service.isDeviceConnected)

                Divider()

                Button("偏好设置...") {
                    // TODO: 打开设置面板
                }

                Divider()

                Button("退出 MacHello") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(4)
        }
        .menuBarExtraStyle(.menu)
    }
}

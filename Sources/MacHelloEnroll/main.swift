import Foundation
import MacHelloCore
import AppKit

final class EnrollmentCLIHandler: FaceEnrollmentDelegate {
    let sema = DispatchSemaphore(value: 0)
    var isWaitingForNextStage = false

    func enrollmentDidUpdateInstruction(stage: EnrollmentStage, pose: TargetPose, progress: Double, message: String) {
        let percent = Int(progress * 100)
        let totalBars = 8
        let filledBars = Int(progress * Double(totalBars))
        let bar = String(repeating: "🟢", count: filledBars) + String(repeating: "⚪️", count: totalBars - filledBars)

        print("\r  [\(bar)] \(percent)%  \(message)      ", terminator: "")
        fflush(stdout)
    }

    func enrollmentDidCapturePose(stage: EnrollmentStage, pose: TargetPose) {
        NSSound.beep()
        print("\n  ✅ 已捕捉角度: [\(pose.rawValue)]")
    }

    func enrollmentStageDidComplete(stage: EnrollmentStage) {
        print("\n\n🎉 阶段完成: 【\(stage.rawValue)】已成功录入！")
        sema.signal()
    }

    func enrollmentDidFinishAll(totalSamples: Int) {
        print("""

======================================================
  ✨ 面容 ID 全部录入成功！
  - 录入特征样本总数: \(totalSamples) 个
  - 包含外观: 日常/佩戴眼镜外观 + 脱镜/替用外观
  - 数据安全保存在: ~/.machello/faces.json
======================================================
""")
    }

    func enrollmentDidFail(error: String) {
        print("\n❌ 录入失败: \(error)")
        sema.signal()
    }
}

print("""
======================================================
  🍏 MacHello 面容 ID 红外录入向导
  - 硬件: Dell 0592WK (0bda:5767) 硬件双目红外模组
  - 核心: Apple Neural Engine (NPU) 原生 128 维特征提取
  - 特性: 仿 iPhone 环形头姿引导 + 戴镜/脱镜双外观录入
======================================================
""")

let irController = IRController.shared
guard irController.isConnected else {
    print("❌ 错误: 未检测到戴尔 0592WK 摄像头模组，请检查 USB 连接。")
    exit(1)
}

// 退出信号保护
signal(SIGINT) { _ in
    print("\n\n🛑 录入已中断，正在安全复位硬件...")
    FaceEnrollmentService.shared.stopEnrollment()
    IRController.shared.resetToRGB()
    print("👋 退出完成。")
    exit(0)
}

let handler = EnrollmentCLIHandler()
let enrollmentService = FaceEnrollmentService.shared
enrollmentService.delegate = handler

print("""
【第 1/2 轮】：录入日常/佩戴眼镜外观
👉 提示: 如果您平时佩戴眼镜，请戴上眼镜；如果不戴，保持平时自然状态即可。
按 [回车键 Enter] 开启红外镜头并开始录入...
""")
_ = readLine()

do {
    print("🌙 正在开启 850nm 红外夜视镜头与特征追踪...")
    try enrollmentService.startEnrollment(stage: .regular)
    handler.sema.wait()

    // 询问是否录入替用/脱镜外观
    print("""

------------------------------------------------------
【第 2/2 轮】：录入脱镜/替用外貌 (Alternative Appearance)
👉 提示: 请摘下眼镜，我们将录入未戴眼镜时的纯面部红外特征。
   (这样无论你平时戴镜，还是睡醒脱镜，都能瞬间解锁)

按 [回车键 Enter] 开始脱镜录入 (输入 's' 并回车可跳过): 
""", terminator: "")

    let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if choice == "s" || choice == "skip" {
        print("⏩ 已跳过替用外观录入。")
        enrollmentService.skipAlternativeStage()
    } else {
        print("🌙 正在继续脱镜特征录入...")
        try enrollmentService.startAlternativeStage()
        handler.sema.wait()
    }

} catch {
    print("❌ 启动录入失败: \(error)")
    enrollmentService.stopEnrollment()
    exit(1)
}

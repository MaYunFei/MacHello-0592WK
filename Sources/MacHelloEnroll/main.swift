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
        print("\n  ✅ Captured pose: [\(pose.title)]")
    }

    func enrollmentStageDidComplete(stage: EnrollmentStage) {
        print("\n\n🎉 Stage Complete: [\(stage.title)] enrolled successfully!")
        sema.signal()
    }

    func enrollmentDidFinishAll(totalSamples: Int) {
        print("""

======================================================
  ✨ Face ID Enrollment Complete!
  - Total biometric sample sets: \(totalSamples)
  - Appearances: Regular/Glasses + Alternative Appearance
  - Securely stored at: ~/.machello/faces.json
======================================================
""")
    }

    func enrollmentDidFail(error: String) {
        print("\n❌ Enrollment failed: \(error)")
        sema.signal()
    }
}

print("""
======================================================
  🍏 MacHello Face ID Enrollment Wizard (CLI)
  - Hardware: Dell CN-0592WK (0bda:5767) Dual-Sensor IR
  - Engine: Apple Neural Engine (ANE) Vision biometrics
  - Mode: Circular head pose guidance + Dual appearances
======================================================
""")

let irController = IRController.shared
guard irController.isConnected else {
    print("❌ Error: Dell 0592WK camera module not detected. Check USB connection.")
    exit(1)
}

// 退出信号保护
signal(SIGINT) { _ in
    print("\n\n🛑 Enrollment interrupted, resetting hardware...")
    FaceEnrollmentService.shared.stopEnrollment()
    IRController.shared.resetToRGB()
    print("👋 Exited.")
    exit(0)
}

let handler = EnrollmentCLIHandler()
let enrollmentService = FaceEnrollmentService.shared
enrollmentService.delegate = handler

print("""
[Stage 1/2]: Regular / Glasses Appearance
👉 Note: If you wear glasses daily, please put them on; otherwise, stay natural.
Press [Enter] to start IR camera and begin enrollment...
""")
_ = readLine()

do {
    print("🌙 Starting 850nm IR camera & feature tracking...")
    try enrollmentService.startEnrollment(stage: .regular)
    handler.sema.wait()

    // 询问是否录入替用/脱镜外观
    print("""

------------------------------------------------------
[Stage 2/2]: Alternative Appearance (Without Glasses)
👉 Note: Please remove your glasses so we can record raw IR facial biometrics.
   (This allows instant unlock whether wearing glasses or waking up without them)

Press [Enter] to start (or enter 's' to skip): 
""", terminator: "")

    let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if choice == "s" || choice == "skip" {
        print("⏩ Skipped alternative appearance.")
        enrollmentService.skipAlternativeStage()
    } else {
        print("🌙 Starting alternative appearance enrollment...")
        try enrollmentService.startAlternativeStage()
        handler.sema.wait()
    }

} catch {
    print("❌ Enrollment failed to start: \(error)")
    enrollmentService.stopEnrollment()
    exit(1)
}

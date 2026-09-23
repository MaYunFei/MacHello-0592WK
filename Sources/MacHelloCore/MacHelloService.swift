import Foundation
import Combine
import CIOKitHelper

public class MacHelloService: ObservableObject, DisplayPowerObserver {
    public static let shared = MacHelloService()

    @Published public var isDeviceConnected: Bool = false
    @Published public var isIRActive: Bool = false
    @Published public var isEnrolled: Bool = false
    @Published public var enrolledSamplesCount: Int = 0

    // 人体感应（走开息屏 / 来人亮屏）状态
    @Published public var isAutoDisplayEnabled: Bool = false
    @Published public var requireOwnerVerification: Bool = true
    @Published public var isSmartIdlePowerSavingEnabled: Bool = true
    @Published public var absenceTimeout: TimeInterval = 15.0
    @Published public var isDisplayAsleep: Bool = false
    @Published public var isPersonPresent: Bool = false
    @Published public var isOwnerVerified: Bool = false

    private let irController = IRController.shared
    private let cameraService = CameraCaptureService.shared
    private let autoDisplayService = PresenceAutoDisplayService.shared
    private let displayManager = DisplayPowerManager.shared

    public init() {
        displayManager.addObserver(self)
        self.isAutoDisplayEnabled = autoDisplayService.isEnabled
        self.requireOwnerVerification = autoDisplayService.requireOwnerVerification
        self.isSmartIdlePowerSavingEnabled = autoDisplayService.isSmartIdlePowerSavingEnabled
        self.absenceTimeout = autoDisplayService.absenceTimeout
        self.isDisplayAsleep = displayManager.isDisplayAsleep

        autoDisplayService.onStateUpdated = { [weak self] isEnabled, isPresent, isOwner, isDisplayAsleep in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var hasChange = false
                if self.isAutoDisplayEnabled != isEnabled { self.isAutoDisplayEnabled = isEnabled; hasChange = true }
                if self.isPersonPresent != isPresent { self.isPersonPresent = isPresent; hasChange = true }
                if self.isOwnerVerified != isOwner { self.isOwnerVerified = isOwner; hasChange = true }
                if self.isDisplayAsleep != isDisplayAsleep { self.isDisplayAsleep = isDisplayAsleep; hasChange = true }
                if hasChange {
                    self.objectWillChange.send()
                }
            }
        }

        refreshStatus()
    }

    public func refreshStatus() {
        self.isDeviceConnected = irController.isConnected
        self.isIRActive = (irController.currentMode == .ir)
        let profile = FaceDatabase.shared.load()
        self.isEnrolled = !(profile?.samples.isEmpty ?? true)
        self.enrolledSamplesCount = profile?.samples.count ?? 0
        self.isAutoDisplayEnabled = autoDisplayService.isEnabled
        self.requireOwnerVerification = autoDisplayService.requireOwnerVerification
        self.isSmartIdlePowerSavingEnabled = autoDisplayService.isSmartIdlePowerSavingEnabled
        self.absenceTimeout = autoDisplayService.absenceTimeout
    }

    public func toggleAutoDisplay() {
        let newState = !isAutoDisplayEnabled
        autoDisplayService.isEnabled = newState
        self.isAutoDisplayEnabled = newState
    }

    public func toggleSmartIdlePowerSaving() {
        let newState = !isSmartIdlePowerSavingEnabled
        autoDisplayService.isSmartIdlePowerSavingEnabled = newState
        self.isSmartIdlePowerSavingEnabled = newState
    }

    public func toggleRequireOwnerVerification() {
        let newState = !requireOwnerVerification
        autoDisplayService.requireOwnerVerification = newState
        self.requireOwnerVerification = newState
    }

    public func setAbsenceTimeout(_ seconds: TimeInterval) {
        autoDisplayService.absenceTimeout = seconds
        self.absenceTimeout = seconds
    }

    public func toggleIRTest() {
        guard isDeviceConnected else { return }
        let success = irController.toggle()
        if success {
            self.isIRActive = (irController.currentMode == .ir)
        }
    }

    public func clearFaceData() {
        FaceDatabase.shared.clear()
        refreshStatus()
    }

    public func displayPowerStateDidChange(isDisplayAsleep: Bool) {
        DispatchQueue.main.async {
            if self.isDisplayAsleep != isDisplayAsleep {
                self.isDisplayAsleep = isDisplayAsleep
            }
        }
    }
}

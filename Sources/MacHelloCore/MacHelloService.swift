import Foundation
import Combine
import CIOKitHelper

public class MacHelloService: ObservableObject {
    public static let shared = MacHelloService()

    @Published public var isDeviceConnected: Bool = false
    @Published public var isIRActive: Bool = false

    private let irController = IRController.shared
    private let cameraService = CameraCaptureService.shared

    public init() {
        checkDeviceConnection()
    }

    public func checkDeviceConnection() {
        self.isDeviceConnected = irController.isConnected
        self.isIRActive = (irController.currentMode == .ir)
    }

    public func toggleIRTest() {
        guard isDeviceConnected else { return }
        let success = irController.toggle()
        if success {
            self.isIRActive = (irController.currentMode == .ir)
        }
    }

    public func setIRActive(_ active: Bool) {
        guard isDeviceConnected else { return }
        let mode: IRController.Mode = active ? .ir : .rgb
        if irController.setMode(mode) {
            self.isIRActive = active
        }
    }

    public func startFaceEnrollment() {
        // TODO: 调用 AVFoundation + Apple Vision 录入
    }
}

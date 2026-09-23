import Foundation
import Combine

public class MacHelloService: ObservableObject {
    public static let shared = MacHelloService()

    @Published public var isDeviceConnected: Bool = false
    @Published public var isIRActive: Bool = false

    public init() {
        checkDeviceConnection()
    }

    public func checkDeviceConnection() {
        // TODO: 侦测 0bda:5767 硬件
        self.isDeviceConnected = false
    }

    public func toggleIRTest() {
        self.isIRActive.toggle()
        // TODO: 调用 IOKit 5步握手
    }

    public func startFaceEnrollment() {
        // TODO: 调用 AVFoundation + Apple Vision 录入
    }
}

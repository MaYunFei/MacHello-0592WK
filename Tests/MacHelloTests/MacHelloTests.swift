import XCTest
@testable import MacHelloCore

final class MacHelloTests: XCTestCase {
    func testDeviceConnection() throws {
        let isConnected = IRController.shared.isConnected
        print("Device connected: \(isConnected)")
        XCTAssertTrue(isConnected, "Dell 0592WK should be detected")
    }

    func testIRModeSwitching() throws {
        let controller = IRController.shared
        guard controller.isConnected else {
            throw XCTSkip("Dell 0592WK hardware not connected")
        }

        defer {
            // Safety guard: always restore RGB mode
            _ = controller.setMode(.rgb)
        }

        // Test IR mode
        let irSuccess = controller.setMode(.ir)
        XCTAssertTrue(irSuccess, "Should switch to IR mode")
        XCTAssertEqual(controller.currentMode, .ir)

        // Test RGB mode
        let rgbSuccess = controller.setMode(.rgb)
        XCTAssertTrue(rgbSuccess, "Should switch back to RGB mode")
        XCTAssertEqual(controller.currentMode, .rgb)
    }

    func testCameraDiscovery() throws {
        let camera = CameraCaptureService.findDellCamera()
        XCTAssertNotNil(camera, "Dell 0592WK camera should be discovered by AVFoundation")
        if let camera = camera {
            print("Discovered camera: \(camera.localizedName) (ModelID: \(camera.modelID))")
            XCTAssertTrue(camera.modelID.contains("3034") || camera.localizedName.contains("Integrated Webcam"))
        }
    }
}

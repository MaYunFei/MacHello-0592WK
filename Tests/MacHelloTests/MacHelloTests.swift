import XCTest
@testable import MacHelloCore

final class MacHelloTests: XCTestCase {
    func testDeviceConnection() throws {
        let isConnected = IRController.shared.isConnected
        print("Device connected: \(isConnected)")
        guard isConnected else {
            throw XCTSkip("Dell 0592WK hardware not connected to local Mac")
        }
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
        guard IRController.shared.isConnected else {
            throw XCTSkip("Dell 0592WK camera not connected to local Mac")
        }
        let camera = CameraCaptureService.findDellCamera()
        XCTAssertNotNil(camera, "Dell 0592WK camera should be discovered by AVFoundation")
        if let camera = camera {
            print("Discovered camera: \(camera.localizedName) (ModelID: \(camera.modelID))")
            XCTAssertTrue(camera.modelID.contains("3034") || camera.localizedName.contains("Integrated Webcam"))
        }
    }

    func testPresenceDetectorStateTransition() {
        let detector = PresenceDetector(hitThreshold: 2, missThreshold: 3)
        detector.autoNotify = false // Don't spam notifications during unit tests

        XCTAssertFalse(detector.isPersonPresent)

        // Reset
        detector.reset()
        XCTAssertFalse(detector.isPersonPresent)
    }

    func testInputIdleMonitor() {
        let idle = InputIdleMonitor.shared.idleSeconds
        XCTAssertGreaterThanOrEqual(idle, 0.0)
    }

    func testPAMManager() {
        let mgr = PAMManager.shared
        XCTAssertFalse(mgr.pamSoPath.isEmpty)
        XCTAssertFalse(mgr.authBinPath.isEmpty)
        XCTAssertFalse(mgr.sudoLocalPath.isEmpty)
    }

    func testFaceDatabaseCosineSimilarity() {
        let vecA: [Float] = [1.0, 0.0, 0.0]
        let vecB: [Float] = [1.0, 0.0, 0.0]
        let vecC: [Float] = [0.0, 1.0, 0.0]

        // Identical vectors should have similarity 1.0
        let simSame = FaceDatabase.cosineSimilarity(a: vecA, b: vecB)
        XCTAssertEqual(simSame, 1.0, accuracy: 0.001)

        // Orthogonal vectors should have similarity 0.0
        let simOrth = FaceDatabase.cosineSimilarity(a: vecA, b: vecC)
        XCTAssertEqual(simOrth, 0.0, accuracy: 0.001)
    }

    func testDisplayPowerManagerObserver() {
        class MockObserver: DisplayPowerObserver {
            var stateChanged = false
            func displayPowerStateDidChange(isDisplayAsleep: Bool) {
                stateChanged = true
            }
        }

        let mgr = DisplayPowerManager.shared
        let obs = MockObserver()
        mgr.addObserver(obs)
        XCTAssertFalse(obs.stateChanged)
    }
}

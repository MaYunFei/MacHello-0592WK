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

    func testFaceFeatureExtractorLandmarks() throws {
        guard let image = NSImage(contentsOfFile: "Tests/Snapshots/snapshot_ir.jpg"),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("Snapshot file not found")
        }

        let extractor = FaceFeatureExtractor.shared
        let results = extractor.extract(from: cgImage)
        XCTAssertFalse(results.isEmpty, "Should detect at least one face in the snapshot")

        if let face = results.first {
            XCTAssertEqual(face.embedding.count, 128, "Embedding dimension should be 128")
            XCTAssertFalse(face.landmarks.isEmpty, "Face landmarks should be detected")
            print("Detected \(face.landmarks.count) landmarks on snapshot face")
            XCTAssertGreaterThanOrEqual(face.landmarks.count, 60, "Landmarks should have rich detail (> 60 points)")
        }
    }

    func testMediaActivityDetectorAndMenuTitle() {
        let detector = MediaActivityDetector.shared
        let service = MacHelloService.shared

        // 默认状态下验证菜单项文案
        service.respectMediaPlayback = true
        let titleWhenActive = service.mediaPlaybackMenuTitle
        if detector.isPreventingDisplaySleep {
            XCTAssertTrue(titleWhenActive.contains("🟢 运行中"))
            XCTAssertNotNil(detector.activeMediaAppName)
        } else {
            XCTAssertTrue(titleWhenActive.contains("⚪ 待命中"))
        }

        // 关闭功能时验证文案
        service.respectMediaPlayback = false
        let titleWhenDisabled = service.mediaPlaybackMenuTitle
        XCTAssertTrue(titleWhenDisabled.contains("已关闭"))

        // 恢复默认
        service.respectMediaPlayback = true
    }

    func testGlobalHotkeyManager() {
        let hotkey = GlobalHotkeyManager.shared
        let originalState = hotkey.isEnabled
        let originalCode = hotkey.currentKeyCode
        let originalMods = hotkey.currentModifiers
        defer {
            hotkey.isEnabled = originalState
            hotkey.setHotkey(keyCode: originalCode, modifiers: originalMods)
        }

        hotkey.isEnabled = true
        XCTAssertTrue(hotkey.isEnabled)
        hotkey.register()

        // Test custom hotkey setting
        hotkey.setHotkey(keyCode: 35, modifiers: 256 | 2048) // ⌥⌘P
        XCTAssertEqual(hotkey.currentKeyCode, 35)
        XCTAssertEqual(hotkey.currentDisplay, "⌥⌘P")

        // Test reset to default (⌘\)
        hotkey.resetToDefault()
        XCTAssertEqual(hotkey.currentKeyCode, GlobalHotkeyManager.defaultKeyCode)
        XCTAssertEqual(hotkey.currentDisplay, "⌘\\")

        hotkey.isEnabled = false
        XCTAssertFalse(hotkey.isEnabled)

        hotkey.isEnabled = true
        XCTAssertTrue(hotkey.isEnabled)
    }

    func testKeychainHelperCustomApp() {
        let keychain = KeychainHelper.shared
        let testBundleId = "com.test.machello.app"
        let testPw = "SuperSecret123!"

        defer {
            keychain.deleteAppPassword(bundleId: testBundleId)
        }

        // 1. 保存
        let saved = keychain.saveAppPassword(bundleId: testBundleId, password: testPw)
        XCTAssertTrue(saved, "Should save app password to Keychain")

        // 2. 检查存在
        XCTAssertTrue(keychain.hasAppPassword(bundleId: testBundleId), "Keychain should have the app password")

        // 3. 读取解密
        let fetched = keychain.fetchAppPassword(bundleId: testBundleId)
        XCTAssertEqual(fetched, testPw, "Fetched password should match stored password")

        // 4. 删除
        let deleted = keychain.deleteAppPassword(bundleId: testBundleId)
        XCTAssertTrue(deleted, "Should delete app password from Keychain")
        XCTAssertFalse(keychain.hasAppPassword(bundleId: testBundleId), "Password should no longer exist after deletion")
    }

    func testAppCredentialManager() {
        let manager = AppCredentialManager.shared
        let testBundleId = "com.test.bitwarden.mock"
        let testAppName = "Bitwarden Mock"
        let testPw = "MockMasterPassword!@#"

        defer {
            manager.deleteRule(bundleId: testBundleId)
        }

        // 1. 添加或更新规则
        let added = manager.addOrUpdateRule(
            bundleId: testBundleId,
            appName: testAppName,
            password: testPw,
            autoConfirm: true,
            isAutoUnlockEnabled: false
        )
        XCTAssertTrue(added, "Should add rule and save password to Keychain")

        // 2. 验证规则查询
        let rule = manager.rule(for: testBundleId)
        XCTAssertNotNil(rule, "Should find rule for bundleId")
        XCTAssertEqual(rule?.appName, testAppName)
        XCTAssertTrue(rule?.autoConfirm ?? false)
        XCTAssertFalse(rule?.isAutoUnlockEnabled ?? true)

        // 3. 验证钥匙串中已存储密码
        let pw = KeychainHelper.shared.fetchAppPassword(bundleId: testBundleId)
        XCTAssertEqual(pw, testPw, "Keychain should store the correct app password")

        // 4. 更新配置选项
        manager.updateRuleOptions(bundleId: testBundleId, autoConfirm: false, isAutoUnlockEnabled: true)
        let updatedRule = manager.rule(for: testBundleId)
        XCTAssertFalse(updatedRule?.autoConfirm ?? true)
        XCTAssertTrue(updatedRule?.isAutoUnlockEnabled ?? false)

        // 5. 校验被动卸载检测 (不存在的应用)
        let status = manager.checkAppInstalled(bundleId: testBundleId)
        XCTAssertFalse(status.installed, "Mock app should not be installed on system")

        // 6. 主动删除
        manager.deleteRule(bundleId: testBundleId)
        XCTAssertNil(manager.rule(for: testBundleId), "Rule should be removed after deletion")
        XCTAssertFalse(KeychainHelper.shared.hasAppPassword(bundleId: testBundleId), "Keychain password should be wiped")
    }

    func testSystemAuthIdentifierRecognition() {
        // 1. 传统 SecurityAgent 识别
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.SecurityAgent", processName: "SecurityAgent"))
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.SecurityAgent", processName: nil))
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: nil, processName: "SecurityAgent"))

        // 2. 现代 LocalAuthentication (coreautha / LocalAuthenticationRemoteService) 识别
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.LocalAuthentication.UIAgent", processName: "coreautha"))
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.LocalAuthentication.UIAgent", processName: nil))
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: nil, processName: "coreautha"))
        XCTAssertTrue(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.LocalAuthenticationRemoteService", processName: "LocalAuthenticationRemoteService (iPhone镜像)"))

        // 3. 普通应用或浏览器应该被排除
        XCTAssertFalse(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.google.Chrome", processName: "Google Chrome"))
        XCTAssertFalse(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.Safari", processName: "Safari"))
        XCTAssertFalse(AccessibilityHelper.isSystemAuthIdentifier(bundleId: "com.apple.Terminal", processName: "Terminal"))
        XCTAssertFalse(AccessibilityHelper.isSystemAuthIdentifier(bundleId: nil, processName: nil))

        // 4. 不可见 PID 必须判定为离屏 (防止常驻后台服务被误判可见从而偷焦)
        XCTAssertFalse(AccessibilityHelper.isProcessWindowOnScreen(pid: 999999))
    }
}

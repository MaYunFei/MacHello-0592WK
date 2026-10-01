import Foundation
import AppKit
import ServiceManagement

public final class UninstallManager {
    public static let shared = UninstallManager()

    private init() {}

    /// 执行彻底数据抹除与卸载准备流程 (Option A)
    /// - Parameters:
    ///   - eraseBiometrics: 是否抹除 ~/.machello/ 下的面容特征库与通行历史照片
    ///   - eraseKeychain: 是否抹除系统钥匙串中的 Mac 密码及所有第三方应用凭据
    ///   - restorePAM: 是否还原终端 Sudo PAM 配置
    ///   - completion: 执行完成回调
    public func executeCompleteWipeAndPrepareUninstall(
        eraseBiometrics: Bool = true,
        eraseKeychain: Bool = true,
        restorePAM: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        NSLog("[UninstallManager] 🧹 开始执行 MacHello 全系统数据抹除流水线...")

        // 1. 注销开机自启动服务 (SMAppService)
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    NSLog("[UninstallManager] ✓ 成功注销开机自启动项")
                }
            } catch {
                NSLog("[UninstallManager] ⚠️ 注销开机自启失败: %@", error.localizedDescription)
            }
        }

        // 2. 钥匙串物理抹除
        if eraseKeychain {
            let customBids = AppCredentialManager.shared.rules.map { $0.bundleId }
            KeychainHelper.shared.deleteAllCredentials(customBundleIds: customBids)
            NSLog("[UninstallManager] ✓ 成功彻底抹除系统钥匙串中所有 MacHello 相关密码凭据")
        }

        // 3. 抹除本地生物特征数据库与抓拍历史 (~/.machello)
        if eraseBiometrics {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let machelloDir = home.appendingPathComponent(".machello", isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: machelloDir.path) {
                    try FileManager.default.removeItem(at: machelloDir)
                    NSLog("[UninstallManager] ✓ 成功彻底删除 ~/.machello/ 目录 (包含 faces.json 及通行照片)")
                }
            } catch {
                NSLog("[UninstallManager] ⚠️ 删除 ~/.machello 目录失败: %@", error.localizedDescription)
            }
        }

        // 4. 重置 UserDefaults 偏好设置
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        UserDefaults.standard.removePersistentDomain(forName: "com.machello.app")
        UserDefaults.standard.synchronize()
        NSLog("[UninstallManager] ✓ 成功重置所有应用偏好设置")

        // 5. 终端 PAM 提权配置还原
        if restorePAM && PAMManager.shared.isInstalled {
            NSLog("[UninstallManager] 正在启动终端还原 PAM 模块配置...")
            PAMManager.shared.runUninstallInTerminal { [weak self] in
                NSLog("[UninstallManager] ✓ PAM 模块已成功卸载还原")
                self?.finishAndRevealApp(completion: completion)
            }
        } else {
            finishAndRevealApp(completion: completion)
        }
    }

    private func finishAndRevealApp(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let appURL: URL?
            if let bundlePath = Bundle.main.bundlePath as String?, bundlePath.hasSuffix(".app") {
                appURL = URL(fileURLWithPath: bundlePath)
            } else if let appInApps = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.machello.app") {
                appURL = appInApps
            } else if FileManager.default.fileExists(atPath: "/Applications/MacHello.app") {
                appURL = URL(fileURLWithPath: "/Applications/MacHello.app")
            } else {
                appURL = nil
            }

            if let targetURL = appURL {
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            }

            completion(true)
        }
    }
}

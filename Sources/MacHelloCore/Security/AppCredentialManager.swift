import Foundation
import AppKit

public struct AppCredentialRule: Codable, Identifiable, Equatable {
    public var id: String { bundleId }
    public let bundleId: String
    public var appName: String
    public var autoConfirm: Bool
    public var isAutoUnlockEnabled: Bool
    public var addedAt: Date
    public var lastVerifiedAt: Date?

    public init(
        bundleId: String,
        appName: String,
        autoConfirm: Bool = true,
        isAutoUnlockEnabled: Bool = false,
        addedAt: Date = Date(),
        lastVerifiedAt: Date? = nil
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.autoConfirm = autoConfirm
        self.isAutoUnlockEnabled = isAutoUnlockEnabled
        self.addedAt = addedAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public struct RunningAppInfo: Identifiable, Hashable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String
    public let icon: NSImage?

    public init(bundleId: String, name: String, icon: NSImage?) {
        self.bundleId = bundleId
        self.name = name
        self.icon = icon
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleId)
    }

    public static func == (lhs: RunningAppInfo, rhs: RunningAppInfo) -> Bool {
        return lhs.bundleId == rhs.bundleId
    }
}

public final class AppCredentialManager: ObservableObject {
    public static let shared = AppCredentialManager()

    private let defaultsKeyRules = "com.machello.customAppRules"
    private let keychain = KeychainHelper.shared

    @Published public private(set) var rules: [AppCredentialRule] = []

    private init() {
        loadRules()
    }

    // MARK: - 持久化与加载

    private func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKeyRules) else {
            self.rules = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([AppCredentialRule].self, from: data)
            self.rules = decoded
        } catch {
            NSLog("[AppCredentialManager] ⚠️ 解析已存规则失败: %@", error.localizedDescription)
            self.rules = []
        }
    }

    private func saveRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: defaultsKeyRules)
        } catch {
            NSLog("[AppCredentialManager] ⚠️ 保存应用规则失败: %@", error.localizedDescription)
        }
    }

    private func executeOnMain(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync {
                block()
            }
        }
    }

    // MARK: - 规则查询与管理

    public func rule(for bundleId: String) -> AppCredentialRule? {
        return rules.first(where: { $0.bundleId.lowercased() == bundleId.lowercased() })
    }

    /// 保存或更新指定应用的凭据规则与密码
    @discardableResult
    public func addOrUpdateRule(
        bundleId: String,
        appName: String,
        password: String,
        autoConfirm: Bool = true,
        isAutoUnlockEnabled: Bool = false
    ) -> Bool {
        let cleanBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleId.isEmpty else { return false }

        // 1. 物理写入安全钥匙串
        let success = keychain.saveAppPassword(bundleId: cleanBundleId, password: password)
        guard success else {
            NSLog("[AppCredentialManager] ❌ 写入钥匙串失败: %@", cleanBundleId)
            return false
        }

        // 2. 同步更新规则表
        executeOnMain {
            if let index = self.rules.firstIndex(where: { $0.bundleId.lowercased() == cleanBundleId.lowercased() }) {
                self.rules[index].appName = appName
                self.rules[index].autoConfirm = autoConfirm
                self.rules[index].isAutoUnlockEnabled = isAutoUnlockEnabled
                self.rules[index].lastVerifiedAt = Date()
            } else {
                let newRule = AppCredentialRule(
                    bundleId: cleanBundleId,
                    appName: appName,
                    autoConfirm: autoConfirm,
                    isAutoUnlockEnabled: isAutoUnlockEnabled,
                    addedAt: Date(),
                    lastVerifiedAt: Date()
                )
                self.rules.append(newRule)
            }
            self.saveRules()
            NSLog("[AppCredentialManager] ✓ 成功添加/更新应用凭据规则: %@ (%@)", appName, cleanBundleId)
        }
        return true
    }

    /// 更新应用开关选项 (无需改动密码)
    public func updateRuleOptions(bundleId: String, autoConfirm: Bool, isAutoUnlockEnabled: Bool) {
        executeOnMain {
            if let index = self.rules.firstIndex(where: { $0.bundleId.lowercased() == bundleId.lowercased() }) {
                self.rules[index].autoConfirm = autoConfirm
                self.rules[index].isAutoUnlockEnabled = isAutoUnlockEnabled
                self.saveRules()
            }
        }
    }

    /// 主动删除应用凭据：彻底清理规则与 Keychain 中的密码条目
    public func deleteRule(bundleId: String) {
        let cleanBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleId.isEmpty else { return }

        // 1. 钥匙串物理抹除
        keychain.deleteAppPassword(bundleId: cleanBundleId)

        // 2. 规则列表剔除并持久化
        executeOnMain {
            self.rules.removeAll(where: { $0.bundleId.lowercased() == cleanBundleId.lowercased() })
            self.saveRules()
            NSLog("[AppCredentialManager] 🗑️ 已彻底删除应用凭据与钥匙串数据: %@", cleanBundleId)
        }
    }

    // MARK: - 应用探查与运行列表获取

    /// 获取当前正在运行的常规 GUI 应用程序列表（包含常规桌面软件与用户级前台/状态栏工具，自动过滤系统级底层 daemon）
    public func runningGUIApplications() -> [RunningAppInfo] {
        let running = NSWorkspace.shared.runningApplications
        let myBundleId = Bundle.main.bundleIdentifier ?? ""

        var list: [RunningAppInfo] = []
        for app in running {
            guard let bid = app.bundleIdentifier, !bid.isEmpty, bid != myBundleId else { continue }

            // 过滤系统纯后台内部服务，仅收录：
            // 1. 常规桌面应用 (policy == .regular，如 Bitwarden, Chrome, 微信, 访达等)
            // 2. 用户级状态栏或辅助应用 (policy == .accessory，且拥有独立 .app 路径且非系统核心服务)
            let isRegular = app.activationPolicy == .regular
            let isUserAccessory = app.activationPolicy == .accessory &&
                !bid.hasPrefix("com.apple.") &&
                !bid.hasSuffix(".helper") &&
                !bid.hasSuffix(".appex") &&
                (app.bundleURL?.path.contains("/Applications/") == true)

            guard isRegular || isUserAccessory else { continue }

            let name = app.localizedName ?? bid
            let icon = app.icon

            // 去重
            if !list.contains(where: { $0.bundleId.lowercased() == bid.lowercased() }) {
                list.append(RunningAppInfo(bundleId: bid, name: name, icon: icon))
            }
        }

        return list.sorted(by: { $0.name.localizedCompare($1.name) == .orderedAscending })
    }

    /// 校验应用当前是否依然安装在系统中（未被删除、且未被移入废纸篓）
    public func checkAppInstalled(bundleId: String) -> (installed: Bool, url: URL?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return (false, nil)
        }
        let path = url.path
        let exists = FileManager.default.fileExists(atPath: path)
        let inTrash = path.contains("/.Trash/")
        return (exists && !inTrash, url)
    }

    // MARK: - 被动卸载检测与自动清理机制 (Passive Cleanup)

    /// 巡检已配置的所有规则：若发现宿主应用已被卸载，自动抹除 Keychain 密码并移除规则
    @discardableResult
    public func cleanOrphanedAppCredentials() -> [String] {
        var orphanedBundleIds: [String] = []

        for rule in rules {
            let status = checkAppInstalled(bundleId: rule.bundleId)
            if !status.installed {
                orphanedBundleIds.append(rule.bundleId)
            }
        }

        guard !orphanedBundleIds.isEmpty else {
            return []
        }

        NSLog("[AppCredentialManager] 🧹 检测到 %d 个已被卸载的孤儿应用凭据，正在执行物理清理: %@",
              orphanedBundleIds.count, orphanedBundleIds.joined(separator: ", "))

        for bid in orphanedBundleIds {
            keychain.deleteAppPassword(bundleId: bid)
        }

        executeOnMain {
            self.rules.removeAll(where: { orphanedBundleIds.contains($0.bundleId) })
            self.saveRules()
        }

        return orphanedBundleIds
    }
}

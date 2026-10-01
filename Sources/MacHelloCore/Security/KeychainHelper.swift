import Foundation
import Security

public final class KeychainHelper {
    public static let shared = KeychainHelper()

    private let service = "com.machello.MacHello"
    private var account: String {
        return NSUserName()
    }

    private init() {}

    /// 保存机主解锁密码到 macOS 系统安全钥匙串
    @discardableResult
    public func savePassword(_ password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // 先删除旧凭据
        deletePassword()

        var access: SecAccess?
        SecAccessCreate("MacHello" as CFString, nil, &access)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacHello Face ID 自动解锁凭据",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let access = access {
            query[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从钥匙串读取解密后的机主密码
    public func fetchPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess {
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)"
            NSLog("[KeychainHelper] ❌ 读取钥匙串失败: status=%d (%@)", status, msg)
            return nil
        }
        guard let data = result as? Data, let pw = String(data: data, encoding: .utf8) else {
            NSLog("[KeychainHelper] ❌ 读取钥匙串数据格式解析失败")
            return nil
        }

        return pw
    }

    public struct KeychainVerificationResult {
        public let success: Bool
        public let status: OSStatus
        public let message: String
        public let passwordLength: Int
    }

    /// 主动进行钥匙串解密读取验证，返回详细状态信息（在前台调用以确保唤起系统授权框）
    public func verifyKeychainAccess() -> KeychainVerificationResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, let _ = String(data: data, encoding: .utf8) {
            return KeychainVerificationResult(
                success: true,
                status: status,
                message: "钥匙串访问授权有效，密码可正常解密。",
                passwordLength: data.count
            )
        }

        let errMsg = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误 (\(status))"
        var explanation = "系统错误码: \(status) (\(errMsg))"
        if status == errSecAuthFailed {
            explanation = "授权被拒绝 (errSecAuthFailed, -25293)。您需要在弹出的系统窗口中输入当前用户的登录密码并点击「总是允许」。"
        } else if status == errSecInteractionNotAllowed {
            explanation = "系统禁止后台交互 (errSecInteractionNotAllowed, -25308)。请确保 MacHello 处于前台激活状态再进行验证。"
        } else if status == errSecItemNotFound {
            explanation = "钥匙串中未找到密码记录 (errSecItemNotFound, -25300)。请先在菜单中保存一次免密解锁密码。"
        }

        return KeychainVerificationResult(
            success: false,
            status: status,
            message: explanation,
            passwordLength: 0
        )
    }

    /// 检查钥匙串中是否已保存密码
    public func hasPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// 从钥匙串彻底清除保存的密码
    @discardableResult
    public func deletePassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

import Foundation
import AppKit

public final class PAMManager {
    public static let shared = PAMManager()

    public let pamSoPath = "/usr/local/lib/pam/pam_machello.so"
    public let authBinPath = "/usr/local/bin/machello-auth"
    public let sudoLocalPath = "/etc/pam.d/sudo_local"

    private init() {}

    /// PAM 模块是否已完整安装并配置生效
    public var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pamSoPath) && fm.fileExists(atPath: authBinPath) else {
            return false
        }
        guard let content = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8) else {
            return false
        }
        return content.contains("pam_machello.so")
    }

    /// 寻找待安装的源文件路径（优先从 App Bundle 资源包中读取，其次从本地 Release 路径读取）
    private func resolveSourceFiles() -> (authBin: String, pamSo: String)? {
        let fm = FileManager.default

        // 1. 从 App Bundle 的 Contents/Resources 查找
        if let resURL = Bundle.main.resourceURL {
            let bundleAuth = resURL.appendingPathComponent("machello-auth").path
            let bundlePam = resURL.appendingPathComponent("pam_machello.so").path
            if fm.fileExists(atPath: bundleAuth) && fm.fileExists(atPath: bundlePam) {
                return (bundleAuth, bundlePam)
            }
        }

        // 2. 从项目根目录 .build/release 或当前工作目录查找
        let cwd = FileManager.default.currentDirectoryPath
        let buildAuth = "\(cwd)/.build/release/MacHelloAuth"
        let buildPam = "\(cwd)/.build/release/pam_machello.so"
        if fm.fileExists(atPath: buildAuth) && fm.fileExists(atPath: buildPam) {
            return (buildAuth, buildPam)
        }

        return nil
    }

    /// 在 GUI 中通过 macOS 原生管理员密码提权弹窗一键安装
    @discardableResult
    public func installViaGUI() -> (success: Bool, error: String?) {
        guard let (authSrc, pamSrc) = resolveSourceFiles() else {
            return (false, "未找到认证核心或动态库文件，请确保应用包完整。")
        }

        let cmd = """
        mkdir -p /usr/local/bin /usr/local/lib/pam
        cp "\(authSrc)" "\(authBinPath)"
        chmod 755 "\(authBinPath)"
        cp "\(pamSrc)" "\(pamSoPath)"
        chmod 555 "\(pamSoPath)"
        if [ ! -f "\(sudoLocalPath)" ]; then
            echo "auth       sufficient     \(pamSoPath)" > "\(sudoLocalPath)"
            chmod 444 "\(sudoLocalPath)"
        elif ! grep -q "pam_machello.so" "\(sudoLocalPath)"; then
            TEMP_F=$(mktemp)
            echo "auth       sufficient     \(pamSoPath)" > "$TEMP_F"
            cat "\(sudoLocalPath)" >> "$TEMP_F"
            cat "$TEMP_F" > "\(sudoLocalPath)"
            rm -f "$TEMP_F"
            chmod 444 "\(sudoLocalPath)"
        fi
        """

        let appleScriptSource = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: appleScriptSource) {
            appleScript.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "用户取消或授权失败"
                return (false, msg)
            }
            return (true, nil)
        }

        return (false, "无法初始化系统认证授权")
    }

    /// 在 GUI 中通过 macOS 原生管理员密码弹窗一键卸载还原
    @discardableResult
    public func uninstallViaGUI() -> (success: Bool, error: String?) {
        let cmd = """
        if [ -f "\(sudoLocalPath)" ]; then
            TEMP_F=$(mktemp)
            grep -v "pam_machello.so" "\(sudoLocalPath)" > "$TEMP_F" || true
            cat "$TEMP_F" > "\(sudoLocalPath)"
            rm -f "$TEMP_F"
            chmod 444 "\(sudoLocalPath)"
        fi
        rm -f "\(pamSoPath)"
        rm -f "\(authBinPath)"
        """

        let appleScriptSource = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: appleScriptSource) {
            appleScript.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "用户取消或授权失败"
                return (false, msg)
            }
            return (true, nil)
        }

        return (false, "无法初始化系统认证授权")
    }
}

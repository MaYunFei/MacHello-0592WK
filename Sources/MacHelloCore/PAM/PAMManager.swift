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

    /// 寻找待安装的源文件路径
    private func resolveSourceFiles() -> (authBin: String, pamSo: String)? {
        let fm = FileManager.default

        if let resURL = Bundle.main.resourceURL {
            let bundleAuth = resURL.appendingPathComponent("machello-auth").path
            let bundlePam = resURL.appendingPathComponent("pam_machello.so").path
            if fm.fileExists(atPath: bundleAuth) && fm.fileExists(atPath: bundlePam) {
                return (bundleAuth, bundlePam)
            }
        }

        let cwd = FileManager.default.currentDirectoryPath
        let buildAuth = "\(cwd)/.build/release/MacHelloAuth"
        let buildPam = "\(cwd)/.build/release/pam_machello.so"
        if fm.fileExists(atPath: buildAuth) && fm.fileExists(atPath: buildPam) {
            return (buildAuth, buildPam)
        }

        if fm.fileExists(atPath: authBinPath) && fm.fileExists(atPath: pamSoPath) {
            return (authBinPath, pamSoPath)
        }

        return nil
    }

    /// 在终端中直接运行安装脚本（使用标准的 .command 机制，避开 AppleScript 自动化权限拦截）
    public func runInstallInTerminal(onCompleted: (() -> Void)? = nil) {
        let scriptPath: String
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL,
           fm.fileExists(atPath: resURL.appendingPathComponent("install-pam.sh").path) {
            scriptPath = resURL.appendingPathComponent("install-pam.sh").path
        } else {
            let cwd = fm.currentDirectoryPath
            scriptPath = "\(cwd)/scripts/install-pam.sh"
        }

        let commandFile = "/tmp/machello_install.command"
        let commandContent = """
        #!/bin/bash
        clear
        echo "======================================================"
        echo "  🍏 MacHello 终端 Sudo 刷脸提权一键配置"
        echo "======================================================"
        echo ""
        echo "👉 请输入您的 Mac 登录密码以完成系统 PAM 授权配置："
        echo ""
        sudo "\(scriptPath)"
        echo ""
        echo "======================================================"
        echo "🎉 全部配置已完成！按任意键关闭此窗口..."
        echo "======================================================"
        read -n 1 -s
        exit 0
        """

        try? commandContent.write(toFile: commandFile, atomically: true, encoding: .utf8)
        _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", commandFile]
        try? task.run()

        // 轮询检查安装结果，一旦生效立即回调通知
        var checksRemaining = 30
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            checksRemaining -= 1
            if PAMManager.shared.isInstalled {
                timer.invalidate()
                onCompleted?()
            } else if checksRemaining <= 0 {
                timer.invalidate()
            }
        }
    }

    /// 在终端中直接运行卸载脚本
    public func runUninstallInTerminal(onCompleted: (() -> Void)? = nil) {
        let scriptPath: String
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL,
           fm.fileExists(atPath: resURL.appendingPathComponent("uninstall-pam.sh").path) {
            scriptPath = resURL.appendingPathComponent("uninstall-pam.sh").path
        } else {
            let cwd = fm.currentDirectoryPath
            scriptPath = "\(cwd)/scripts/uninstall-pam.sh"
        }

        let commandFile = "/tmp/machello_uninstall.command"
        let commandContent = """
        #!/bin/bash
        clear
        echo "======================================================"
        echo "  🧹 MacHello 终端 Sudo 刷脸提权卸载还原"
        echo "======================================================"
        echo ""
        echo "👉 请输入您的 Mac 登录密码以安全还原系统 PAM 配置："
        echo ""
        sudo "\(scriptPath)"
        echo ""
        echo "======================================================"
        echo "✅ 卸载已完成！按任意键关闭此窗口..."
        echo "======================================================"
        read -n 1 -s
        exit 0
        """

        try? commandContent.write(toFile: commandFile, atomically: true, encoding: .utf8)
        _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", commandFile]
        try? task.run()

        var checksRemaining = 30
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            checksRemaining -= 1
            if !PAMManager.shared.isInstalled {
                timer.invalidate()
                onCompleted?()
            } else if checksRemaining <= 0 {
                timer.invalidate()
            }
        }
    }

    /// 打开系统偏好设置：完全磁盘访问权限
    public func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 在 GUI 中通过 macOS 原生管理员密码提权弹窗一键安装
    @discardableResult
    public func installViaGUI() -> (success: Bool, isPermissionDenied: Bool, error: String?) {
        guard let (authSrc, pamSrc) = resolveSourceFiles() else {
            return (false, false, "未找到认证核心或动态库文件，请确保应用包完整。")
        }

        let tmpScriptPath = "/tmp/machello_pam_install.sh"
        let scriptContent = """
        #!/bin/sh
        set -e
        mkdir -p /usr/local/bin /usr/local/lib/pam
        cp "\(authSrc)" "\(authBinPath)"
        chmod 755 "\(authBinPath)"
        cp "\(pamSrc)" "\(pamSoPath)"
        chmod 555 "\(pamSoPath)"

        if [ ! -f "\(sudoLocalPath)" ]; then
            printf '%s\\n' '# sudo_local: local config file which survives system updates' 'auth       sufficient     \(pamSoPath)' > "\(sudoLocalPath)"
            chmod 444 "\(sudoLocalPath)"
        elif ! grep -q "pam_machello.so" "\(sudoLocalPath)"; then
            TEMP_F=$(mktemp)
            printf '%s\\n' 'auth       sufficient     \(pamSoPath)' > "$TEMP_F"
            cat "\(sudoLocalPath)" >> "$TEMP_F"
            cat "$TEMP_F" > "\(sudoLocalPath)"
            rm -f "$TEMP_F"
            chmod 444 "\(sudoLocalPath)"
        fi
        """

        do {
            try scriptContent.write(toFile: tmpScriptPath, atomically: true, encoding: .utf8)
        } catch {
            return (false, false, "创建临时脚本失败: \(error.localizedDescription)")
        }

        let appleScriptSource = "do shell script \"/bin/sh \(tmpScriptPath) && /bin/rm -f \(tmpScriptPath)\" with administrator privileges"
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: appleScriptSource) {
            appleScript.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "用户取消或授权失败"
                _ = try? FileManager.default.removeItem(atPath: tmpScriptPath)
                let isPermDenied = msg.contains("Operation not permitted") || msg.contains("Permission denied")
                return (false, isPermDenied, msg)
            }
            let installed = self.isInstalled
            return (installed, false, installed ? nil : "写入配置未生效，请检查系统权限")
        }

        return (false, false, "无法初始化系统认证授权")
    }

    /// 在 GUI 中通过 macOS 原生管理员密码弹窗一键卸载还原
    @discardableResult
    public func uninstallViaGUI() -> (success: Bool, error: String?) {
        let tmpScriptPath = "/tmp/machello_pam_uninstall.sh"
        let scriptContent = """
        #!/bin/sh
        set -e
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

        do {
            try scriptContent.write(toFile: tmpScriptPath, atomically: true, encoding: .utf8)
        } catch {
            return (false, "创建临时脚本失败: \(error.localizedDescription)")
        }

        let appleScriptSource = "do shell script \"/bin/sh \(tmpScriptPath) && /bin/rm -f \(tmpScriptPath)\" with administrator privileges"
        var errorDict: NSDictionary?
        if let appleScript = NSAppleScript(source: appleScriptSource) {
            appleScript.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "用户取消或授权失败"
                _ = try? FileManager.default.removeItem(atPath: tmpScriptPath)
                return (false, msg)
            }
            return (!self.isInstalled, !self.isInstalled ? nil : "卸载未完全生效")
        }

        return (false, "无法初始化系统认证授权")
    }
}

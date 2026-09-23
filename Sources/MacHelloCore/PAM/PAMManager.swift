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

    /// 在终端中直接运行安装配置脚本（使用标准 .command 机制，避开系统 AppleScript 自动化权限拦截）
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

        // 轮询检查安装结果，一旦生效立即回调通知状态栏刷新
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

    /// 在终端中直接运行卸载还原脚本
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
}

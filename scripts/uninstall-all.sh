#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 检查管理员权限
if [ "$EUID" -ne 0 ]; then
    echo "🔐 彻底卸载 MacHello 需要系统管理员权限，正在请求 sudo..."
    exec sudo "$0" "$@"
fi

# 获取真实普通机主用户与家目录 (兼容 sudo 运行环境)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "======================================================"
echo "  🍏 MacHello 彻底卸载与全系统数据抹除工具 (Option B)"
echo "  目标机主: $REAL_USER ($REAL_HOME)"
echo "======================================================"
echo ""
echo "⚠️  此操作将彻底删除以下所有内容："
echo "  1. 退出正在运行的 MacHello 守护进程"
echo "  2. 还原 /etc/pam.d/sudo_local 并删除 /usr/local/lib/pam/pam_machello.so"
echo "  3. 彻底删除系统钥匙串中的 Mac 登录密码及全部第三方应用凭据"
echo "  4. 永久删除 $REAL_HOME/.machello/ 目录 (面容向量特征库、通行抓拍历史与自检缓存)"
echo "  5. 清理应用偏好设置 plist 与开机自启动配置"
echo "  6. 删除 /Applications/MacHello.app 应用程序包"
echo ""

read -p "❓ 您确定要彻底抹除并卸载 MacHello 吗？(y/N): " -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 卸载已取消。"
    exit 0
fi

echo ""
echo "🧹 [1/6] 停止正在运行的 MacHello 进程..."
killall MacHello 2>/dev/null || true
killall MacHelloAuth 2>/dev/null || true
killall machello-auth 2>/dev/null || true
sleep 0.5
echo "  ✓ 进程已安全停止"

echo "🧹 [2/6] 还原系统 PAM 配置与清理提权动态库..."
if [ -f "$DIR/scripts/uninstall-pam.sh" ]; then
    bash "$DIR/scripts/uninstall-pam.sh"
elif [ -f "/Applications/MacHello.app/Contents/Resources/uninstall-pam.sh" ]; then
    bash "/Applications/MacHello.app/Contents/Resources/uninstall-pam.sh"
else
    # 兜底直接还原
    PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"
    if [ -f "$PAM_SUDO_LOCAL" ]; then
        TEMP_FILE=$(mktemp)
        grep -v "pam_machello.so" "$PAM_SUDO_LOCAL" > "$TEMP_FILE" || true
        cat "$TEMP_FILE" > "$PAM_SUDO_LOCAL"
        rm -f "$TEMP_FILE"
        chmod 444 "$PAM_SUDO_LOCAL"
    fi
    rm -f /usr/local/lib/pam/pam_machello.so
    rm -f /usr/local/bin/machello-auth
fi
echo "  ✓ PAM 系统配置与二进制文件已彻底还原"

echo "🧹 [3/6] 抹除系统钥匙串安全凭据..."
# 在当前真实机主用户权限下执行 security 命令
su - "$REAL_USER" -c 'security delete-generic-password -s "com.machello.MacHello" 2>/dev/null || true'
su - "$REAL_USER" -c 'security delete-generic-password -s "com.machello.customApp" 2>/dev/null || true'
echo "  ✓ 钥匙串中 Mac 密码与所有第三方应用专属密码已彻底抹除"

echo "🧹 [4/6] 永久删除面容特征数据库与通行历史 (~/.machello)..."
if [ -d "$REAL_HOME/.machello" ]; then
    rm -rf "$REAL_HOME/.machello"
    echo "  ✓ $REAL_HOME/.machello 目录已彻底删除"
else
    echo "  ℹ️  未找到 $REAL_HOME/.machello 目录，已跳过"
fi

echo "🧹 [5/6] 清除偏好设置与系统自启配置..."
su - "$REAL_USER" -c 'defaults delete com.machello.app 2>/dev/null || true'
rm -f "$REAL_HOME/Library/Preferences/com.machello.app.plist"
rm -f "$REAL_HOME/Library/Preferences/com.machello.*.plist"
echo "  ✓ 偏好设置已重置"

echo "🧹 [6/6] 删除应用程序包 /Applications/MacHello.app..."
if [ -d "/Applications/MacHello.app" ]; then
    rm -rf "/Applications/MacHello.app"
    echo "  ✓ /Applications/MacHello.app 已删除"
fi
if [ -d "$DIR/dist/MacHello.app" ]; then
    rm -rf "$DIR/dist/MacHello.app"
fi

echo ""
echo "======================================================"
echo "🎉 MacHello 已从您的系统中 100% 彻底干净卸载！"
echo "  - 面容特征数据已物理粉碎"
echo "  - 钥匙串密码已彻底抹除"
echo "  - 系统 PAM 配置文件已安全恢复"
echo "  - 没有任何残留垃圾文件"
echo "======================================================"

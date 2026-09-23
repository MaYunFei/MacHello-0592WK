#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "🔐 卸载 PAM 模块需要管理员权限，正在请求提权..."
    exec sudo "$0" "$@"
fi

echo "======================================================"
echo "  🧹 MacHello PAM 终端 Sudo 刷脸提权卸载程序"
echo "======================================================"

INSTALL_BIN="/usr/local/bin/machello-auth"
INSTALL_PAM_SO="/usr/local/lib/pam/pam_machello.so"
PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"

if [ -f "$PAM_SUDO_LOCAL" ]; then
    echo "⚙️ 正在还原 $PAM_SUDO_LOCAL ..."
    # 移除 pam_machello.so 相关行
    TEMP_FILE=$(mktemp)
    grep -v "pam_machello.so" "$PAM_SUDO_LOCAL" > "$TEMP_FILE" || true
    cat "$TEMP_FILE" > "$PAM_SUDO_LOCAL"
    rm "$TEMP_FILE"
    chmod 444 "$PAM_SUDO_LOCAL"
fi

if [ -f "$INSTALL_PAM_SO" ]; then
    echo "🗑️ 移除 $INSTALL_PAM_SO ..."
    rm -f "$INSTALL_PAM_SO"
fi

if [ -f "$INSTALL_BIN" ]; then
    echo "🗑️ 移除 $INSTALL_BIN ..."
    rm -f "$INSTALL_BIN"
fi

echo "======================================================"
echo "✅ 卸载完成，系统认证配置已安全还原。"
echo "======================================================"

#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "🔐 安装 PAM 模块需要管理员权限，正在请求提权..."
    exec sudo "$0" "$@"
fi

echo "======================================================"
echo "  🍏 MacHello PAM 终端 Sudo 刷脸免密提权安装程序"
echo "======================================================"

# 1. 查找二进制
if [ -f "$DIR/machello-auth" ] && [ -f "$DIR/pam_machello.so" ]; then
    AUTH_BIN="$DIR/machello-auth"
    PAM_SO="$DIR/pam_machello.so"
elif [ -f "/Applications/MacHello.app/Contents/Resources/machello-auth" ]; then
    AUTH_BIN="/Applications/MacHello.app/Contents/Resources/machello-auth"
    PAM_SO="/Applications/MacHello.app/Contents/Resources/pam_machello.so"
else
    "$DIR/scripts/build-pam.sh"
    AUTH_BIN="$DIR/.build/release/MacHelloAuth"
    PAM_SO="$DIR/.build/release/pam_machello.so"
fi

# 2. 安装目标路径
INSTALL_BIN="/usr/local/bin/machello-auth"
INSTALL_PAM_DIR="/usr/local/lib/pam"
INSTALL_PAM_SO="$INSTALL_PAM_DIR/pam_machello.so"
PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"

echo "📦 正在复制可执行文件与动态库..."
mkdir -p /usr/local/bin
cp "$AUTH_BIN" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"

mkdir -p "$INSTALL_PAM_DIR"
cp "$PAM_SO" "$INSTALL_PAM_SO"
chmod 555 "$INSTALL_PAM_SO"

# 3. 配置 /etc/pam.d/sudo_local
echo "⚙️ 正在配置 $PAM_SUDO_LOCAL ..."

PAM_LINE="auth       sufficient     $INSTALL_PAM_SO"

if [ ! -f "$PAM_SUDO_LOCAL" ]; then
    cat << EOF > "$PAM_SUDO_LOCAL"
# sudo_local: local config file which survives system updates
# MacHello Face ID Sudo Authentication
$PAM_LINE
EOF
    chmod 444 "$PAM_SUDO_LOCAL"
else
    # 检查是否已经配置过
    if grep -q "pam_machello.so" "$PAM_SUDO_LOCAL"; then
        echo "ℹ️  已存在 pam_machello.so 配置，跳过写入。"
    else
        # 备份原文件
        cp "$PAM_SUDO_LOCAL" "${PAM_SUDO_LOCAL}.bak"
        # 写入最前方
        TEMP_FILE=$(mktemp)
        echo "$PAM_LINE" > "$TEMP_FILE"
        cat "$PAM_SUDO_LOCAL" >> "$TEMP_FILE"
        cat "$TEMP_FILE" > "$PAM_SUDO_LOCAL"
        rm "$TEMP_FILE"
        chmod 444 "$PAM_SUDO_LOCAL"
    fi
fi

echo "======================================================"
echo "🎉 安装成功！"
echo "👉 现在在任何终端执行 'sudo 任意命令'，即可体验 Windows Hello 级红外秒速刷脸提权！"
echo "👉 随时卸载请运行: sudo ./scripts/uninstall-pam.sh"
echo "======================================================"

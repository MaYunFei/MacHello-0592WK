#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="machello-server"

echo "======================================================"
echo "  🐧 安装 MacHello Linux Presence Server 为系统服务"
echo "======================================================"

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ 请使用 sudo 执行此安装脚本: sudo ./install-service.sh"
    exit 1
fi

# 检查 Python 3
command -v python3 >/dev/null 2>&1 || { echo "❌ 请先安装 python3"; exit 1; }

echo "📦 [1/3] 检查并安装依赖包..."
pip3 install --break-system-packages -r "$DIR/requirements.txt" 2>/dev/null || pip3 install -r "$DIR/requirements.txt" 2>/dev/null || true

# 杀掉可能存在的残留前台或 nohup 进程
if pgrep -f 'machello_server.py' >/dev/null 2>&1; then
    echo "🛑 停止现存的手动运行进程..."
    pkill -9 -f 'machello_server.py' || true
    sleep 1
fi

echo "⚙️ [2/3] 配置 systemd 服务文件..."
cat << EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=MacHello Dell 0592WK Linux Presence Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${DIR}
ExecStart=/usr/bin/python3 ${DIR}/machello_server.py
Restart=always
RestartSec=3
Environment=PORT=8765

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 [3/3] 重新加载 systemd 并启用开机自启..."
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo "======================================================"
echo "🎉 安装完成！MacHello Linux 服务已作为 systemd 守护进程运行并设为开机自启！"
echo "👉 查看状态: systemctl status ${SERVICE_NAME}"
echo "👉 查看实时日志: journalctl -u ${SERVICE_NAME} -f"
echo "👉 默认服务端口: http://192.168.66.5:8765"
echo "======================================================"

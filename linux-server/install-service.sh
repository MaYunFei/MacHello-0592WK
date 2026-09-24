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

# 检查 Python 3 与 pip
command -v python3 >/dev/null 2>&1 || { echo "❌ 请先安装 python3"; exit 1; }

echo "📦 [1/3] 安装依赖包..."
pip3 install -r "$DIR/requirements.txt" || pip install -r "$DIR/requirements.txt"

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

echo "🚀 [3/3] 重新加载 systemd 并启动服务..."
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo "======================================================"
echo "🎉 安装完成！MacHello Linux 服务已经在后台运行并开机自启！"
echo "👉 查看状态: sudo systemctl status ${SERVICE_NAME}"
echo "👉 查看实时日志: sudo journalctl -u ${SERVICE_NAME} -f"
echo "👉 默认服务端口: http://<此机IP>:8765"
echo "======================================================"

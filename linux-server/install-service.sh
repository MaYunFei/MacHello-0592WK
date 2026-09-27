#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="machello-server"

echo "======================================================"
echo "  🐧 Installing MacHello Linux Server as Systemd Service"
echo "======================================================"

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Please run this script with sudo: sudo ./install-service.sh"
    exit 1
fi

# Check Python 3
command -v python3 >/dev/null 2>&1 || { echo "❌ Please install python3 first"; exit 1; }

echo "📦 [1/3] Checking and installing dependencies..."
pip3 install --break-system-packages -r "$DIR/requirements.txt" 2>/dev/null || pip3 install -r "$DIR/requirements.txt" 2>/dev/null || true

# Kill existing manual process if any
if pgrep -f 'machello_server.py' >/dev/null 2>&1; then
    echo "🛑 Stopping existing manual process..."
    pkill -9 -f 'machello_server.py' || true
    sleep 1
fi

echo "⚙️ [2/3] Configuring systemd service file..."
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

echo "🚀 [3/3] Reloading systemd and enabling service on boot..."
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo "======================================================"
echo "🎉 Installation complete! MacHello Linux service is running as a systemd daemon!"
echo "👉 Check status: systemctl status ${SERVICE_NAME}"
echo "👉 View live logs: journalctl -u ${SERVICE_NAME} -f"
echo "👉 Default port: http://0.0.0.0:8765"
echo "======================================================"

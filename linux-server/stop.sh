#!/bin/bash
if systemctl is-active --quiet machello-server 2>/dev/null; then
    echo "🛑 通过 systemd 停止 MacHello Server..."
    sudo systemctl stop machello-server || systemctl stop machello-server
fi

pkill -f 'machello_server.py' 2>/dev/null || true
echo "MacHello Server 已停止"

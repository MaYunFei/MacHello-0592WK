#!/bin/bash
if systemctl is-active --quiet machello-server 2>/dev/null; then
    echo "🛑 Stopping MacHello Server via systemd..."
    sudo systemctl stop machello-server || systemctl stop machello-server
    exit 0
fi

pkill -9 -f 'machello_server.py' 2>/dev/null || true
echo "🛑 MacHello Server stopped."

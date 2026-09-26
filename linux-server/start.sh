#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if systemctl is-active --quiet machello-server 2>/dev/null; then
    echo "MacHello Server 正在由 systemd 运行中"
    systemctl status machello-server --no-pager
    exit 0
fi

if systemctl list-unit-files machello-server.service 2>/dev/null | grep -q machello-server; then
    echo "🚀 通过 systemd 启动 MacHello Server..."
    sudo systemctl start machello-server || systemctl start machello-server
    systemctl status machello-server --no-pager
    exit 0
fi

if pgrep -f 'machello_server.py' > /dev/null; then
    echo "MacHello Server 已经在运行中 (PID: $(pgrep -f 'machello_server.py'))"
else
    nohup python3 "$DIR/machello_server.py" > "$DIR/server.log" 2>&1 &
    sleep 1
    echo "MacHello Server 启动成功！(PID: $(pgrep -f 'machello_server.py'))"
    echo "日志查看: tail -f $DIR/server.log"
fi

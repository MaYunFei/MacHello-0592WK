#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if systemctl is-active --quiet machello-server 2>/dev/null; then
    echo "MacHello Server is currently running via systemd"
    systemctl status machello-server --no-pager
    exit 0
fi

if systemctl list-unit-files machello-server.service 2>/dev/null | grep -q machello-server; then
    echo "🚀 Starting MacHello Server via systemd..."
    sudo systemctl start machello-server || systemctl start machello-server
    systemctl status machello-server --no-pager
    exit 0
fi

if pgrep -f 'machello_server.py' > /dev/null; then
    echo "MacHello Server is already running (PID: $(pgrep -f 'machello_server.py'))"
else
    nohup python3 "$DIR/machello_server.py" > "$DIR/server.log" 2>&1 &
    sleep 1
    echo "MacHello Server started successfully! (PID: $(pgrep -f 'machello_server.py'))"
    echo "Log output: tail -f $DIR/server.log"
fi

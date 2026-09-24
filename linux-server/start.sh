#!/bin/bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if pgrep -f 'machello_server.py' > /dev/null; then
    echo "MacHello Server 已经在运行中 (PID: $(pgrep -f 'machello_server.py'))"
else
    nohup python3 "$DIR/machello_server.py" > "$DIR/server.log" 2>&1 &
    sleep 1
    echo "MacHello Server 启动成功！(PID: $(pgrep -f 'machello_server.py'))"
    echo "日志查看: tail -f $DIR/server.log"
fi

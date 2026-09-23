#!/bin/bash
echo "正在触发 macOS 原生 GUI 管理员密码弹窗..."
result=$(osascript -e 'do shell script "echo 验证成功，当前权限为: $(whoami)" with administrator privileges')
echo "$result"

#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "🔨 正在编译 MacHelloAuth (Swift 原生人脸认证核心)..."
swift build -c release --product MacHelloAuth

AUTH_BIN="$DIR/.build/release/MacHelloAuth"

echo "🔨 正在编译 pam_machello.so (PAM 动态链接库)..."
mkdir -p "$DIR/.build/release"
clang -shared -fPIC -lpam -O2 -Wall -Wextra -Werror \
    -o "$DIR/.build/release/pam_machello.so" \
    Sources/MacHelloPAM/pam_machello.c

echo "✅ 编译完成！"
echo "  - 认证二进制: $AUTH_BIN"
echo "  - PAM 动态库: $DIR/.build/release/pam_machello.so"

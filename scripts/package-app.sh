#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "======================================================"
echo "  🍏 正在打包 MacHello.app (原生 macOS 应用程序)"
echo "======================================================"

# 1. 编译 Release 产品
echo "📦 [1/5] 编译优化版二进制文件 (Release)..."
swift build -c release --product MacHello
swift build -c release --product MacHelloAuth

# 2. 编译 PAM 动态链接库
echo "📦 [2/5] 编译 pam_machello.so..."
mkdir -p .build/release
clang -shared -fPIC -lpam -O2 -Wall -Wextra -Werror \
    -o .build/release/pam_machello.so \
    Sources/MacHelloPAM/pam_machello.c

# 3. 准备 AppIcon
if [ ! -f "AppIcon.icns" ]; then
    echo "🎨 [3/5] 生成高清 AppIcon.icns..."
    swift scripts/generate-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
else
    echo "🎨 [3/5] 发现已有 AppIcon.icns..."
fi

# 4. 构建 .app Bundle 目录结构
APP_NAME="MacHello.app"
APP_DIR="$DIR/dist/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "🔨 [4/5] 组装应用包目录: $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 拷贝主程序
cp .build/release/MacHello "$MACOS_DIR/MacHello"
chmod 755 "$MACOS_DIR/MacHello"

# 拷贝内置资源与 PAM 认证核心
cp .build/release/MacHelloAuth "$RESOURCES_DIR/machello-auth"
chmod 755 "$RESOURCES_DIR/machello-auth"
cp .build/release/pam_machello.so "$RESOURCES_DIR/pam_machello.so"
chmod 555 "$RESOURCES_DIR/pam_machello.so"
cp scripts/install-pam.sh "$RESOURCES_DIR/install-pam.sh"
chmod 755 "$RESOURCES_DIR/install-pam.sh"
cp scripts/uninstall-pam.sh "$RESOURCES_DIR/uninstall-pam.sh"
chmod 755 "$RESOURCES_DIR/uninstall-pam.sh"
cp AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

# 生成 Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>MacHello</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.machello.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacHello</string>
    <key>CFBundleDisplayName</key>
    <string>MacHello</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>MacHello 需要使用戴尔 0592WK 摄像头进行红外人脸录入、人体存在检测与 Face ID 身份认证。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 代码签名（优先使用本机已有的 Apple Development 开发者签名，彻底避免钥匙串每次重新询问）
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔏 正在使用苹果官方开发者证书签名: $SIGN_IDENTITY ..."
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.machello.app" "$APP_DIR"
else
    echo "🔏 使用本地稳定签名..."
    codesign --force --deep --sign - --identifier "com.machello.app" "$APP_DIR"
fi

echo "✅ [5/5] 打包成功: $APP_DIR"

# 5. 可选：安装到 /Applications
if [ "$1" == "--install" ] || [ "$1" == "-i" ]; then
    echo "🚀 正在将应用安装到系统 /Applications 目录..."
    killall MacHello 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/"
    echo "======================================================"
    echo "🎉 安装完成！MacHello.app 已经位于您的「应用程序」文件夹中！"
    echo "👉 您可以随时从启动台 (Launchpad)、聚焦搜索 (Spotlight) 或访达中双击运行！"
    echo "======================================================"
    open "/Applications/$APP_NAME"
fi

#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "======================================================"
echo "  🍏 Packaging MacHello.app (Native macOS Application)"
echo "======================================================"

# 1. Compile Release Binaries
echo "📦 [1/5] Building Release binaries..."
swift build -c release --product MacHello
swift build -c release --product MacHelloAuth

# 2. Compile PAM Shared Library
echo "📦 [2/5] Compiling pam_machello.so..."
mkdir -p .build/release
clang -shared -fPIC -lpam -O2 -Wall -Wextra -Werror \
    -o .build/release/pam_machello.so \
    Sources/MacHelloPAM/pam_machello.c

# 3. Prepare AppIcon
if [ ! -f "AppIcon.icns" ]; then
    echo "🎨 [3/5] Generating AppIcon.icns..."
    swift scripts/generate-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
else
    echo "🎨 [3/5] Using existing AppIcon.icns..."
fi

# 4. Construct .app Bundle Directory Structure
APP_NAME="MacHello.app"
APP_DIR="$DIR/dist/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "🔨 [4/5] Assembling bundle: $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy main binary
cp .build/release/MacHello "$MACOS_DIR/MacHello"
chmod 755 "$MACOS_DIR/MacHello"

# Copy resources & PAM authentication core
cp .build/release/MacHelloAuth "$RESOURCES_DIR/machello-auth"
chmod 755 "$RESOURCES_DIR/machello-auth"
cp .build/release/pam_machello.so "$RESOURCES_DIR/pam_machello.so"
chmod 555 "$RESOURCES_DIR/pam_machello.so"
cp scripts/install-pam.sh "$RESOURCES_DIR/install-pam.sh"
chmod 755 "$RESOURCES_DIR/install-pam.sh"
cp scripts/uninstall-pam.sh "$RESOURCES_DIR/uninstall-pam.sh"
chmod 755 "$RESOURCES_DIR/uninstall-pam.sh"
cp AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

# Generate Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
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
    <string>MacHello requires camera access for infrared face recognition, human presence detection, and Face ID authentication. / MacHello 需要使用摄像头进行红外人脸录入、人体存在检测与 Face ID 身份认证。</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Code signing
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
if [ -n "$SIGN_IDENTITY" ]; then
    echo "🔏 Signing with Apple Development certificate: $SIGN_IDENTITY ..."
    codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "com.machello.app" "$APP_DIR"
else
    echo "🔏 Signing ad-hoc..."
    codesign --force --deep --sign - --identifier "com.machello.app" "$APP_DIR"
fi

echo "✅ [5/5] Packaged successfully: $APP_DIR"

# 5. Optional: install to /Applications
if [ "$1" == "--install" ] || [ "$1" == "-i" ]; then
    echo "🚀 Installing to /Applications..."
    killall MacHello 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/"
    echo "======================================================"
    echo "🎉 Installation complete! MacHello.app is now in /Applications!"
    echo "👉 You can run it anytime from Launchpad, Spotlight, or Finder."
    echo "======================================================"
    open "/Applications/$APP_NAME"
fi

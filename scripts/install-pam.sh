#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "🔐 Installing PAM module requires administrator privileges, requesting sudo..."
    exec sudo "$0" "$@"
fi

echo "======================================================"
echo "  🍏 MacHello PAM Sudo Face ID Setup"
echo "======================================================"

# 1. Locate binaries
if [ -f "$DIR/machello-auth" ] && [ -f "$DIR/pam_machello.so" ]; then
    AUTH_BIN="$DIR/machello-auth"
    PAM_SO="$DIR/pam_machello.so"
elif [ -f "/Applications/MacHello.app/Contents/Resources/machello-auth" ]; then
    AUTH_BIN="/Applications/MacHello.app/Contents/Resources/machello-auth"
    PAM_SO="/Applications/MacHello.app/Contents/Resources/pam_machello.so"
else
    "$DIR/scripts/build-pam.sh"
    AUTH_BIN="$DIR/.build/release/MacHelloAuth"
    PAM_SO="$DIR/.build/release/pam_machello.so"
fi

# 2. Installation destinations
INSTALL_BIN="/usr/local/bin/machello-auth"
INSTALL_PAM_DIR="/usr/local/lib/pam"
INSTALL_PAM_SO="$INSTALL_PAM_DIR/pam_machello.so"
PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"

echo "📦 Copying binaries and shared library..."
mkdir -p /usr/local/bin
cp "$AUTH_BIN" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"

mkdir -p "$INSTALL_PAM_DIR"
cp "$PAM_SO" "$INSTALL_PAM_SO"
chmod 555 "$INSTALL_PAM_SO"

# 3. Configure /etc/pam.d/sudo_local
echo "⚙️ Configuring $PAM_SUDO_LOCAL ..."

PAM_LINE="auth       sufficient     $INSTALL_PAM_SO"

if [ ! -f "$PAM_SUDO_LOCAL" ]; then
    cat << EOF > "$PAM_SUDO_LOCAL"
# sudo_local: local config file which survives system updates
# MacHello Face ID Sudo Authentication
$PAM_LINE
EOF
    chmod 444 "$PAM_SUDO_LOCAL"
else
    # Check if already configured
    if grep -q "pam_machello.so" "$PAM_SUDO_LOCAL"; then
        echo "ℹ️  Configuration for pam_machello.so already exists, skipping."
    else
        # Backup original
        cp "$PAM_SUDO_LOCAL" "${PAM_SUDO_LOCAL}.bak"
        # Prepend line
        TEMP_FILE=$(mktemp)
        echo "$PAM_LINE" > "$TEMP_FILE"
        cat "$PAM_SUDO_LOCAL" >> "$TEMP_FILE"
        cat "$TEMP_FILE" > "$PAM_SUDO_LOCAL"
        rm "$TEMP_FILE"
        chmod 444 "$PAM_SUDO_LOCAL"
    fi
fi

echo "======================================================"
echo "🎉 Setup successful!"
echo "👉 Run 'sudo <command>' in any terminal to experience IR Face ID unlock!"
echo "👉 To uninstall anytime, run: sudo ./scripts/uninstall-pam.sh"
echo "======================================================"

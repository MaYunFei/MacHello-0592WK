#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "🔐 Uninstalling PAM module requires administrator privileges, requesting sudo..."
    exec sudo "$0" "$@"
fi

echo "======================================================"
echo "  🧹 MacHello PAM Sudo Face ID Uninstallation"
echo "======================================================"

INSTALL_BIN="/usr/local/bin/machello-auth"
INSTALL_PAM_SO="/usr/local/lib/pam/pam_machello.so"
PAM_SUDO_LOCAL="/etc/pam.d/sudo_local"

if [ -f "$PAM_SUDO_LOCAL" ]; then
    echo "⚙️ Restoring $PAM_SUDO_LOCAL ..."
    TEMP_FILE=$(mktemp)
    grep -v "pam_machello.so" "$PAM_SUDO_LOCAL" > "$TEMP_FILE" || true
    cat "$TEMP_FILE" > "$PAM_SUDO_LOCAL"
    rm "$TEMP_FILE"
    chmod 444 "$PAM_SUDO_LOCAL"
fi

if [ -f "$INSTALL_PAM_SO" ]; then
    echo "🗑️ Removing $INSTALL_PAM_SO ..."
    rm -f "$INSTALL_PAM_SO"
fi

if [ -f "$INSTALL_BIN" ]; then
    echo "🗑️ Removing $INSTALL_BIN ..."
    rm -f "$INSTALL_BIN"
fi

echo "======================================================"
echo "✅ Uninstallation complete. System PAM configuration safely restored."
echo "======================================================"

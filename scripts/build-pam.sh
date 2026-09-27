#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "🔨 Building MacHelloAuth (Swift Native Face Auth Core)..."
swift build -c release --product MacHelloAuth

AUTH_BIN="$DIR/.build/release/MacHelloAuth"

echo "🔨 Compiling pam_machello.so (PAM shared library)..."
mkdir -p "$DIR/.build/release"
clang -shared -fPIC -lpam -O2 -Wall -Wextra -Werror \
    -o "$DIR/.build/release/pam_machello.so" \
    Sources/MacHelloPAM/pam_machello.c

echo "✅ Compilation complete!"
echo "  - Auth binary: $AUTH_BIN"
echo "  - PAM library: $DIR/.build/release/pam_machello.so"

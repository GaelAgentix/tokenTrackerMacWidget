#!/bin/bash
# Builds build/Token Tracker.app. Pass --install to copy it to ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TokenTracker"

APP="build/Token Tracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenTracker"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Token Tracker.app"
    mkdir -p "$HOME/Applications"
    pkill -x TokenTracker 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi

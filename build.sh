#!/bin/bash
# Build LunoBTCBar.app, install to ~/Applications, and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LunoBTCBar.app"
DEST="$HOME/Applications/LunoBTCBar.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/LunoBTCBar" main.swift DayRange.swift
codesign --force --sign - "$APP"

pkill -x LunoBTCBar || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed: $DEST"

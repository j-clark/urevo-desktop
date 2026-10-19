#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/WalkingPad.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WalkingPad "$APP/Contents/MacOS/WalkingPad"
swift scripts/make-icon.swift .build/WalkingPad.iconset
iconutil -c icns .build/WalkingPad.iconset -o "$APP/Contents/Resources/WalkingPad.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>WalkingPad</string>
  <key>CFBundleIdentifier</key><string>local.joshclark.walkingpad</string>
  <key>CFBundleName</key><string>WalkingPad</string>
  <key>CFBundleDisplayName</key><string>WalkingPad</string>
  <key>CFBundleIconFile</key><string>WalkingPad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>WalkingPad uses Bluetooth to connect to your Urevo walking pad, read its live speed, and send controls you choose.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>WalkingPad uses Bluetooth to connect to and control your walking pad.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"

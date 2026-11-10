#!/bin/bash
# Builds build/IronPet.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/IronPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/IronPet" "$APP/Contents/MacOS/IronPet"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ghost's sprite sheet is drawn in code; bundle it so the pet works without any setup.
swift tools/make_wolf.swift ghost "$APP/Contents/Resources/spritesheet.png" >/dev/null

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.ironpet.app</string>
  <key>CFBundleName</key><string>ironpet</string>
  <key>CFBundleDisplayName</key><string>ironpet</string>
  <key>CFBundleExecutable</key><string>IronPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ironpet switches to the iTerm tab where an agent is waiting.</string>
  <key>NSScreenCaptureUsageDescription</key><string>ironpet captures a window or region when you ask it for help with your screen.</string>
</dict>
</plist>
PLIST

IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"ironpet-dev"'; then IDENTITY="ironpet-dev"; fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP"

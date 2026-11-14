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
# Mermaid diagrams in the chat: a pinned mermaid.js from npm, checked against its SHA-256 and cached in
# build/vendor so it is downloaded once. Without network the app still builds; diagrams then show as code.
MERMAID_VERSION=12.2.0
MERMAID_SHA256=a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f
MERMAID_JS="build/vendor/mermaid-$MERMAID_VERSION.min.js"
if [ ! -f "$MERMAID_JS" ]; then
  mkdir -p build/vendor
  TMP=$(mktemp -d)
  if curl -fsSL "https://registry.npmjs.org/mermaid/-/mermaid-$MERMAID_VERSION.tgz" -o "$TMP/mermaid.tgz" \
     && tar -xzf "$TMP/mermaid.tgz" -C "$TMP" package/dist/mermaid.min.js \
     && [ "$(shasum -a 256 "$TMP/package/dist/mermaid.min.js" | cut -d' ' -f1)" = "$MERMAID_SHA256" ]; then
    mv "$TMP/package/dist/mermaid.min.js" "$MERMAID_JS"
  else
    echo "warning: could not fetch mermaid $MERMAID_VERSION; diagrams will show as code" >&2
  fi
  rm -rf "$TMP"
fi
if [ -f "$MERMAID_JS" ]; then
  cp "$MERMAID_JS" "$APP/Contents/Resources/mermaid.min.js"
  cp Resources/mermaid.html "$APP/Contents/Resources/mermaid.html"
fi
# ACP adapters for Claude Code, Codex and Pi: one self-contained .mjs per adapter (no node_modules, no agent binaries),
# run on the user's Node 22+ or a Bun they allow ironpet to download. Building needs Bun here, not on the user's Mac.
# `--omit=optional` keeps the agents' own platform binaries out of the install.
if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to bundle the ACP adapters (https://bun.sh)" >&2
  exit 1
fi
(
  cd sidecar
  npm ci --omit=optional --ignore-scripts --no-audit --no-fund >/dev/null
  rm -rf out
  for adapter in claude codex pi; do
    bun build --minify --target=node --format=esm "$adapter.mjs" --outfile "out/$adapter.mjs" >/dev/null
  done
)
mkdir -p "$APP/Contents/Resources/acp"
cp sidecar/out/claude.mjs sidecar/out/codex.mjs sidecar/out/pi.mjs "$APP/Contents/Resources/acp/"
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
  <key>NSMicrophoneUsageDescription</key><string>ironpet records your voice when you start a voice note, and sends it to the transcription server you set in Settings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>ironpet captures a window or region when you ask it for help with your screen.</string>
</dict>
</plist>
PLIST

# IRONPET_SIGN_IDENTITY=- forces ad-hoc signing, e.g. when the keychain would prompt for the ironpet-dev key.
IDENTITY="${IRONPET_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  if security find-identity -p codesigning 2>/dev/null | grep -q '"ironpet-dev"'; then IDENTITY="ironpet-dev"; fi
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP"

#!/bin/bash
# Builds ironpet, installs it to /Applications and (re)starts it. Safe to run again to update.
# First run also creates a local code signing identity so macOS keeps permissions across rebuilds.
# On first launch, ironpet's welcome window asks before changing anything outside ~/.ironpet.
set -euo pipefail
cd "$(dirname "$0")/.."

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

bold "Checking requirements"

MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] || fail "macOS 14 or later is required (this Mac has $MACOS)."
ok "macOS $MACOS"

command -v swift >/dev/null 2>&1 || fail "Swift not found. Install the Xcode command line tools: xcode-select --install"
SWIFT_VERSION="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1.\2/p' | head -1)"
[ -n "$SWIFT_VERSION" ] || fail "Couldn't read the Swift version. Try: xcode-select --install"
MAJOR="${SWIFT_VERSION%%.*}"; MINOR="${SWIFT_VERSION##*.}"
if [ "$MAJOR" -lt 5 ] || { [ "$MAJOR" -eq 5 ] && [ "$MINOR" -lt 10 ]; }; then
  fail "Swift 5.10 or later is required (found $SWIFT_VERSION). Update Xcode or its command line tools."
fi
ok "Swift $SWIFT_VERSION"

command -v openssl >/dev/null 2>&1 || fail "openssl not found (it ships with macOS; check your PATH)."

found_agent=0
for cli in "$HOME/.local/bin/cursor-agent" /opt/homebrew/bin/cursor-agent /usr/local/bin/cursor-agent; do
  if [ -x "$cli" ]; then ok "cursor-agent ($cli)"; found_agent=1; break; fi
done
for cli in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude"; do
  if [ -x "$cli" ]; then ok "Claude Code ($cli)"; found_agent=1; break; fi
done
if [ "$found_agent" = 0 ]; then
  warn "Neither cursor-agent nor claude was found. The pet will run, but chat needs one of them:"
  warn "  Cursor CLI:  https://cursor.com/cli"
  warn "  Claude Code: https://docs.anthropic.com/claude-code"
fi
command -v gh >/dev/null 2>&1 && ok "GitHub CLI (optional, for PR alerts)" || warn "GitHub CLI not found (optional, for PR alerts): brew install gh"

bold "Signing identity"
if security find-identity -p codesigning 2>/dev/null | grep -q '"ironpet-dev"'; then
  ok "ironpet-dev already exists"
else
  echo "Creating a local, self-signed 'ironpet-dev' identity so Screen Recording and Automation permissions"
  echo "survive rebuilds. macOS may ask for your login password to trust it."
  ./scripts/make_signing_identity.sh || warn "Couldn't create it; building with an ad-hoc signature (permissions reset on each rebuild)."
fi

bold "Building (this takes a minute the first time)"
mkdir -p build
if ! ./scripts/bundle.sh > build/install.log 2>&1; then
  tail -30 build/install.log >&2
  fail "Build failed; the full log is in build/install.log"
fi
ok "Built build/IronPet.app"

bold "Installing"
pkill -f "IronPet.app/Contents/MacOS/IronPet" || true
sleep 1
rm -rf /Applications/IronPet.app
cp -R build/IronPet.app /Applications/IronPet.app
open /Applications/IronPet.app
ok "Installed /Applications/IronPet.app and started it"
echo
echo "On first launch a welcome window asks what the pet may do. Settings: ⌘, or right-click the pet."
echo "To remove everything later: ./scripts/uninstall.sh"

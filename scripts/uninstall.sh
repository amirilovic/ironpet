#!/bin/bash
# Removes ironpet: its hooks (other tools' hooks are left alone), login item, app, Keychain item and preferences.
# Asks before deleting your chats and notes in ~/.ironpet and the local signing identity.
#   --purge   also delete ~/.ironpet and the signing identity without asking (task copies in worktrees/ still ask)
#   --yes     answer yes to every question (same as --purge)
set -euo pipefail

APP=/Applications/IronPet.app
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge|--yes|-y) PURGE=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
ask() {
  [ "$PURGE" = 1 ] && return 0
  [ -t 0 ] || return 1
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}
# Asks even with --purge. Without a terminal the answer is no.
confirm() {
  [ -t 0 ] || return 1
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}

pkill -f "IronPet.app/Contents/MacOS/IronPet" 2>/dev/null && ok "Quit ironpet" || true

# Hooks and login item: the app knows exactly which entries are its own.
if [ -x "$APP/Contents/MacOS/IronPet" ]; then
  "$APP/Contents/MacOS/IronPet" --uninstall | while read -r line; do ok "$line"; done
else
  warn "$APP not found, so its hooks can't be removed automatically."
  warn "Delete the entries containing .ironpet/bin/ironpet-hook from the agents' configs (~/.cursor/hooks.json, ~/.claude/settings.json, ~/.codex/hooks.json, ~/.gemini/settings.json) and delete ~/.copilot/hooks/ironpet.json and ~/.pi/agent/extensions/ironpet.ts."
fi
for backup in "$HOME/.cursor/hooks.json.ironpet-backup" "$HOME/.claude/settings.json.ironpet-backup"; do
  [ -e "$backup" ] && warn "Kept $backup (your file from before ironpet was installed; delete it if you don't need it)."
done

if [ -d "$APP" ]; then
  rm -rf "$APP"
  ok "Deleted $APP"
fi

if security find-generic-password -s ironpet.sentry >/dev/null 2>&1; then
  while security delete-generic-password -s ironpet.sentry >/dev/null 2>&1; do :; done
  ok "Deleted the Sentry token from the Keychain"
fi

if security find-generic-password -s ironpet.voice >/dev/null 2>&1; then
  while security delete-generic-password -s ironpet.voice >/dev/null 2>&1; do :; done
  ok "Deleted the voice transcription API key from the Keychain"
fi

if security find-generic-password -s ironpet.voiceprints >/dev/null 2>&1; then
  while security delete-generic-password -s ironpet.voiceprints >/dev/null 2>&1; do :; done
  rm -rf "$HOME/Library/Application Support/IronPet"
  ok "Deleted the stored voiceprints and their Keychain key"
fi

defaults delete dev.ironpet.app >/dev/null 2>&1 && ok "Deleted preferences" || true
rm -rf "$HOME/.ironpet/bin" "$HOME/.ironpet/port"

# The app removed the clean task copies above. What is left has uncommitted work, or ironpet.db did not list it.
WORKTREES="$HOME/.ironpet/worktrees"
COPIES=0
if [ -d "$WORKTREES" ] && [ -n "$(ls -A "$WORKTREES" 2>/dev/null)" ]; then
  COPIES=1
  warn "Task copies agents worked in are still in $WORKTREES (uncommitted work may be in them)."
fi

if [ -d "$HOME/.ironpet" ]; then
  what="settings, saved chats, memory notes, screenshots"
  [ "$COPIES" = 1 ] && what="$what, and the task copies in worktrees/ with their uncommitted work"
  if ask "Delete ~/.ironpet ($what)?"; then
    if [ "$COPIES" = 1 ] && [ "$PURGE" = 1 ] && ! confirm "Also delete the task copies in $WORKTREES?"; then
      find "$HOME/.ironpet" -mindepth 1 -maxdepth 1 ! -name worktrees -exec rm -rf {} +
      ok "Deleted ~/.ironpet except worktrees/"
      warn "Kept the task copies in $WORKTREES. Delete them yourself, then run 'git worktree prune' in each project."
    else
      rm -rf "$HOME/.ironpet"
      ok "Deleted ~/.ironpet"
      [ "$COPIES" = 1 ] && warn "Run 'git worktree prune' in each project an agent worked on, so git forgets the deleted copies."
    fi
  else
    warn "Kept ~/.ironpet"
  fi
fi

if security find-identity -p codesigning 2>/dev/null | grep -q '"ironpet-dev"'; then
  if ask "Delete the local 'ironpet-dev' code signing identity?"; then
    security delete-identity -c ironpet-dev >/dev/null 2>&1 && ok "Deleted the ironpet-dev signing identity" \
      || warn "Couldn't delete it; remove 'ironpet-dev' in Keychain Access."
  else
    warn "Kept the ironpet-dev signing identity"
  fi
fi

echo
echo "ironpet is uninstalled. If you turned on Share MCP sign-ins, copied sign-ins stay in"
echo "~/.cursor/projects/*/mcp-auth.json until you sign out of those servers."

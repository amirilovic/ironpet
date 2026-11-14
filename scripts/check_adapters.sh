#!/bin/bash
# Starts the bundled ACP adapters with the user's `node` and checks that they answer `initialize`.
# The adapters' CLIs are stubbed with /usr/bin/true, so no agent needs to be installed. Codex is not started here:
# its adapter launches `codex app-server` and has nothing to say without a real binary.
# Usage: scripts/check_adapters.sh [build/IronPet.app]
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/IronPet.app}"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
status=0
for adapter in claude codex pi; do
  [ -f "$APP/Contents/Resources/acp/$adapter.mjs" ] || { echo "missing: $adapter.mjs"; status=1; }
done
check() {
  local name=$1; shift
  local out; out=$(mktemp)
  (printf '%s\n' "$INIT"; sleep 3) | env "$@" node "$APP/Contents/Resources/acp/$name.mjs" > "$out" 2>/dev/null || true
  if grep -q '"protocolVersion"' "$out"; then echo "ok: $name answers initialize"; else echo "FAIL: $name did not answer initialize"; status=1; fi
  rm -f "$out"
}
check claude CLAUDE_CODE_EXECUTABLE=/usr/bin/true
check pi PI_ACP_PI_COMMAND=/usr/bin/true
# Size guard: the bundle holds three adapters and no agent or runtime.
if [ -n "$(find "$APP" -size +20M)" ]; then echo "FAIL: a file over 20 MB is in the app bundle"; status=1; else echo "ok: no file over 20 MB in the bundle"; fi
exit $status

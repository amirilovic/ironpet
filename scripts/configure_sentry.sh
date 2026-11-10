#!/bin/bash
# Configures ironpet's Sentry alerts: host, org and optional projects go to ~/.ironpet/sentry.json,
# the auth token goes to the Keychain (readable by IronPet.app without a prompt).
# Create a token at <host>/settings/account/api/auth-tokens/ with the event:read and project:read scopes.
set -euo pipefail

read -r -p "Sentry host [https://sentry.io]: " HOST
HOST="${HOST:-https://sentry.io}"
read -r -p "Organization slug: " ORG
read -r -p "Project slugs to watch (comma-separated, empty for all): " PROJECTS
read -r -s -p "Auth token: " TOKEN
echo

STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$HOST/api/0/organizations/$ORG/")
if [ "$STATUS" != "200" ]; then
  echo "Sentry rejected the token for org '$ORG' (HTTP $STATUS)." >&2
  exit 1
fi

security add-generic-password -U -s ironpet.sentry -a "$ORG" -w "$TOKEN" \
  -T /Applications/IronPet.app -T "$(cd "$(dirname "$0")/.." && pwd)/build/IronPet.app"

mkdir -p "$HOME/.ironpet"
python3 - "$HOST" "$ORG" "$PROJECTS" > "$HOME/.ironpet/sentry.json" <<'EOF'
import json, sys
host, org, projects = sys.argv[1:4]
print(json.dumps({"host": host, "org": org, "projects": [p.strip() for p in projects.split(",") if p.strip()]}, indent=2))
EOF
echo "Saved. Restart ironpet to start watching Sentry."

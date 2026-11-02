#!/bin/bash
# Refuses distribution code that still permits debugger attachment.
# Checks the app and every signed Mach-O nested inside it without executing any.
set -euo pipefail

app="${1:?Usage: check-release-entitlements.sh path/to/Scope.app}"
entitlements="$(mktemp -t scope-release-entitlements)"
trap 'rm -f "$entitlements"' EXIT

check() {
  codesign -d --entitlements - --xml "$1" > "$entitlements" 2>/dev/null
  # A signed executable may have no entitlements at all.
  [ -s "$entitlements" ] || return 0
  plutil -lint "$entitlements" >/dev/null
  local debug
  debug="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)"
  if [ "$debug" = true ]; then
    echo "error: $1 has com.apple.security.get-task-allow enabled" >&2
    return 1
  fi
}

check "$app"
# -print0 keeps bundle and executable names with spaces intact. Only Mach-O
# code can carry a code-signing entitlement; resources are not executable.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    check "$candidate"
  fi
done < <(find "$app/Contents" -type f -print0)

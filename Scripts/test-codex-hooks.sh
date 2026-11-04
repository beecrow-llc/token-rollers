#!/bin/bash
# Tests Scripts/codex-hooks.sh against fixture hooks.json files in a temporary CODEX_HOME.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly SCRIPT="$PWD/Scripts/codex-hooks.sh"
readonly JQ=/usr/bin/jq
readonly BIN=/Apps/Stercorarius.app/Contents/MacOS/Stercorarius
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -r "$WORK"' EXIT
export CODEX_HOME="$WORK"
readonly HOOKS="$WORK/hooks.json"
failures=0

check() {
  local description="$1"
  shift
  if "$@"; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

fails_quietly() { ! "$@" 2>/dev/null; }

value() { "$JQ" -r "$1" "$HOOKS"; }

cat >"$HOOKS" <<'JSON'
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/x/notify.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/x/notify.sh" }] }],
    "PreCompact": []
  }
}
JSON
cp "$HOOKS" "$WORK/original.json"

"$SCRIPT" install "$BIN" >/dev/null
check "install keeps the existing Stop group first" \
  test "$(value '.hooks.Stop[0].hooks[0].command')" = /x/notify.sh
check "install appends the idle hook to Stop" \
  test "$(value '.hooks.Stop[1].hooks[0].command')" = "$BIN codex-hook idle"
check "install adds the busy hook to UserPromptSubmit" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BIN codex-hook busy"
check "install adds the idle hook to Interrupt" \
  test "$(value '.hooks.Interrupt[0].hooks[0].command')" = "$BIN codex-hook idle"
check "install adds the idle hook to SessionEnd" \
  test "$(value '.hooks.SessionEnd[0].hooks[0].command')" = "$BIN codex-hook idle"
check "install leaves SessionStart alone" \
  test "$(value '.hooks.SessionStart | tojson')" = \
  "$("$JQ" -r '.hooks.SessionStart | tojson' "$WORK/original.json")"
check "install adds no top-level keys" test "$(value 'keys | tojson')" = '["hooks"]'
check "install backs up the original" \
  test "$(find "$WORK" -name 'hooks.json.stercorarius-*.bak' | wc -l | tr -d ' ')" = 1

cp "$HOOKS" "$WORK/installed.json"
"$SCRIPT" install "$BIN" >/dev/null
check "a second install leaves the file byte-identical" cmp -s "$HOOKS" "$WORK/installed.json"

"$SCRIPT" install /Other/Stercorarius >/dev/null
check "installing from a new path leaves four Stercorarius commands" \
  test "$(value '[.. | .command? // empty | select(contains("Stercorarius codex-hook"))] | length')" = 4
check "installing from a new path keeps the existing Stop group first" \
  test "$(value '.hooks.Stop[0].hooks[0].command')" = /x/notify.sh

"$SCRIPT" uninstall /Other/Stercorarius >/dev/null
check "uninstall restores the original content" \
  test "$("$JQ" -S . "$HOOKS")" = "$("$JQ" -S . "$WORK/original.json")"

rm "$HOOKS"
"$SCRIPT" install "$BIN" >/dev/null
check "install creates a missing hooks.json" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BIN codex-hook busy"

echo '{"hooks": []}' >"$HOOKS"
cp "$HOOKS" "$WORK/invalid.json"
check "install rejects a hooks.json whose .hooks is not an object" \
  fails_quietly "$SCRIPT" install "$BIN"
check "a rejected hooks.json is left untouched" cmp -s "$HOOKS" "$WORK/invalid.json"

if [ "$failures" -gt 0 ]; then
  echo "$failures installer check(s) failed"
  exit 1
fi
echo "All installer checks passed"

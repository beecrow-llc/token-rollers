#!/bin/bash
# Tests Scripts/codex-hooks.sh against fixture hooks.json files in a temporary CODEX_HOME.
# shellcheck disable=SC2016 # jq programs in single quotes use jq variables such as $i.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly SCRIPT="$PWD/Scripts/codex-hooks.sh"
readonly JQ=/usr/bin/jq
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -r "$WORK"' EXIT
export CODEX_HOME="$WORK/codex"
readonly HOOKS="$CODEX_HOME/hooks.json"
# A fake Stercorarius in a path with a space; it records the arguments it runs with.
readonly BIN="$WORK/My Apps/Stercorarius.app/Contents/MacOS/Stercorarius"
readonly BUSY="'$BIN' codex-hook busy"
readonly IDLE="'$BIN' codex-hook idle"
readonly OTHER_BIN=/Other/Stercorarius
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

fails_quietly() { ! "$@" >/dev/null 2>&1; }

value() { "$JQ" -r "$1" "$HOOKS"; }

same_json() { test "$("$JQ" -S . "$1")" = "$("$JQ" -S . "$2")"; }

with_later_stop_group() {
  "$JQ" '.hooks.Stop += [{hooks: [{type: "command", command: "/y/later.sh"}]}]' "$1"
}

mkdir -p "$CODEX_HOME" "$(dirname "$BIN")"
printf '#!/bin/sh\necho "$@" >"%s/args.txt"\n' "$WORK" >"$BIN"
chmod +x "$BIN"

cat >"$HOOKS" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/x/notify.sh" }] },
      { "hooks": [{ "type": "command", "command": "echo 'Stercorarius codex-hook idle' >> /tmp/a" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/x/notify.sh" }] },
      { "hooks": [] }
    ],
    "PreCompact": []
  }
}
JSON
cp "$HOOKS" "$WORK/original.json"

"$SCRIPT" install "$BIN" >/dev/null
check "install keeps the existing Stop groups first" \
  test "$(value '[.hooks.Stop[0:2][] | .hooks | length] | tojson')" = '[1,0]'
check "install appends the idle hook to Stop" \
  test "$(value '.hooks.Stop[2].hooks[0].command')" = "$IDLE"
check "install adds the busy hook to UserPromptSubmit" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BUSY"
check "install adds the idle hook to Interrupt" \
  test "$(value '.hooks.Interrupt[0].hooks[0].command')" = "$IDLE"
check "install adds the idle hook to SessionEnd" \
  test "$(value '.hooks.SessionEnd[0].hooks[0].command')" = "$IDLE"
check "install leaves SessionStart alone, including a look-alike command" \
  test "$(value '.hooks.SessionStart | tojson')" = \
  "$("$JQ" -r '.hooks.SessionStart | tojson' "$WORK/original.json")"
check "install adds no top-level keys" test "$(value 'keys | tojson')" = '["hooks"]'
check "install backs up the original" \
  cmp -s "$(find "$CODEX_HOME" -name 'hooks.json.stercorarius-*.bak')" "$WORK/original.json"

/bin/zsh -c "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')"
check "the busy command runs through the shell despite the space in its path" \
  test "$(cat "$WORK/args.txt")" = "codex-hook busy"

cp "$HOOKS" "$WORK/installed.json"
"$SCRIPT" install "$BIN" >/dev/null
check "a second install leaves the file byte-identical" cmp -s "$HOOKS" "$WORK/installed.json"

"$SCRIPT" uninstall "$BIN" >/dev/null
check "uninstall restores the original, keeping its empty group and array" \
  same_json "$HOOKS" "$WORK/original.json"

"$SCRIPT" install "$BIN" >/dev/null
with_later_stop_group "$HOOKS" >"$WORK/later.json"
cp "$WORK/later.json" "$HOOKS"
"$SCRIPT" install "$OTHER_BIN" >/dev/null
check "installing from a new path rewrites every Stercorarius command" \
  test "$(value '[.. | .command? // empty | select(contains("/Stercorarius"))] | unique | tojson')" \
  = "$("$JQ" -nc --arg b "'$OTHER_BIN' codex-hook busy" --arg i "'$OTHER_BIN' codex-hook idle" \
    '[$b, $i]')"
check "installing from a new path keeps every Stop group in place" \
  test "$(value '[.hooks.Stop[] | .hooks[0].command // "-"] | tojson')" \
  = "$("$JQ" -nc --arg i "'$OTHER_BIN' codex-hook idle" '["/x/notify.sh", "-", $i, "/y/later.sh"]')"

"$SCRIPT" uninstall "$OTHER_BIN" >/dev/null
with_later_stop_group "$WORK/original.json" >"$WORK/original-later.json"
check "uninstall removes only Stercorarius handlers" same_json "$HOOKS" "$WORK/original-later.json"

rm "$HOOKS"
"$SCRIPT" install "$BIN" >/dev/null
check "install creates a missing hooks.json" \
  test "$(value '.hooks.UserPromptSubmit[0].hooks[0].command')" = "$BUSY"

: >"$HOOKS"
"$SCRIPT" install "$BIN" >/dev/null
check "install fills an empty hooks.json" \
  test "$(value '.hooks.SessionEnd[0].hooks[0].command')" = "$IDLE"

mkdir -p "$WORK/dotfiles"
echo '{"hooks": {}}' >"$WORK/dotfiles/hooks.json"
rm "$HOOKS"
ln -s "$WORK/dotfiles/hooks.json" "$HOOKS"
"$SCRIPT" install "$BIN" >/dev/null
check "install keeps a symlinked hooks.json a symlink" test -L "$HOOKS"
check "install writes through the symlink" \
  test "$("$JQ" -r '.hooks.Stop[0].hooks[0].command' "$WORK/dotfiles/hooks.json")" = "$IDLE"

rm "$HOOKS"
echo '{"hooks": []}' >"$HOOKS"
cp "$HOOKS" "$WORK/invalid.json"
check "install rejects a hooks.json whose .hooks is not an object" \
  fails_quietly "$SCRIPT" install "$BIN"
echo '{"hooks": {' >"$HOOKS"
cp "$HOOKS" "$WORK/broken.json"
check "uninstall fails on a hooks.json it cannot parse" fails_quietly "$SCRIPT" uninstall "$BIN"
check "a rejected hooks.json is left untouched" cmp -s "$HOOKS" "$WORK/broken.json"
check "install rejects a binary path with a single quote" \
  fails_quietly "$SCRIPT" install "/tmp/it's/Stercorarius"
check "no temporary files are left behind" \
  test -z "$(find "$CODEX_HOME" "$WORK/dotfiles" -name 'hooks.json.??????')"

if [ "$failures" -gt 0 ]; then
  echo "$failures installer check(s) failed"
  exit 1
fi
echo "All installer checks passed"

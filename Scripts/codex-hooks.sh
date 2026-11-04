#!/bin/bash
# Adds or removes Stercorarius's hooks in Codex's hooks.json ($CODEX_HOME, default ~/.codex).
# Usage: Scripts/codex-hooks.sh install|uninstall <path to the Stercorarius binary>
#
# Codex rejects the whole file when it has an unknown top-level key, and its hook trust keys
# depend on array positions. So this only touches .hooks.<Event> arrays: install rewrites its own
# handlers in place and appends missing ones at the end; uninstall removes only its own handlers
# and the groups and arrays they leave empty.
# shellcheck disable=SC2016 # jq programs in single quotes use jq variables such as $busy.
set -euo pipefail

readonly USAGE="usage: $0 install|uninstall <stercorarius-binary>"
readonly ACTION="${1:?$USAGE}"
readonly BINARY="${2:?$USAGE}"
readonly JQ=/usr/bin/jq
readonly RESTART_NOTE="Restart Codex sessions and ChatGPT.app; loaded threads keep their old hooks."
HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.json"
# Edit the file behind a symlink (such as a dotfiles checkout) so that the link survives.
if [ -L "$HOOKS_FILE" ]; then HOOKS_FILE="$(/bin/realpath "$HOOKS_FILE")"; fi
readonly HOOKS_FILE
TMP_FILE=""
trap 'if [ -n "$TMP_FILE" ]; then rm -f "$TMP_FILE"; fi' EXIT

# Hook commands single-quote the binary path for the shell that Codex runs them with.
case "$BINARY" in
*\'*)
  echo "The Stercorarius path must not contain a single quote: $BINARY" >&2
  exit 2
  ;;
esac

# jq definitions; $busy and $idle are the complete hook commands, $q is a single quote.
readonly DEFS='
def ours:
  (.command // "")
  | test("^" + $q + "[^" + $q + "]*/Stercorarius" + $q + " codex-hook (busy|idle)$");
def wanted: {UserPromptSubmit: $busy, Stop: $idle, Interrupt: $idle, SessionEnd: $idle};
def document:
  (.[0] // {})
  | if type == "object" and ((.hooks // {}) | type) == "object" then .
    else error("hooks.json must be an object whose .hooks is an object") end;
def update_ours:
  .hooks |= with_entries(.key as $event
    | if wanted[$event] == null then .
      else .value |= map(if .hooks == null then .
        else .hooks |= map(if ours then .command = wanted[$event] else . end) end) end);
def append_missing:
  reduce (wanted | to_entries[]) as $e (.;
    if any(.hooks[$e.key][]?.hooks[]?; .command == $e.value) then .
    else .hooks[$e.key] = ((.hooks[$e.key] // [])
      + [{hooks: [{type: "command", command: $e.value}]}]) end);
def install: .hooks //= {} | update_ours | append_missing;
def strip_event:
  map(if any(.hooks[]?; ours)
    then (.hooks |= map(select(ours | not))) | select(.hooks != [])
    else . end);
def uninstall:
  if .hooks == null then .
  else .hooks |= with_entries(if any(.value[]?.hooks[]?; ours)
    then (.value |= strip_event) | select(.value != [])
    else . end) end;
'

run_jq() {
  "$JQ" --arg busy "'$BINARY' codex-hook busy" --arg idle "'$BINARY' codex-hook idle" \
    --arg q "'" "$DEFS $1" "${@:2}"
}

# Writes `document | <action>` over hooks.json (a missing or empty file counts as {}) to a temp
# file next to it, and checks that the result is still a hooks document.
transform() {
  local source="$HOOKS_FILE"
  if [ ! -f "$source" ]; then source=/dev/null; fi
  mkdir -p "$(dirname "$HOOKS_FILE")"
  TMP_FILE="$(mktemp "$HOOKS_FILE.XXXXXX")"
  run_jq "document | $1" --slurp "$source" >"$TMP_FILE"
  "$JQ" -e 'type == "object" and ((.hooks // {}) | type) == "object"' "$TMP_FILE" >/dev/null
}

# True when the temp file holds the same document as hooks.json.
unchanged() {
  [ -f "$HOOKS_FILE" ] &&
    "$JQ" -e --slurp --slurpfile new "$TMP_FILE" '(.[0] // {}) == $new[0]' "$HOOKS_FILE" \
      >/dev/null
}

# Moves the temp file over hooks.json, keeping its mode and a backup of the old content.
replace() {
  if [ -f "$HOOKS_FILE" ]; then
    chmod "$(stat -f %Lp "$HOOKS_FILE")" "$TMP_FILE"
    cp -p "$HOOKS_FILE" "$HOOKS_FILE.stercorarius-$(date +%Y%m%d-%H%M%S)-$$.bak"
  else
    chmod 644 "$TMP_FILE"
  fi
  mv "$TMP_FILE" "$HOOKS_FILE"
  TMP_FILE=""
}

install_hooks() {
  transform install
  if unchanged; then
    echo "Stercorarius hooks are already in $HOOKS_FILE."
    return
  fi
  replace
  cat <<EOF
Installed Stercorarius hooks in $HOOKS_FILE.
Next steps:
  1. Trust the hooks once: start \`codex\` and accept "Hooks need review" (or run /hooks),
     or open ChatGPT.app > Settings > Hooks.
  2. $RESTART_NOTE
EOF
}

uninstall_hooks() {
  if [ ! -f "$HOOKS_FILE" ]; then
    echo "No $HOOKS_FILE; nothing to remove."
    return
  fi
  transform uninstall
  if unchanged; then
    echo "No Stercorarius hooks in $HOOKS_FILE."
    return
  fi
  replace
  echo "Removed Stercorarius hooks from $HOOKS_FILE."
  echo "$RESTART_NOTE"
}

case "$ACTION" in
install) install_hooks ;;
uninstall) uninstall_hooks ;;
*)
  echo "$USAGE" >&2
  exit 2
  ;;
esac

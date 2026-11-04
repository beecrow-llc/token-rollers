#!/bin/bash
# Adds or removes Stercorarius's hooks in Codex's hooks.json ($CODEX_HOME, default ~/.codex).
# Usage: Scripts/codex-hooks.sh install|uninstall <path to the Stercorarius binary>
#
# Codex rejects the whole file when it has an unknown top-level key, and its hook trust keys
# depend on array positions. So this only appends groups to .hooks.<Event> arrays and removes
# its own handlers; everything else stays as it was.
set -euo pipefail

readonly USAGE="usage: $0 install|uninstall <stercorarius-binary>"
readonly ACTION="${1:?$USAGE}"
readonly BINARY="${2:?$USAGE}"
readonly JQ=/usr/bin/jq
readonly HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.json"
TMP_FILE=""
trap 'if [ -n "$TMP_FILE" ]; then rm -f "$TMP_FILE"; fi' EXIT

# jq definitions shared by every invocation; $bin is the Stercorarius binary.
# shellcheck disable=SC2016 # $bin, $root, $e and $had are jq variables, not shell ones.
readonly DEFS='
def ours: (.command // "") | contains("Stercorarius codex-hook");
def wanted: {
  UserPromptSubmit: "\($bin) codex-hook busy",
  Stop: "\($bin) codex-hook idle",
  Interrupt: "\($bin) codex-hook idle",
  SessionEnd: "\($bin) codex-hook idle"
};
def checked:
  if ((.hooks // {}) | type) == "object" then . else error("hooks.json: .hooks must be an object") end;
def installed: . as $root
  | all(wanted | to_entries[]; . as $e | any($root.hooks[$e.key][]?.hooks[]?; .command == $e.value));
def has_ours: any(.hooks[]?[]?.hooks[]?; ours);
def strip_group: if any(.hooks[]?; ours) then .hooks |= map(select(ours | not)) else . end;
def strip:
  .hooks |= (to_entries
    | map((.value | any(.[]?.hooks[]?; ours)) as $had
      | .value |= (if $had then map(strip_group | select(.hooks | length > 0)) else . end)
      | select(($had and .value == []) | not))
    | from_entries);
def append_ours:
  reduce (wanted | to_entries[]) as $e (.;
    .hooks[$e.key] = ((.hooks[$e.key] // []) + [{hooks: [{type: "command", command: $e.value}]}]));
'

run_jq() { "$JQ" --arg bin "$BINARY" "$DEFS $1" "${@:2}"; }

# Rewrites hooks.json through the jq filter $1: backup, validate, then atomic replace.
rewrite() {
  TMP_FILE="$(mktemp "$HOOKS_FILE.XXXXXX")"
  run_jq "$1" "$HOOKS_FILE" >"$TMP_FILE"
  "$JQ" empty "$TMP_FILE"
  chmod "$(stat -f %Lp "$HOOKS_FILE")" "$TMP_FILE"
  cp -p "$HOOKS_FILE" "$HOOKS_FILE.stercorarius-$(date +%Y%m%d-%H%M%S)-$$.bak"
  mv "$TMP_FILE" "$HOOKS_FILE"
  TMP_FILE=""
}

install_hooks() {
  if [ ! -f "$HOOKS_FILE" ]; then
    mkdir -p "$(dirname "$HOOKS_FILE")"
    run_jq '{hooks: {}} | append_ours' -n >"$HOOKS_FILE"
  elif run_jq 'checked | installed' -e "$HOOKS_FILE" >/dev/null; then
    echo "Stercorarius hooks are already in $HOOKS_FILE."
    return
  else
    rewrite 'checked | .hooks //= {} | strip | append_ours'
  fi
  cat <<EOF
Installed Stercorarius hooks in $HOOKS_FILE.
Next steps:
  1. Trust the hooks once: start \`codex\` and accept "Hooks need review" (or run /hooks),
     or open ChatGPT.app > Settings > Hooks.
  2. Restart Codex sessions and ChatGPT.app; threads that are already loaded keep their old hooks.
EOF
}

uninstall_hooks() {
  if [ -f "$HOOKS_FILE" ] && run_jq 'has_ours' -e "$HOOKS_FILE" >/dev/null; then
    rewrite 'strip'
    echo "Removed Stercorarius hooks from $HOOKS_FILE."
  else
    echo "No Stercorarius hooks in $HOOKS_FILE."
  fi
}

case "$ACTION" in
install) install_hooks ;;
uninstall) uninstall_hooks ;;
*)
  echo "$USAGE" >&2
  exit 2
  ;;
esac

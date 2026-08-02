#!/usr/bin/env bash
set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$docs_dir/../.." && pwd)"
engine="$repo_root/packaging/npm/aiur-cli/libexec/aiur-engine.sh"
parser="$repo_root/src/lib/aiur/cli.ex"
dev_shim="$repo_root/scripts/aiurdev"
page="$docs_dir/reference/cli.md"

fail=0

source_commands="$(
  sed -n '/^aiur_engine_main()/,$p' "$engine" \
    | sed -n '/^  case "\$cmd" in/,/^    "")/p' \
    | sed -n 's/^    \([^)]*\))$/\1/p' \
    | tr '|' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | rg -v '^(__identity|""|-\*|\*)$' \
    | sort -u
)"

source_flags="$(
  {
    # The release parser owns normal run, init, todo, and acknowledgement flags.
    sed -n '/@switches \[/,/^  \]/p' "$parser" \
      | sed -n 's/^    \([a-z_][a-z_]*\): .*/--\1/p' \
      | tr '_' '-'
    sed -n 's/^  @acknowledgement_switch :\([a-z_][a-z_]*\)$/--\1/p' "$parser" | tr '_' '-'

    # Launcher usage plus command parsers own shared-engine control flags.
    sed -n '/^usage() {/,/^}/p' "$engine"
    sed -n '/^cmd_alerts() {/,/^cmd_set() {/p' "$engine"

    # These two bounded blocks are the dev-only public surface, not mix-reset internals.
    sed -n '/if \[ "${1:-}" = "build" \]; then/,/^# --- dev test/p' "$dev_shim"
    sed -n '/^# --- dev test/,/^if \[ -n "\$agent_workspace_marker" \]; then/p' "$dev_shim"
  } \
    | rg -o -- '--[a-z][a-z0-9-]*' \
    | sort -u
)"

documented_commands="$(
  rg -o '<!-- cli-command: [^ ]+ -->' "$page" \
    | sed 's/.*cli-command: //; s/ -->//' \
    | sort -u
)"

documented_flags="$(
  rg -o '<!-- cli-flag: --[a-z0-9-]+ -->' "$page" \
    | sed 's/.*cli-flag: //; s/ -->//' \
    | sort -u
)"

has_complete_table_row() {
  local token="$1"

  awk -F '|' -v token="$token" '
    index($0, token) > 0 && NF >= 5 && $2 !~ /^[[:space:]-]*$/ &&
      $3 !~ /^[[:space:]-]*$/ && $4 !~ /^[[:space:]-]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$page"
}

compare_source_to_docs() {
  local kind="$1" source="$2" documented="$3" token

  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if ! printf '%s\n' "$documented" | rg -Fxq -- "$token"; then
      printf 'missing CLI %s marker: %s\n' "$kind" "$token" >&2
      fail=1
    fi
  done <<EOF
$source
EOF

  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if ! printf '%s\n' "$source" | rg -Fxq -- "$token"; then
      printf 'stale CLI %s marker: %s\n' "$kind" "$token" >&2
      fail=1
    fi
  done <<EOF
$documented
EOF
}

compare_source_to_docs command "$source_commands" "$documented_commands"
compare_source_to_docs flag "$source_flags" "$documented_flags"

while IFS= read -r command; do
  [ -n "$command" ] || continue
  if ! has_complete_table_row "$command"; then
    printf 'CLI command lacks syntax, behavior, or runnable-example row: %s\n' "$command" >&2
    fail=1
  fi
done <<EOF
$source_commands
EOF

while IFS= read -r flag; do
  [ -n "$flag" ] || continue
  if ! has_complete_table_row "$flag"; then
    printf 'CLI flag lacks syntax, default/interaction, or runnable-example row: %s\n' "$flag" >&2
    fail=1
  fi
done <<EOF
$source_flags
EOF

exit "$fail"

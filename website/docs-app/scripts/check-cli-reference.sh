#!/usr/bin/env bash
set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$docs_dir/../.." && pwd)"
engine="$repo_root/packaging/npm/aiur-cli/libexec/aiur-engine.sh"
parser="$repo_root/src/lib/aiur/cli.ex"
dev_shim="$repo_root/scripts/aiurdev"
page="$docs_dir/reference/cli.md"
source_dev_commands="$(sed -n 's/^if \[ "${1:-}" = "\([a-z-]*\)" \]; then$/\1/p' "$dev_shim" | sort -u)"

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

    # Every dispatched control handler is authoritative, including handlers
    # absent from the usage banner such as cleanup-stale.
    sed -n '/^usage() {/,/^}/p' "$engine"
    awk '/^cmd_[a-z_]+\(\)/ { in_command = 1 } in_command { print } in_command && /^}/ { in_command = 0 }' "$engine"

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
documented_dev_commands="$(rg -o '<!-- cli-dev-command: [a-z-]+ -->' "$page" | sed 's/.*cli-dev-command: //; s/ -->//' | sort -u)"
documented_planned_flags="$(rg -o '<!-- cli-planned-flag: --[a-z0-9-]+ -->' "$page" | sed 's/.*cli-planned-flag: //; s/ -->//' | sort -u)"
documented_planned_commands="$(rg -o '<!-- cli-planned-command: [a-z-]+ -->' "$page" | sed 's/.*cli-planned-command: //; s/ -->//' | sort -u)"

has_complete_table_row() {
  local token="$1"

  case "$token" in
    -h|-help|--h|--help) token="help" ;;
  esac

  awk -F '|' -v token="$token" '
    $2 ~ "(^|[^[:alnum:]-])" token "([^[:alnum:]-]|$)" && NF >= 5 && $2 !~ /^[[:space:]-]*$/ &&
      $3 !~ /^[[:space:]-]*$/ && $4 !~ /^[[:space:]-]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$page"
}

rendered_flags="$(awk -F '|' 'NF >= 5 { print $2 }' "$page" | rg -o -- '--[a-z][a-z0-9-]*' | sort -u)"
source_word_commands="$(printf '%s\n' "$source_commands" | rg '^[a-z][a-z-]*$')"
rendered_commands="$(awk -F '|' 'NF >= 5 { print $2 }' "$page" | rg -o -- 'aiur[[:space:]]+[a-z][a-z-]*' | sed 's/^aiur[[:space:]]*//' | sort -u)"
rendered_dev_commands="$(awk -F '|' 'NF >= 5 { print $2 }' "$page" | rg -o -- 'scripts/aiurdev[[:space:]]+[a-z][a-z-]*' | sed 's|^scripts/aiurdev[[:space:]]*||' | sort -u)"
source_flag_tokens="$(printf '%s\n%s\n%s\n' "$source_flags" "$source_commands" "$documented_planned_flags" | rg '^--' | sort -u)"
source_prose_commands="$(printf '%s\n%s\n' "$source_word_commands" "$documented_planned_commands" | sort -u)"
prose_flags="$(rg -o --no-filename -- '--[a-z][a-z0-9-]*' "$page" | sort -u)"
prose_commands="$(rg -o --no-filename -- 'aiur[[:space:]]+[a-z][a-z-]*' "$page" | sed 's/^aiur[[:space:]]*//' | sort -u)"

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
compare_source_to_docs rendered-command "$source_word_commands" "$rendered_commands"
compare_source_to_docs rendered-flag "$source_flags" "$rendered_flags"
compare_source_to_docs dev-command "$source_dev_commands" "$documented_dev_commands"
compare_source_to_docs rendered-dev-command "$source_dev_commands" "$rendered_dev_commands"
compare_source_to_docs prose-flag "$source_flag_tokens" "$prose_flags"
compare_source_to_docs prose-command "$source_prose_commands" "$prose_commands"

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

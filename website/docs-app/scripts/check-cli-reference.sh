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
    | rg '^[a-z][a-z-]*$' \
    | sort -u
)"

source_flags="$(
  {
    # The release parser owns normal run, init, todo, and acknowledgement flags.
    sed -n '/@switches \[/,/^  \]/p' "$parser" \
      | sed -n 's/^    \([a-z_][a-z_]*\): .*/--\1/p' \
      | tr '_' '-'
    sed -n 's/^  @acknowledgement_switch :\([a-z_][a-z_]*\)$/--\1/p' "$parser" | tr '_' '-'

    # Control-handler flags come from the real argument-parsing arms, not from
    # the usage banner or function comments: a `--flag)` case arm, a
    # `--flag=*)` case arm, or a `[ "$1" = "--flag" ]` comparison is proof the
    # launcher parses that flag. Anything a comment or the help banner mentions
    # without such a parse arm is not a shipped flag and must not be required.
    awk '
      /^[a-z_]+\(\)/ { in_command = 1; in_case = 0 }
      in_command && /^[[:space:]]*case[[:space:]]/ { in_case = 1 }
      in_command && in_case && /^[[:space:]]*--[a-z0-9-]*([=][*])?\)/ { print }
      in_command && in_case && /^[[:space:]]*esac/ { in_case = 0 }
      in_command && /= "--[a-z0-9-]*"/ { print }
      in_command && /^}/ { in_command = 0; in_case = 0 }
    ' "$engine"

    # The dev-only surface is the shim's own flag parser: the force-rebuild
    # arms and the bounded test-harness parser, never mix-reset internals.
    sed -n '/^if \[ "${1:-}" = "build" \]; then/,/^# --- dev test/p' "$dev_shim" \
      | awk '/= "--[a-z0-9-]*"/ { print }'
    sed -n '/^# --- dev test/,/^if \[ -n "\$agent_workspace_marker" \]; then/p' "$dev_shim" \
      | awk '/^[[:space:]]*case[[:space:]]/ { in_case = 1 }
             in_case && /^[[:space:]]*--[a-z0-9-]*([=][*])?\)/ { print }
             in_case && /^[[:space:]]*esac/ { in_case = 0 }'
  } \
    | rg -o -- '--[a-z][a-z0-9-]*' \
    | sort -u
)"

# The page used to carry `<!-- cli-command: ... -->` markers beside every entry.
# They duplicated the visible syntax column and cluttered the source, so the
# checker now reads the rendered tables and prose instead. The rendered-* and
# prose-* comparisons below cover exactly what the markers covered.

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
source_flag_tokens="$(printf '%s\n%s\n' "$source_flags" "$source_commands" | rg '^--' | sort -u)"
source_prose_commands="$source_word_commands"
prose_flags="$(rg -o --no-filename -- '--[a-z][a-z0-9-]*' "$page" | sort -u)"
prose_commands="$(rg -o --no-filename -- 'aiur[[:space:]]+[a-z][a-z-]*' "$page" | sed 's/^aiur[[:space:]]*//' | sort -u)"
prose_dev_commands="$(rg -o --no-filename -- 'scripts/aiurdev[[:space:]]+[a-z][a-z-]*' "$page" | sed 's|^scripts/aiurdev[[:space:]]*||' | sort -u)"

compare_source_to_docs() {
  local kind="$1" source="$2" documented="$3" missing stale

  missing="$(comm -23 <(printf '%s\n' "$source" | sed '/^$/d' | sort -u) <(printf '%s\n' "$documented" | sed '/^$/d' | sort -u))"
  stale="$(comm -13 <(printf '%s\n' "$source" | sed '/^$/d' | sort -u) <(printf '%s\n' "$documented" | sed '/^$/d' | sort -u))"

  if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | sed "s/^/missing CLI $kind marker: /" >&2
    fail=1
  fi

  if [ -n "$stale" ]; then
    printf '%s\n' "$stale" | sed "s/^/stale CLI $kind marker: /" >&2
    fail=1
  fi
}

compare_source_to_docs rendered-command "$source_word_commands" "$rendered_commands"
compare_source_to_docs rendered-flag "$source_flags" "$rendered_flags"
compare_source_to_docs rendered-dev-command "$source_dev_commands" "$rendered_dev_commands"
compare_source_to_docs prose-flag "$source_flag_tokens" "$prose_flags"
compare_source_to_docs prose-command "$source_prose_commands" "$prose_commands"
compare_source_to_docs prose-dev-command "$source_dev_commands" "$prose_dev_commands"

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

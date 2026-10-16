#!/usr/bin/env bash
set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$docs_dir/../.." && pwd)"
engine="$repo_root/packaging/npm/aiur-cli/libexec/aiur-engine.sh"
parser="$repo_root/src/lib/aiur/cli.ex"
dev_shim="$repo_root/scripts/aiurdev"
dev_harness="$repo_root/scripts/lib/aiurdev-harness.sh"
page="$docs_dir/reference/cli.md"
cli_launch_options_page="$docs_dir/reference/cli-options.md"
cli_reference_pages=("$page")
for command_page in "$docs_dir"/reference/*commands*.md; do
  [ -f "$command_page" ] && cli_reference_pages+=("$command_page")
done
cli_reference_pages+=("$docs_dir/reference/experiment-statistics.md")
cli_reference_pages+=("$docs_dir/reference/cli-options.md")
source_dev_commands="$(sed -n 's/^if \[ "${1:-}" = "\([a-z-]*\)" \]; then$/\1/p' "$dev_shim" "$dev_harness" | sort -u)"

fail=0

source_commands="$(
  sed -n '/^aiur_engine_main()/,$p' "$engine" \
    | sed -n '/^  case "\$cmd" in/,/^    "")/p' \
    | sed -n 's/^    \([^)]*\))\( .*\)\?$/\1/p' \
    | tr '|' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E '^[a-z][a-z-]*$' \
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
      in_command && /^[[:space:]]*case[[:space:]]/ { in_case++ }
      in_command && in_case && /^[[:space:]]*--[a-z0-9-]*([=][*])?\)/ { print }
      in_command && in_case && /^[[:space:]]*esac/ { in_case-- }
      in_command && /= "--[a-z0-9-]*"/ { print }
      in_command && /^}/ { in_command = 0; in_case = 0 }
    ' "$repo_root"/packaging/npm/aiur-cli/libexec/*.sh "$repo_root"/packaging/npm/aiur-cli/libexec/engine/*.sh

    # Experiments transports argv in the shell; its control client validates flags.
    sed -n '/^  @switches \[/,/^  \]/p' "$repo_root/src/lib/aiur/experiments_cli.ex" \
      | sed -n 's/^[[:space:]]*\([a-z_][a-z_]*\):.*/\1/p' \
      | sed '/^spec_json$/d; s/^/--/; s/_/-/g'

    # The offline statistics CLI owns its arguments in argparse declarations.
    sed -n 's/.*add_argument("\(--[a-z][a-z-]*\)".*/\1/p' \
      "$repo_root/analytics/lib/analytics/experiment_stats_cmd.py"

    sed -n 's/^  @usage "\(.*\)"$/\1/p' "$repo_root/src/lib/aiur/pr_merge_cli.ex" \
      | grep -oE -- '--[a-z][a-z0-9-]*'

    # Alerts also validates transported argv in its control client.
    sed -n '/^  defp parse(\[/p' "$repo_root/src/lib/aiur/alerts_cli.ex"

    # doctor delegates its flag parser to the standalone helper.
    sed -n 's/.*\$mode == \(--repair\).*/\1/p' "$repo_root/packaging/npm/aiur-cli/libexec/aiur-mise-doctor"

    # The dev-only surface is the shim's own flag parser: the force-rebuild
    # arms and the bounded test-harness parser, never mix-reset internals.
    sed -n '/^if \[ "${1:-}" = "build" \]; then/,/^# --- dev test/p' "$dev_harness" \
      | awk '/= "--[a-z0-9-]*"/ { print }'
    sed -n '/^# --- dev test/,/^if \[ -n "\$agent_workspace_marker" \]; then/p' "$dev_harness" \
      | awk '/^[[:space:]]*case[[:space:]]/ { in_case++ }
             in_case && /^[[:space:]]*--[a-z0-9-]*([=][*])?\)/ { print }
             in_case && /^[[:space:]]*esac/ { in_case-- }'
  } \
    | cat - <(awk -F '|' 'NF >= 5 { print $2 }' "$docs_dir/reference/cli-options.md" | grep -oE -- '--[a-z][a-z0-9-]*') \
    | grep -oE -- '--[a-z][a-z0-9-]*' \
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
  ' "${cli_reference_pages[@]}" "$cli_launch_options_page"
}

rendered_flags="$(cat "${cli_reference_pages[@]}" | awk -F '|' 'NF >= 5 { print $2 }' | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)"
source_word_commands="$(printf '%s\n' "$source_commands" | grep -E '^[a-z][a-z-]*$')"
rendered_commands="$(cat "${cli_reference_pages[@]}" | awk -F '|' 'NF >= 5 { print $2 }' | grep -oE -- 'aiur[[:space:]]+[a-z][a-z-]*' | sed 's/^aiur[[:space:]]*//' | sort -u)"
rendered_dev_commands="$(cat "${cli_reference_pages[@]}" | awk -F '|' 'NF >= 5 { print $2 }' | grep -oE -- 'scripts/aiurdev[[:space:]]+[a-z][a-z-]*' | sed 's|^scripts/aiurdev[[:space:]]*||' | sort -u)"
source_flag_tokens="$(printf '%s\n%s\n' "$source_flags" "$source_commands" | grep -E '^--' | sort -u)"
source_prose_commands="$source_word_commands"
prose_flags="$(cat "${cli_reference_pages[@]}" | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u)"
prose_commands="$(cat "${cli_reference_pages[@]}" | grep -oE -- 'aiur[[:space:]]+[a-z][a-z-]*' | sed 's/^aiur[[:space:]]*//' | sort -u)"
prose_dev_commands="$(cat "${cli_reference_pages[@]}" | grep -oE -- 'scripts/aiurdev[[:space:]]+[a-z][a-z-]*' | sed 's|^scripts/aiurdev[[:space:]]*||' | sort -u)"

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

compare_dev_commands_to_docs() {
  local kind="$1" special="$2" engine_commands="$3" documented="$4" missing stale valid

  missing="$(comm -23 <(printf '%s\n' "$special" | sed '/^$/d' | sort -u) <(printf '%s\n' "$documented" | sed '/^$/d' | sort -u))"
  valid="$(printf '%s\n%s\n' "$special" "$engine_commands" | sed '/^$/d' | sort -u)"
  stale="$(comm -13 <(printf '%s\n' "$valid") <(printf '%s\n' "$documented" | sed '/^$/d' | sort -u))"

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
compare_dev_commands_to_docs rendered-dev-command "$source_dev_commands" "$source_word_commands" "$rendered_dev_commands"
compare_source_to_docs prose-flag "$source_flag_tokens" "$prose_flags"
compare_source_to_docs prose-command "$source_prose_commands" "$prose_commands"
compare_dev_commands_to_docs prose-dev-command "$source_dev_commands" "$source_word_commands" "$prose_dev_commands"

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

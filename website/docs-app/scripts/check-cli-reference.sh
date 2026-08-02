#!/usr/bin/env bash
set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$docs_dir/../.." && pwd)"
engine="$repo_root/packaging/npm/aiur-cli/libexec/aiur-engine.sh"
parser="$repo_root/src/lib/aiur/cli.ex"
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
documented_commands="$(
  rg -o '<!-- cli-command: [^ ]+ -->' "$page" \
    | sed 's/.*cli-command: //; s/ -->//' \
    | sort -u
)"

while IFS= read -r command; do
  [ -n "$command" ] || continue
  if ! printf '%s\n' "$documented_commands" | rg -Fxq -- "$command"; then
    printf 'missing CLI command marker: %s\n' "$command" >&2
    fail=1
  fi
done <<EOF
$source_commands
EOF

while IFS= read -r command; do
  [ -n "$command" ] || continue
  if ! printf '%s\n' "$source_commands" | rg -Fxq -- "$command"; then
    printf 'stale CLI command marker: %s\n' "$command" >&2
    fail=1
  fi
done <<EOF
$documented_commands
EOF

parser_flags="$(
  sed -n '/@switches \[/,/^  \]/p' "$parser" \
    | sed -n 's/^    \([a-z_][a-z_]*\): .*/--\1/p' \
    | tr '_' '-'
)"

for flag in $parser_flags --i-understand-that-this-will-be-running-without-the-usual-guardrails --debug --bg --needs-attention --full --changes --once --interval --topic --payload --all --dry-run --deps --test --test3 --allow-remote --clear; do
  if ! rg -Fq -- "$flag" "$page"; then
    printf 'missing CLI flag: %s\n' "$flag" >&2
    fail=1
  fi
done

exit "$fail"

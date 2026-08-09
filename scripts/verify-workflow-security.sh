#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [workflow-or-action-path]" >&2
  exit 1
fi

workflow_path="${1:-.github/workflows}"
pin_paths=("$workflow_path")

if [[ "$#" -eq 0 && -d ".github/actions" ]]; then
  pin_paths+=(".github/actions")
fi

if [[ ! -d "$workflow_path" && ! -f "$workflow_path" ]]; then
  echo "workflow security guard: path not found: $workflow_path" >&2
  exit 1
fi

scan_yaml() {
  local path="$1"
  local pattern="$2"
  local grep_args=(-H -n -E)
  local symlink

  if [[ -L "$path" ]]; then
    echo "workflow security guard: scanner refused symlinked path: $path" >&2
    return 2
  fi

  if [[ -d "$path" ]]; then
    if ! symlink="$(find "$path" -type l -print -quit 2>&1)"; then
      echo "workflow security guard: scanner could not inspect symlinks under $path" >&2
      [[ -z "$symlink" ]] || echo "$symlink" >&2
      return 2
    fi

    if [[ -n "$symlink" ]]; then
      echo "workflow security guard: scanner refused symlink: $symlink" >&2
      return 2
    fi

    grep_args+=(-r --include='*.yml' --include='*.yaml')
  fi

  grep "${grep_args[@]}" -- "$pattern" "$path"
}

fail_on_scanner_error() {
  local status="$1"
  local output="$2"

  if [[ "$status" -gt 1 ]]; then
    echo "workflow security guard: scanner failed with status $status" >&2
    [[ -z "$output" ]] || echo "$output" >&2
    exit 1
  fi
}

# Raw-text checks cannot safely interpret escapes in double-quoted YAML keys.
# Reject them rather than letting an encoded trigger or `uses` key bypass grep.
for pin_path in "${pin_paths[@]}"; do
  if output="$(scan_yaml "$pin_path" '"[^"]*\\[^\"]*"[[:space:]]*:' 2>&1)"; then
    echo "$output"
    echo "workflow security guard: escaped double-quoted YAML keys are forbidden" >&2
    exit 1
  else
    status="$?"
    fail_on_scanner_error "$status" "$output"
  fi
done

# Explicit mapping keys can put `? uses` and its `:` on separate lines, which
# has no reliable raw-text equivalent to the simple key scanner below.
for pin_path in "${pin_paths[@]}"; do
  if output="$(scan_yaml "$pin_path" '^[[:space:]-]*\?[[:space:]]' 2>&1)"; then
    echo "$output"
    echo "workflow security guard: explicit YAML mapping keys are forbidden" >&2
    exit 1
  else
    status="$?"
    fail_on_scanner_error "$status" "$output"
  fi
done

# Bare-substring scan catches flow-map and list-form YAML in addition to key-colon form.
if output="$(scan_yaml "$workflow_path" 'pull_request_target|workflow_run' 2>&1)"; then
  echo "$output"
  echo "workflow security guard: pull_request_target and workflow_run are forbidden" >&2
  exit 1
else
  status="$?"
  fail_on_scanner_error "$status" "$output"
fi

# Third-party actions must be pinned to a full 40-hex-char commit SHA.
# Local (./) and docker:// references are not GitHub actions and are excluded.
uses_key_pattern="(^|[[:space:]{[,]+)(uses|\"uses\"|'uses')[[:space:]]*:[[:space:]]*"

for pin_path in "${pin_paths[@]}"; do
  if output="$(scan_yaml "$pin_path" "$uses_key_pattern" 2>&1)"; then
    unpinned=""

    while IFS= read -r line; do
      remaining="$line"
      line_unpinned=0

      # A flow sequence can contain several action mappings on one line, so
      # consume and validate every uses key instead of stopping at the first.
      while [[ "$remaining" =~ $uses_key_pattern ]]; do
        remaining="${remaining#*"${BASH_REMATCH[0]}"}"
        quote="${remaining:0:1}"

        if [[ "$quote" == "'" || "$quote" == '"' ]]; then
          scalar="${remaining:1}"

          if [[ "$scalar" != *"$quote"* ]]; then
            line_unpinned=1
            break
          fi

          reference="${scalar%%"$quote"*}"
          remaining="${scalar#*"$quote"}"
        else
          reference="${remaining%%[[:space:]]*}"
          reference="${reference%%,*}"
          reference="${reference%%\}*}"
          reference="${reference%%\]*}"

          if [[ -z "$reference" ]]; then
            line_unpinned=1
            break
          fi

          remaining="${remaining#"$reference"}"
        fi

        if [[ "$reference" == ./* ]]; then
          if [[ "$reference" != ./.github/actions/* ]]; then
            line_unpinned=1
          fi

          continue
        fi

        if [[ "$reference" == docker://* ]]; then
          continue
        fi

        version="${reference##*@}"

        if [[ "$reference" != *@* || ! "$version" =~ ^[0-9a-fA-F]{40}$ ]]; then
          line_unpinned=1
        fi
      done

      if [[ "$line_unpinned" -eq 1 ]]; then
        unpinned+="${line}"$'\n'
      fi
    done <<<"$output"

    if [[ -n "$unpinned" ]]; then
      printf '%s' "$unpinned"
      echo "workflow security guard: third-party actions must use full commit SHA pins and local actions must live under .github/actions" >&2
      exit 1
    fi
  else
    status="$?"
    fail_on_scanner_error "$status" "$output"
  fi
done

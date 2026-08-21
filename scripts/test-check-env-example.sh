#!/usr/bin/env bash
#
# Guards `scripts/check-env-example.py`. A drift gate that silently passes is
# worse than no gate, so every case below asserts the check actually fails when
# it should — not merely that it exits 0 on the real tree.
#
# Usage: bash scripts/test-check-env-example.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/check-env-example.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Build a miniature repo with the same layout the checker expects.
scaffold() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/scripts" "$root/src/lib/aiur/env"
  cp "$checker" "$root/scripts/check-env-example.py"

  cat >"$root/src/lib/aiur/env/schema.ex" <<'EOF'
defmodule Aiur.Env.Schema do
  def groups do
    [
      required: "Required",
      github_app: "Optional - GitHub App auth.",
      ambient: nil
    ]
  end

  @specs [
    {"GITHUB_TOKEN",
     type: :secret,
     required: true,
     group: :required,
     purpose: "Fallback GitHub credential.",
     fetch: "github.com/settings/tokens -> Generate -> repo scope"},
    {"GITHUB_APP_ID",
     type: :string,
     group: :github_app,
     purpose: "GitHub App numeric id."},
    {"PATH",
     type: :path,
     validate: false,
     example: false,
     group: :ambient,
     purpose: "Executable search path."}
  ]
end
EOF
}

example() {
  cat >"$1/.env.example"
}

run_check() {
  (cd "$1" && python3 scripts/check-env-example.py 2>&1)
}

# --- Case 1: every declared example var documented -> pass ------------------
root="$work/pass"
scaffold "$root"
example "$root" <<'EOF'
# Aiur environment variables.

## Required
# Fallback GitHub credential.
GITHUB_TOKEN=

## Optional - GitHub App auth.
# GitHub App numeric id.
GITHUB_APP_ID=
EOF
if ! output="$(run_check "$root")"; then
  fail "a fully documented example should pass, got: $output"
fi
grep -q "2 declared env vars are documented" <<<"$output" ||
  fail "expected both example vars to be counted, got: $output"

# --- Case 2: a schema var absent from the example -> fail -------------------
root="$work/missing"
scaffold "$root"
example "$root" <<'EOF'
## Required
# Fallback GitHub credential.
GITHUB_TOKEN=
EOF
if output="$(run_check "$root")"; then
  fail "a schema var absent from the example must fail the check, got: $output"
fi
grep -q "GITHUB_APP_ID" <<<"$output" ||
  fail "the failure must name the missing var, got: $output"

# --- Case 3: an example var not declared in the schema -> fail --------------
root="$work/undeclared"
scaffold "$root"
example "$root" <<'EOF'
## Required
# Fallback GitHub credential.
GITHUB_TOKEN=

# A var nobody declared.
GHOST_VAR=
EOF
if output="$(run_check "$root")"; then
  fail "an undeclared example var must fail the check, got: $output"
fi
grep -q "GHOST_VAR" <<<"$output" ||
  fail "the failure must name the undeclared var, got: $output"

# --- Case 4: an `example: false` var leaking into the example -> fail -------
root="$work/hidden"
scaffold "$root"
example "$root" <<'EOF'
## Required
# Fallback GitHub credential.
GITHUB_TOKEN=

# Ambient var that should never be in the example.
PATH=
EOF
if output="$(run_check "$root")"; then
  fail "an example:false var in the example must fail the check, got: $output"
fi
grep -q "PATH" <<<"$output" ||
  fail "the failure must name the leaked ambient var, got: $output"

# --- Case 5: header drift between schema groups and example -> fail ---------
root="$work/header-drift"
scaffold "$root"
example "$root" <<'EOF'
## Required
# Fallback GitHub credential.
GITHUB_TOKEN=

## Optional - GitHub App auth. WRONG
# GitHub App numeric id.
GITHUB_APP_ID=
EOF
if output="$(run_check "$root")"; then
  fail "a header drift must fail the check, got: $output"
fi
grep -q "Optional - GitHub App auth." <<<"$output" ||
  fail "the failure must name the drifted header, got: $output"

# --- Case 6: a digit in the name is not truncated ---------------------------
# The matcher must capture the whole name, not a prefix ending at the first
# non-uppercase character.
root="$work/digits"
scaffold "$root"
python3 - "$root/src/lib/aiur/env/schema.ex" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
source = source.replace(
    '{"GITHUB_APP_ID",\n     type: :string,',
    '{"AIUR_BASE_BRANCH",\n     type: :string,',
).replace("group: :github_app,", "group: :github_app,")
path.write_text(source)
PY
example "$root" <<'EOF'
## Required
# Fallback GitHub credential.
GITHUB_TOKEN=

## Optional - GitHub App auth.
# Authoritative integration branch.
AIUR_BASE_BRANCH=
EOF
if ! output="$(run_check "$root")"; then
  fail "a fully documented example should pass after the rename, got: $output"
fi

# --- Case 7: broken layout fails loudly, never silently passes --------------
root="$work/broken"
scaffold "$root"
example "$root" </dev/null
rm "$root/.env.example"
if output="$(run_check "$root")"; then
  fail "a missing example file must not pass, got: $output"
fi
grep -q "expected path is missing" <<<"$output" ||
  fail "a missing example file must say so, got: $output"

root="$work/noschema"
scaffold "$root"
example "$root" <<'EOF'
## Required
GITHUB_TOKEN=
EOF
: >"$root/src/lib/aiur/env/schema.ex"
if output="$(run_check "$root")"; then
  fail "an unparseable schema must not pass, got: $output"
fi
grep -q "no env-var declarations" <<<"$output" ||
  fail "an empty schema must say the matcher found nothing, got: $output"

echo "check-env-example guard: all cases passed"

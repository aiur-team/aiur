#!/usr/bin/env bash
#
# Guards `scripts/check-config-docs.py`. A docs gate that silently passes is
# worse than no gate, so every case below asserts the check actually fails when
# it should — not merely that it exits 0 on the real tree.
#
# Usage: bash scripts/test-check-config-docs.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_root/scripts/check-config-docs.py"

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
  mkdir -p "$root/scripts" "$root/src/lib/aiur/config/schema" "$root/website/docs-app/reference"
  cp "$checker" "$root/scripts/check-config-docs.py"

  cat >"$root/src/lib/aiur/config/schema.ex" <<'EOF'
defmodule Aiur.Config.Schema do
  alias Aiur.Config.Schema.{Tracker}

  embedded_schema do
    field(:debug, :boolean, default: false)

    embeds_one(:tracker, Tracker, on_replace: :update)
  end
end
EOF

  # Two modules in one file, and a field name reused across sections — the two
  # shapes the first version of this check got wrong.
  cat >"$root/src/lib/aiur/config/schema/tracker.ex" <<'EOF'
defmodule Aiur.Config.Schema.Tracker do
  embedded_schema do
    field(:kind, :string)
    field(:command, :string)

    embeds_one(:github, Github, on_replace: :update)
  end
end

defmodule Aiur.Config.Schema.Github do
  embedded_schema do
    field(:command, :string)
    field(:p95_latency_ms, :integer)
  end
end
EOF
}

reference() {
  cat >"$1/website/docs-app/reference/configuration.md"
}

run_check() {
  (cd "$1" && python3 scripts/check-config-docs.py 2>&1)
}

# --- Case 1: every dotted key documented -> pass -----------------------------
root="$work/pass"
scaffold "$root"
reference "$root" <<'EOF'
# Configuration reference

| `debug` | boolean | false | Debug. |
| `tracker.kind` | string | required | Kind. |
| `tracker.command` | string | nil | Tracker command. |
| `tracker.github.command` | string | nil | GitHub command. |
| `tracker.github.p95_latency_ms` | integer | 0 | Latency budget. |
EOF
if ! output="$(run_check "$root")"; then
  fail "fully documented schema should pass, got: $output"
fi
grep -q "all 5 config keys are documented" <<<"$output" ||
  fail "expected all 5 keys to be counted, got: $output"

# --- Case 2: an undocumented key -> fail ------------------------------------
root="$work/missing"
scaffold "$root"
reference "$root" <<'EOF'
| `debug` | boolean | false | Debug. |
| `tracker.kind` | string | required | Kind. |
| `tracker.command` | string | nil | Tracker command. |
| `tracker.github.command` | string | nil | GitHub command. |
EOF
if output="$(run_check "$root")"; then
  fail "an undocumented key must fail the check, got: $output"
fi
grep -q "tracker.github.p95_latency_ms" <<<"$output" ||
  fail "the failure must name the missing key, got: $output"

# --- Case 3: a digit in the name is not truncated ---------------------------
# `field\(:[a-z_]+` matched `p` here and passed for free against any prose
# containing the letter p. Assert the whole name is required.
root="$work/digits"
scaffold "$root"
reference "$root" <<'EOF'
| `debug` | boolean | false | Debug. |
| `tracker.kind` | string | required | Kind. |
| `tracker.command` | string | nil | Tracker command. |
| `tracker.github.command` | string | nil | GitHub command. |
| `tracker.github.p` | integer | 0 | A prefix, not the key. |
EOF
if output="$(run_check "$root")"; then
  fail "a truncated key name must not satisfy the check, got: $output"
fi

# --- Case 4: a section key documented only by its bare name -> fail ---------
# `command` appears under two sections. Documenting one must not satisfy both.
root="$work/bare"
scaffold "$root"
reference "$root" <<'EOF'
| `debug` | boolean | false | Debug. |
| `tracker.kind` | string | required | Kind. |
| `command` | string | nil | Ambiguous bare name. |
| `tracker.github.p95_latency_ms` | integer | 0 | Latency budget. |
EOF
if output="$(run_check "$root")"; then
  fail "a bare field name must not satisfy a dotted key, got: $output"
fi
grep -q "tracker.command" <<<"$output" ||
  fail "expected tracker.command to be reported missing, got: $output"

# --- Case 5: a broken layout fails loudly, never silently passes ------------
root="$work/broken"
scaffold "$root"
reference "$root" </dev/null
rm "$root/website/docs-app/reference/configuration.md"
if output="$(run_check "$root")"; then
  fail "a missing reference file must not pass, got: $output"
fi
grep -q "expected path is missing" <<<"$output" ||
  fail "a missing reference file must say so, got: $output"

root="$work/noschema"
scaffold "$root"
reference "$root" </dev/null
: >"$root/src/lib/aiur/config/schema.ex"
if output="$(run_check "$root")"; then
  fail "an unparseable root schema must not pass, got: $output"
fi
grep -q "the matcher is broken" <<<"$output" ||
  fail "an unparseable root schema must say the matcher is broken, got: $output"

echo "check-config-docs guard: all cases passed"

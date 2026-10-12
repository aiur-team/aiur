# Spliced into the gh and git guards at their `@aiur-recursion-guard@` marker by
# Aiur.AgentGitHubGuard.RecursionGuard; not a standalone script.
#
# A "real" @tool@ that resolves back to this wrapper must fail one command, not
# fork-bomb the host (#4205). A call that re-enters the wrapper nested inside
# the identical call is a loop and is refused before anything is spawned; the
# depth cap bounds a chain that changes its arguments on every hop. Nested calls
# that differ (a hook or `rebase --exec` running @tool@) still pass.
guard_depth=${AIUR_@TOOL@_GUARD_DEPTH:-0}
case "$guard_depth" in '' | *[!0-9]* | ???*) guard_depth=99 ;; esac
# Without cksum on PATH there is no fingerprint and only the depth cap applies.
guard_call=$({ printf '%s\n' "$PWD" "$@" | cksum; } 2>/dev/null) || guard_call=
if [ "$guard_depth" -ge 8 ] || { [ -n "$guard_call" ] && [ "$guard_depth" -gt 0 ] && [ "$guard_call" = "${AIUR_@TOOL@_GUARD_CALL:-}" ]; }; then
  printf '%s\n' 'aiur: @tool@ guard re-entered itself; refusing to recurse (check PATH and AIUR_REAL_@TOOL@)' >&2
  exit 70
fi
AIUR_@TOOL@_GUARD_DEPTH=$((guard_depth + 1))
AIUR_@TOOL@_GUARD_CALL=$guard_call
export AIUR_@TOOL@_GUARD_DEPTH AIUR_@TOOL@_GUARD_CALL
unset guard_depth guard_call
